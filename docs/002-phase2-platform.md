# Phase 2: Platform

컴퓨팅/스토리지 기반 — [Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/), CSI Drivers, [RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/), [S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/), [FSx for Lustre](https://docs.aws.amazon.com/fsx/latest/LustreGuide/), [ECR](https://docs.aws.amazon.com/AmazonECR/latest/userguide/), [Karpenter](https://karpenter.sh/docs/), [IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)

## Goal

모든 워크로드가 올라갈 컴퓨팅 클러스터와 스토리지를 구축한다.

## Prerequisites

- Phase 1 완료 (VPC, 서브넷, SG, VPC Endpoints)
- IAM 관리 권한
- g7e.48xlarge AZ 가용 확인 완료 (g7e GA 시 전환 가능, Compute SP 사용 시 인스턴스 변경 무관)

## Design Decisions

| 결정 | 선택 | 이유 |
|------|------|------|
| EKS 엔드포인트 | Private Only | GPU 클러스터는 외부 노출이 불필요하다. kubectl은 DX 경유로만 접근한다 |
| GPU 노드 전략 | 3-tier: ASG Baseline + Karpenter Spot Burst + OD Fallback | 대형 GPU 인스턴스(g7e.48xlarge)는 가용성이 낮고 프로비저닝이 느리다(5~10분). Baseline은 ASG로 항상 유지하여 용량을 보장하고, burst는 Karpenter Spot으로 비용 효율화한다 |
| GPU Baseline | Managed Node Group (min=max=2) | On-Demand 2대 상시 가동(16 GPU). ASG이므로 Karpenter consolidation에 의해 제거되지 않는다. 장시간/멀티노드 학습에 안정적 |
| GPU Burst | Karpenter Spot (우선) + On-Demand (fallback) | HPO, 단기 실험에 Spot으로 60~70% 비용 절감. Spot 용량 부족 시 On-Demand로 자동 전환. 학습 완료 후 노드 자동 제거 |
| ~~HyperPod (장기)~~ | ~~ASG Baseline 대체 후보~~ | ~~Deep Health Check + 자동 노드 교체가 장시간 학습에 유리하나, RayJob auto-resume 미지원(PyTorchJob만). g7e GA + RayJob 지원 확인 후 전환 검토~~ **(미적용 — 향후 검토)** |
| 노드 분리 | Management MNG + GPU Baseline MNG + Karpenter GPU Burst | Management는 항상 실행(저비용), GPU Baseline은 학습 안정성 보장, Burst는 탄력적 확장 |
| 공유 스토리지 | FSx for Lustre (EFS 대신) | 멀티노드 체크포인트 I/O에 병렬 파일시스템 성능이 필요하다. EFS는 처리량이 부족하다 |
| 메타데이터 DB | RDS PostgreSQL 공용 | Keycloak과 MLflow가 별도 DB를 쓰지만 동일 RDS 인스턴스를 공유하여 관리 복잡도를 줄인다 |
| 시크릿 관리 | External Secrets + Secrets Manager | K8s Secret을 코드에 하드코딩하지 않고 중앙 관리한다. 시크릿 로테이션도 자동화된다 |
| Pod 권한 | IRSA (노드 IAM Role 대신) | Pod별 최소 권한 원칙. 노드 IAM Role은 해당 노드의 모든 Pod에 동일 권한을 부여해 과도하다 |
| 비용 전략 | Phase 1~2: OD → 3개월 후 Compute SP 1yr | 인프라 구축 기간(~2개월)은 GPU 불필요. 사용 패턴 파악 후 Compute Savings Plans 적용. g7e 전환 가능성을 위해 Standard RI 대신 Compute SP 선택 |

---

## Service Flow

### EKS 클러스터 아키텍처

```
kubectl (On-Prem via DX)
  │
  │  Private Endpoint Only
  ▼
┌─ EKS Control Plane (AWS Managed) ──────────────────────────────────┐
│  API Server ◄── VPC Endpoint (com.amazonaws.{region}.eks)          │
└────────────────────────────────────────────────────────────────────┘
        │
        │ kubelet
        ▼
┌─ Management Node Group (m6i.2xlarge x3~5) ──────────────────────┐
│  Subnet: 10.100.1.0/24                                          │
│                                                                 │
│  System Pods:                                                   │
│    ├── CoreDNS (x2)                                             │
│    ├── VPC CNI                                                  │
│    ├── Karpenter                                                │
│    ├── ALB Ingress Controller                                   │
│    ├── EBS CSI Driver                                           │
│    ├── FSx CSI Driver                                           │
│    └── External Secrets Operator                                │
│                                                                 │
│  Application Pods (deployed in Phase 4~9):                      │
│    ├── Keycloak, MLflow, ClickHouse                             │
│    ├── JupyterHub, Grafana, Prometheus                          │
│    ├── OSMO Controller, Ray Head                                │
│    └── Fluent Bit (DaemonSet)                                   │
└─────────────────────────────────────────────────────────────────┘

┌─ GPU Baseline Node Group (ASG, g7e.48xlarge x2) ────────────────┐
│  Subnet: 10.100.0.0/24                                          │
│  Capacity: On-Demand, min=max=2 (항상 16 GPU 보장)               │
│                                                                 │
│  Labels:                                                        │
│    node-type: gpu                                                │
│    gpu-tier: baseline                                            │
│  Taint: nvidia.com/gpu=:NoSchedule                              │
│                                                                 │
│  Per Node (8x NVIDIA L40S, 48GB GDDR6 each):                   │
│    ├── Ray Worker Pod (uses 8 GPUs)                             │
│    ├── DCGM Exporter (DaemonSet)                                │
│    ├── Fluent Bit (DaemonSet)                                   │
│    └── FSx mount (/mnt/fsx)                                     │
│                                                                 │
│  용도: 장시간 학습, 멀티노드 학습 (안정성 우선)                    │
└─────────────────────────────────────────────────────────────────┘

┌─ GPU Burst Nodes (Karpenter, g7e x0~N) ─────────────────────────┐
│  Subnet: 10.100.0.0/24                                          │
│                                                                 │
│  ┌──────────────────────────────────────────────────────┐       │
│  │ NodePool: gpu-burst-spot (weight=10, 우선)            │       │
│  │   Instance: g7e/g6e (48x, 24x, 12xlarge)              │       │
│  │   Capacity: Spot (60~70% 할인)                        │       │
│  │   용도: HPO, 단기 실험 (4시간 이하)                     │       │
│  │   Disruption: WhenEmpty, 10m                          │       │
│  └──────────────────────────────────────────────────────┘       │
│  ┌──────────────────────────────────────────────────────┐       │
│  │ NodePool: gpu-burst-od (weight=1, fallback)           │       │
│  │   Instance: g7e.48xlarge                              │       │
│  │   Capacity: On-Demand                                 │       │
│  │   용도: Spot 용량 부족 시 자동 전환                      │       │
│  │   Disruption: WhenEmpty, 10m                          │       │
│  └──────────────────────────────────────────────────────┘       │
│                                                                 │
│  Per Node:                                                      │
│    ├── Ray Worker Pod (uses GPUs)                               │
│    ├── DCGM Exporter (DaemonSet)                                │
│    ├── Fluent Bit (DaemonSet)                                   │
│    └── FSx mount (/mnt/fsx)                                     │
└─────────────────────────────────────────────────────────────────┘
```

### 스토리지 아키텍처

```
                    ┌──────────────────────┐
                    │   EKS Pods           │
                    └──────┬───────────────┘
                           │
            ┌──────────────┼───────────────────┐
            │              │                   │
            ▼              ▼                   ▼
   ┌─────────────┐  ┌───────────┐    ┌──────────────────┐
   │ FSx Lustre  │  │ EBS gp3   │    │ S3 (VPC Endpoint)│
   │ PERSISTENT_2│  │ (CSI)     │    │                  │
   │             │  │           │    │ ├── checkpoints  │
   │ /mnt/fsx/   │  │ Used by:  │    │ ├── models       │
   │ ├─ ckpt/    │  │ ClickHouse│    │ ├── logs-archive │
   │ ├─ data/    │  │ Prometheus│    │ └── training-data│
   │ └─ shared/  │  │           │    │                  │
   └──────┬──────┘  └───────────┘    └──────────────────┘
          │                                   ▲
          │ Data Repository Association       │
          └───────────────────────────────────┘
            FSx ↔ S3 자동 동기화 (체크포인트 백업)

   ┌─────────────────────────────────┐
   │ RDS PostgreSQL                  │
   │   ├── keycloak_db (Phase 4)     │
   │   └── mlflow_db   (Phase 6)     │
   │   SG-Storage: :5432             │
   └─────────────────────────────────┘
```

### IRSA 신뢰 관계

```
AWS IAM Role                    K8s Service Account              용도
─────────────────────────────────────────────────────────────────────
EBS-CSI-Role            ◄────  ebs-csi-controller-sa         EBS 볼륨
FSx-CSI-Role            ◄────  fsx-csi-controller-sa         FSx 마운트
Karpenter-Role          ◄────  karpenter                     EC2 프로비저닝
ALB-Controller-Role     ◄────  aws-load-balancer-controller  ALB 관리
MLflow-Role             ◄────  mlflow                        S3 models
FluentBit-Role          ◄────  fluent-bit                    S3 logs-archive
ExtSecrets-Role         ◄────  external-secrets              Secrets Manager
CH-Backup-Role          ◄────  clickhouse-backup             S3 logs-archive
Training-Role           ◄────  training-job                  S3 + FSx

         ┌───────────────────────────────────┐
         │  EKS OIDC Provider                │
         │  sts.amazonaws.com                │
         │                                   │
         │  Trust: "aud": "sts.amazonaws.com"│
         │         "sub": "system:sa:ns:name"│
         └───────────────────────────────────┘
```

---

## Steps

### 2-1. [EKS 클러스터](https://docs.aws.amazon.com/eks/latest/userguide/private-clusters.html) 생성

```
Cluster Name: isaac-lab-production
Kubernetes Version: 1.31+
Endpoint Access: Private Only
VPC: Phase 1에서 생성한 VPC
Subnets: GPU Compute, Management, Infrastructure
Security Groups: SG-Mgmt-Node (cluster SG)
```

Private Endpoint Only이므로 kubectl 접근은 VPC 내부 또는 DX 경유만 가능하다.

[EKS Control Plane Logging](https://docs.aws.amazon.com/eks/latest/userguide/control-plane-logs.html)을 활성화하여 API server, scheduler, controller manager, authenticator, audit 로그를 CloudWatch Logs로 전송한다. Phase 7에서 ClickHouse에 수집하는 노드/컨테이너 로그와 별개로, 컨트롤 플레인 수준의 스케줄링/인증 문제를 추적하는 데 사용한다.

```
Logging:
  api: Enabled
  audit: Enabled
  authenticator: Enabled
  controllerManager: Enabled
  scheduler: Enabled

Log Group: /aws/eks/isaac-lab-production/cluster
Retention: 30 days
```

### 2-2. [VPC CNI](https://docs.aws.amazon.com/eks/latest/userguide/managing-vpc-cni.html) 설정

```
WARM_IP_TARGET=2
MINIMUM_IP_TARGET=10
ENABLE_PREFIX_DELEGATION=true
```

Pod 밀도가 높지 않으므로 Prefix Delegation은 선택. WARM_IP_TARGET=2로 불필요한 IP 선점 방지.

### 2-3. 노드 그룹 -- Management

```
Name: management
Instance Types: m6i.2xlarge ~ m6i.4xlarge
Min/Max/Desired: 3 / 5 / 3
Subnet: Management (10.100.1.0/24)
Labels:
  node-type: management
AMI: Amazon Linux 2023 (EKS Optimized)
```

Management 노드 그룹은 [EKS Managed Node Group](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html)으로 생성한다.

### 2-3b. 노드 그룹 -- GPU Baseline

```
Name: gpu-baseline
Instance Types: g7e.48xlarge
Min/Max/Desired: 2 / 2 / 2
Subnet: GPU Compute (10.100.0.0/24)
Capacity: On-Demand
Labels:
  node-type: gpu
  gpu-tier: baseline
Taints:
  nvidia.com/gpu=:NoSchedule
AMI: Amazon Linux 2023 (EKS Optimized GPU)
Tags:
  karpenter.sh/discovery: isaac-lab-production
  k8s.io/cluster-autoscaler/enabled: "false"
```

GPU Baseline 노드 그룹은 ASG 기반 Managed Node Group으로 **min=max=2를 고정**하여 항상 16 GPU를 확보한다. 대형 GPU 인스턴스(g7e.48xlarge)는 프로비저닝에 5~10분이 소요되고, 리전별 용량이 제한적이므로 Karpenter에 의존하면 학습 시작이 지연되거나 실패할 수 있다. Baseline 노드는 Karpenter의 관리 대상이 아니므로 consolidation/disruption에 영향받지 않는다.

**장시간 학습, 멀티노드 학습**은 반드시 Baseline 노드에 스케줄링하여 안정성을 보장한다.

<!-- HyperPod 전환 경로 (미적용 — 향후 검토)

Baseline 노드 그룹은 SageMaker HyperPod EKS 모드의 전환 후보이다:

| 항목 | 현재 (ASG Baseline) | HyperPod 전환 후 |
|------|-------------------|------------------|
| 노드 장애 대응 | 수동 확인, ASG 교체 | Deep Health Check + 자동 노드 교체 |
| GPU 모니터링 | DCGM Exporter | HyperPod 자체 + DCGM Exporter |
| 디바이스 플러그인 | 수동 설치 (NVIDIA + EFA) | HyperPod Helm Chart 자동 설치 |
| auto-resume | 미지원 | PyTorchJob만 지원 (RayJob 미지원) |
| Karpenter | 별도 설치 | HyperPod Managed Karpenter |

전환 조건:
- g7e.48xlarge ap-northeast-2 GA
- HyperPod의 RayJob auto-resume 지원 (또는 OSMO에서 checkpoint 기반 재시작 구현)
- 실제 워크로드 패턴에서 Deep Health Check 가치 확인 (24h+ 학습 비율)
-->

### 2-4. [EBS CSI Driver](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html)

```
1. IAM Role 생성 (IRSA)
   - Policy: AmazonEBSCSIDriverPolicy
   - Service Account: ebs-csi-controller-sa (kube-system)

2. EKS Add-on 설치
   - aws-ebs-csi-driver
   - Service Account에 IAM Role 연결

3. StorageClass 생성
   - Name: gp3
   - Type: gp3
   - Encrypted: true
   - ReclaimPolicy: Delete
```

ClickHouse, Prometheus 등 Persistent Volume이 필요한 워크로드에 사용한다.

### 2-5. [FSx CSI Driver](https://docs.aws.amazon.com/eks/latest/userguide/fsx-csi.html)

```
1. IAM Role 생성 (IRSA)
   - Policy: AmazonFSxFullAccess (또는 최소 권한 커스텀)
   - Service Account: fsx-csi-controller-sa (kube-system)

2. Helm 설치
   - aws-fsx-csi-driver

3. FSx for Lustre 파일시스템 생성
   - Deployment Type: PERSISTENT_2
   - Subnet: Infrastructure (10.100.2.0/24), GPU와 같은 AZ
   - Security Group: SG-Storage
   - Storage Capacity: 최소 1.2 TiB
   - Per Unit Storage Throughput: 250 MB/s/TiB

4. PersistentVolume 생성 (static provisioning)
   - volumeHandle: FSx 파일시스템 ID
   - mountName: FSx mount name
```

```
/mnt/fsx/
  ├── checkpoints/    training checkpoints (high-speed I/O)
  ├── datasets/       training datasets
  └── shared/         multi-node shared storage
```

### 2-6. [S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/) 버킷 생성

| 버킷 | 용도 | Lifecycle |
|------|------|-----------|
| {prefix}-checkpoints | 체크포인트 백업 (FSx → S3) | 90일 → IA, 365일 삭제 |
| {prefix}-models | MLflow 모델 아티팩트 | 영구 보관 |
| {prefix}-logs-archive | ClickHouse 로그 아카이브 | 180일 → Glacier |
| {prefix}-training-data | 학습 데이터 원본 | 영구 보관 |

모든 버킷:
- Versioning: Enabled
- Encryption: SSE-S3 (또는 SSE-KMS)
- Public Access: Block All
- VPC Endpoint Policy: VPC 내부에서만 접근

### 2-7. [RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/) PostgreSQL

```
Engine: PostgreSQL 16
Instance: db.r6g.large
Multi-AZ: Standby 권장 (primary는 GPU와 같은 AZ)
Subnet Group: Infrastructure Subnet
Security Group: SG-Storage
Storage: gp3, 50 GiB
Encryption: 활성화

Databases:
  - keycloak_db   (Phase 4에서 사용)
  - mlflow_db     (Phase 6에서 사용)
```

### 2-8. [ECR](https://docs.aws.amazon.com/AmazonECR/latest/userguide/) Repository

```
Repository: isaac-lab-training
Image Tag Mutability: IMMUTABLE (권장)
Scan on Push: Enabled
Lifecycle Policy: 최근 30개 이미지 유지, 나머지 자동 삭제
```

기존 테스트 환경 이미지(nvcr.io/nvidia/isaac-lab:2.2.0 기반)를 참고하여 프로덕션 이미지를 빌드한다.

### 2-9. [Karpenter](https://karpenter.sh/docs/) 설치 (GPU Burst 전용)

Karpenter는 **GPU Burst 노드만 관리**한다. Baseline GPU 노드(2-3b)는 ASG Managed Node Group으로 별도 관리된다.

```
1. Karpenter IAM Role 생성
   - EC2 인스턴스 프로파일
   - SQS 인터럽션 큐 (Spot 중단 + 상태 변경 이벤트)
   - Service Account IRSA

2. Helm 설치
   - karpenter (karpenter namespace)

3. NodePool 2개 정의

   (a) gpu-burst-spot — Spot 우선 (weight=10)
   apiVersion: karpenter.sh/v1
   kind: NodePool
   metadata:
     name: gpu-burst-spot
   spec:
     weight: 10
     template:
       metadata:
         labels:
           node-type: gpu
           gpu-tier: burst
           capacity-type: spot
       spec:
         taints:
           - key: nvidia.com/gpu
             effect: NoSchedule
         requirements:
           - key: node.kubernetes.io/instance-type
             operator: In
             values: ["g7e.48xlarge", "g7e.24xlarge", "g7e.12xlarge",
                      "g6e.48xlarge", "g6e.24xlarge", "g6e.12xlarge"]
           - key: karpenter.sh/capacity-type
             operator: In
             values: ["spot"]
           - key: topology.kubernetes.io/zone
             operator: In
             values: ["{az}"]
         nodeClassRef:
           name: gpu-class
     limits:
       cpu: "1920"
       nvidia.com/gpu: "80"
     disruption:
       consolidationPolicy: WhenEmpty
       consolidateAfter: 10m

   (b) gpu-burst-od — On-Demand fallback (weight=1)
   apiVersion: karpenter.sh/v1
   kind: NodePool
   metadata:
     name: gpu-burst-od
   spec:
     weight: 1
     template:
       metadata:
         labels:
           node-type: gpu
           gpu-tier: burst
           capacity-type: on-demand
       spec:
         taints:
           - key: nvidia.com/gpu
             effect: NoSchedule
         requirements:
           - key: node.kubernetes.io/instance-type
             operator: In
             values: ["g7e.48xlarge"]
           - key: karpenter.sh/capacity-type
             operator: In
             values: ["on-demand"]
           - key: topology.kubernetes.io/zone
             operator: In
             values: ["{az}"]
         nodeClassRef:
           name: gpu-class
     limits:
       cpu: "960"
       nvidia.com/gpu: "40"
     disruption:
       consolidationPolicy: WhenEmpty
       consolidateAfter: 10m

4. EC2NodeClass 정의 (Baseline과 Burst 공유)
   - AMI: EKS Optimized GPU AMI (AL2023)
   - Subnet: GPU Compute
   - Security Groups: SG-GPU-Node
   - EFA: enabled
   - Block Device: gp3, 200 GiB
   - UserData: FSx mount, NVIDIA driver 확인
```

**워크로드 자동 배치 전략**

사용자는 학습을 제출만 하면 OSMO Controller가 워크로드 특성에 따라 자동 배치한다:

| 워크로드 특성 | 배치 대상 | 이유 |
|-------------|----------|------|
| 멀티노드 (16+ GPU) 또는 12시간+ | Baseline (ASG) | 안정성 필수, Spot 회수 시 전체 실패 |
| 단일노드 실험 (8 GPU, <6시간) | Burst (Spot 우선) | 비용 효율, 실패 시 재시작 가능 |
| HPO sweep (1~8 GPU per trial) | Burst (Spot 우선) | trial 단위 독립, 일부 실패 허용 |

배치 메커니즘:
- **Baseline 배치**: RayJob에 `nodeSelector: { eks.amazonaws.com/nodegroup: gpu-baseline }` 설정
- **Burst 배치**: nodeSelector 없이 taint toleration만 설정 → Karpenter가 자동 프로비저닝

**Spot 회수 대응**

Karpenter SQS 인터럽션 큐를 통해 2분 전 termination 경고를 수신하고 graceful drain을 수행한다. 학습 Pod에는 `terminationGracePeriodSeconds: 120`을 설정하여 checkpoint 저장 시간을 확보한다.

### 2-10. [IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) (IAM Roles for Service Accounts)

| Service Account | Namespace | IAM Policy | 용도 |
|----------------|-----------|------------|------|
| ebs-csi-controller-sa | kube-system | AmazonEBSCSIDriverPolicy | EBS 볼륨 관리 |
| fsx-csi-controller-sa | kube-system | AmazonFSxFullAccess | FSx 마운트 |
| karpenter | karpenter | Karpenter Controller Policy | EC2 프로비저닝 |
| aws-load-balancer-controller | kube-system | ALB Controller Policy | ALB 생성/관리 |
| mlflow | mlflow | S3 read/write (models 버킷) | 아티팩트 저장 |
| fluent-bit | logging | S3 write (logs-archive) | 로그 아카이브 |
| external-secrets | external-secrets | SecretsManager read | 시크릿 동기화 |
| clickhouse-backup | logging | S3 write (logs-archive) | 백업 |
| training-job | training | S3 read/write, FSx | 학습 작업 |

### 2-11. [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)

```
1. IAM Role 생성 (IRSA)
2. Helm 설치 (aws-load-balancer-controller)
3. IngressClass: alb
```

Internal ALB는 Phase 4 이후 Ingress 리소스 생성 시 자동 프로비저닝된다.

### 2-12. [External Secrets Operator](https://external-secrets.io/)

```
1. Helm 설치 (external-secrets)
2. ClusterSecretStore 생성 (AWS Secrets Manager)
3. ExternalSecret 리소스로 시크릿 동기화
```

RDS 비밀번호, Keycloak 시크릿 등을 Secrets Manager에서 K8s Secret으로 자동 동기화한다.

### 2-13. GPU 비용 전략

월 예산 $65,000 기준, g7e.48xlarge On-Demand $37.04/hr (ap-northeast-2) 기준.

**리소스 산정**

| 구성 | GPU 수 | 월 비용 | 역할 |
|------|--------|---------|------|
| 고정 인프라 (EKS, RDS, FSx 등) | - | $2,178 | 항상 실행 |
| GPU Baseline 2× g7e.48xlarge (OD) | 16 GPU | $54,078 | 상시 학습 |
| GPU Burst (Spot, ~$11/hr) | 0~N GPU | ~$8,744 잔여 | HPO, 실험 |
| **합계** | 16~32 GPU | **$65,000** | |

**단계별 비용 최적화**

| 단계 | 기간 | GPU 전략 | 비고 |
|------|------|---------|------|
| 인프라 구축 | 0~2개월 | GPU 없음 | 고정 인프라만 ~$2,200/월 |
| GPU 검증 | 2~3개월 | On-Demand (필요 시) | Stage 1~4 검증 |
| 본격 운영 | 3개월~ | Baseline 2대 + Burst | 패턴 파악 |
| SP 적용 | 4~5개월~ | [Compute Savings Plans](https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html) 1yr | Baseline 비용 ~25% 절감 |

**Compute Savings Plans 선택 이유**
- g7e 전환 시 인스턴스 패밀리 변경 가능 (Standard RI는 불가)
- 리전 변경 가능 (ap-northeast-2 → us-east-1 등)
- No Upfront 옵션으로 선결제 부담 없이 ~25% 절감

**SP 적용 시 예산 배분 (Compute SP 1yr)**

| 구성 | 월 비용 |
|------|---------|
| 고정 인프라 | $2,178 |
| GPU Baseline 2대 (SP ~25%) | $40,559 |
| GPU Burst (Spot) | $22,263 잔여 |
| → Spot burst 가능 시간 | ~2,024hr (8GPU) 또는 ~675hr (24GPU) |

**운영 규칙**

- 평일만 학습 시 GPU Baseline 비용 28% 절감 가능 (주말 drain → Karpenter 아님, ASG 축소)
- 단, ASG min=2를 0으로 변경하면 재기동 시 용량 확보 실패 위험이 있으므로 상시 유지 권장
- Baseline 노드에서 실행 중인 학습은 `karpenter.sh/do-not-disrupt` annotation과 PDB로 보호

---

## References

### Compute

- [Amazon EKS User Guide](https://docs.aws.amazon.com/eks/latest/userguide/)
- [EKS Private Clusters](https://docs.aws.amazon.com/eks/latest/userguide/private-clusters.html)
- [EKS Managed Node Groups](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html)
- [EKS Add-ons](https://docs.aws.amazon.com/eks/latest/userguide/eks-add-ons.html)
- [Karpenter](https://karpenter.sh/docs/)
- [SageMaker HyperPod EKS](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod-eks.html)

### Cost Optimization

- [Compute Savings Plans](https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html)
- [EC2 Spot Instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html)
- [On-Demand Capacity Reservations](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-reservations.html)

### Networking and Load Balancing

- [Amazon VPC CNI Plugin](https://docs.aws.amazon.com/eks/latest/userguide/managing-vpc-cni.html)
- [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)

### Storage

- [Amazon EBS CSI Driver](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html)
- [Amazon FSx CSI Driver](https://docs.aws.amazon.com/eks/latest/userguide/fsx-csi.html)
- [FSx for Lustre](https://docs.aws.amazon.com/fsx/latest/LustreGuide/)
- [Amazon S3 User Guide](https://docs.aws.amazon.com/AmazonS3/latest/userguide/)

### Database

- [Amazon RDS User Guide](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/)

### Container Registry

- [Amazon ECR User Guide](https://docs.aws.amazon.com/AmazonECR/latest/userguide/)

### Security and Secrets

- [IRSA (IAM Roles for Service Accounts)](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [External Secrets Operator](https://external-secrets.io/)

## Validation Checklist

- [ ] EKS 클러스터 Private Endpoint 접근 확인
- [ ] Management 노드 그룹 (3대) Running
- [ ] kubectl get nodes 정상
- [ ] EBS CSI Driver 설치 → PVC 생성/마운트 테스트
- [ ] FSx for Lustre 생성 → Pod에서 /mnt/fsx 마운트 확인
- [ ] S3 버킷 4개 생성 → VPC Endpoint 경유 접근 확인
- [ ] RDS PostgreSQL 접근 확인 (Management Subnet에서)
- [ ] ECR Repository 생성 → 이미지 push/pull 테스트
- [ ] GPU Baseline 노드 그룹: g7e.48xlarge 2대 Running 확인
- [ ] GPU Baseline 노드: nvidia-smi 8 GPU 확인, FSx 마운트 확인
- [ ] GPU Baseline 노드: taint nvidia.com/gpu=:NoSchedule 확인
- [ ] Karpenter 설치 → gpu-burst-spot NodePool에서 Spot 프로비저닝 확인
- [ ] Karpenter → Spot 용량 부족 시 gpu-burst-od fallback 확인
- [ ] Karpenter → 학습 완료 후 10분 내 burst 노드 자동 제거 확인
- [ ] SQS 인터럽션 큐: Spot 중단 이벤트 수신 확인
- [ ] IRSA: 각 Service Account에서 AWS API 호출 성공
- [ ] ALB Controller 설치 확인
- [ ] External Secrets Operator 동작 확인
- [ ] GPU Preflight (per-node): nvidia-smi 8 GPU, EFA fi_info, FSx 쓰기/읽기, checkpoint I/O
- [ ] GPU Preflight (multi-node): NCCL 2-node all-reduce 정상, bandwidth >50 Gbps, FSx 공유 확인

## Next

→ [Phase 3: Bridge](003-phase3-bridge.md)
