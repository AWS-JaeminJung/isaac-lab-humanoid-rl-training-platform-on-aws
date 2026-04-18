# Phase 2: Platform

컴퓨팅/스토리지 기반 — [Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/), CSI Drivers, [RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/), [S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/), [FSx for Lustre](https://docs.aws.amazon.com/fsx/latest/LustreGuide/), [ECR](https://docs.aws.amazon.com/AmazonECR/latest/userguide/), [Karpenter](https://karpenter.sh/docs/), [IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)

## Goal

모든 워크로드가 올라갈 컴퓨팅 클러스터와 스토리지를 구축한다.

## Prerequisites

- Phase 1 완료 (VPC, 서브넷, SG, VPC Endpoints)
- IAM 관리 권한
- g6e.48xlarge AZ 가용 확인 완료

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
┌─ Management Node Group (m6i.2xlarge x3~5) ─────────────────────┐
│  Subnet: 10.100.1.0/24                                         │
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
│  Application Pods (Phase 4~9에서 배포):                         │
│    ├── Keycloak, MLflow, ClickHouse                             │
│    ├── JupyterHub, Grafana, Prometheus                          │
│    ├── OSMO Controller, Ray Head                                │
│    └── Fluent Bit (DaemonSet)                                   │
└─────────────────────────────────────────────────────────────────┘

┌─ GPU Nodes (Karpenter, g6e.48xlarge x0~10) ────────────────────┐
│  Subnet: 10.100.0.0/24                                         │
│                                                                 │
│  ┌──────────────────────────────────────────────────────┐      │
│  │ Karpenter NodePool: gpu-pool                          │      │
│  │   Instance: g6e.48xlarge (8x L40S)                    │      │
│  │   Taint: nvidia.com/gpu=:NoSchedule                   │      │
│  │   EFA: enabled                                        │      │
│  │   Scale: 0 → 10 (학습 요청 시 자동 프로비저닝)         │      │
│  └──────────────────────────────────────────────────────┘      │
│                                                                 │
│  Per Node:                                                      │
│    ├── Ray Worker Pod (GPU 8개 사용)                             │
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
   │ ├─ ckpt/   │  │ ClickHouse│    │ ├── logs-archive │
   │ ├─ data/   │  │ Prometheus│    │ └── training-data│
   │ └─ shared/ │  │           │    │                  │
   └──────┬──────┘  └───────────┘    └──────────────────┘
          │                                   ▲
          │ Data Repository Association       │
          └───────────────────────────────────┘
            FSx ↔ S3 자동 동기화 (체크포인트 백업)

   ┌─────────────────────────────────┐
   │ RDS PostgreSQL                  │
   │   ├── keycloak_db (Phase 4)     │
   │   └── mlflow_db   (Phase 6)    │
   │   SG-Storage: :5432            │
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

         ┌──────────────────────────────────┐
         │  EKS OIDC Provider               │
         │  sts.amazonaws.com               │
         │                                  │
         │  Trust: "aud": "sts.amazonaws.com"│
         │         "sub": "system:sa:ns:name"│
         └──────────────────────────────────┘
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

Management 노드 그룹은 [EKS Managed Node Group](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html)으로 생성한다. GPU 노드는 Karpenter가 관리하므로 여기서는 생성하지 않는다.

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
  ├── checkpoints/    학습 체크포인트 (고속 I/O)
  ├── datasets/       학습 데이터셋
  └── shared/         멀티노드 공유 스토리지
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

### 2-9. [Karpenter](https://karpenter.sh/docs/) 설치

```
1. Karpenter IAM Role 생성
   - EC2 인스턴스 프로파일
   - SQS 인터럽션 큐
   - Service Account IRSA

2. Helm 설치
   - karpenter (karpenter namespace)

3. NodePool 정의
   apiVersion: karpenter.sh/v1
   kind: NodePool
   metadata:
     name: gpu-pool
   spec:
     template:
       metadata:
         labels:
           node-type: gpu
       spec:
         taints:
           - key: nvidia.com/gpu
             effect: NoSchedule
         requirements:
           - key: node.kubernetes.io/instance-type
             operator: In
             values: ["g6e.48xlarge"]
           - key: topology.kubernetes.io/zone
             operator: In
             values: ["{az}"]
         nodeClassRef:
           name: gpu-class
     limits:
       cpu: "1920"
     disruption:
       consolidationPolicy: WhenEmpty
       consolidateAfter: 5m

4. EC2NodeClass 정의
   - AMI: EKS Optimized GPU AMI
   - Subnet: GPU Compute
   - Security Groups: SG-GPU-Node
   - EFA: enabled
   - Block Device: gp3, 200 GiB
   - UserData: FSx mount, NVIDIA driver 확인
```

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

---

## References

### Compute

- [Amazon EKS User Guide](https://docs.aws.amazon.com/eks/latest/userguide/)
- [EKS Private Clusters](https://docs.aws.amazon.com/eks/latest/userguide/private-clusters.html)
- [EKS Managed Node Groups](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html)
- [EKS Add-ons](https://docs.aws.amazon.com/eks/latest/userguide/eks-add-ons.html)
- [Karpenter](https://karpenter.sh/docs/)

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
- [ ] Karpenter 설치 → GPU Pod 배포 시 g6e.48xlarge 프로비저닝 확인
- [ ] IRSA: 각 Service Account에서 AWS API 호출 성공
- [ ] ALB Controller 설치 확인
- [ ] External Secrets Operator 동작 확인

## Next

→ [Phase 3: Bridge](phase3-bridge.md)
