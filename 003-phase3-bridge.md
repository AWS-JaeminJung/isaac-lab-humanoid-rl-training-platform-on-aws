# Phase 3: Bridge

[EKS Hybrid Nodes](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-overview.html) — On-Prem GPU 환경 설정, Hybrid Nodes Gateway, DX 연결 확인, S3 접근 검증

## Goal

On-Prem RTX Pro 6000 머신을 EKS Hybrid Nodes로 등록하고, Hybrid Nodes Gateway로 Pod 네트워킹을 자동화하여 단일 GPU 작업(eval, 디버깅, 시각화)을 실행할 수 있게 한다.

## Prerequisites

- Phase 2 완료 (EKS 클러스터 운영 중)
- [Direct Connect](https://docs.aws.amazon.com/directconnect/latest/UserGuide/)로 On-Prem ↔ VPC 통신 확인
- On-Prem GPU 머신: Ubuntu 22.04+, NVIDIA Driver 설치
- CNI: EKS Cilium (VTEP 지원, v1.17.x 이상)

## Design Decisions

| 결정 | 선택 | 이유 |
|------|------|------|
| On-Prem 통합 | EKS Hybrid Nodes (별도 클러스터 대신) | 단일 컨트롤 플레인으로 통합 스케줄링. 별도 클러스터는 이중 관리 부담이 크다 |
| Pod 네트워킹 | [Hybrid Nodes Gateway](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-gateway-overview.html) | VXLAN 터널로 VPC ↔ On-Prem Pod 라우팅을 자동화한다. BGP/Static Route 수동 설정이 불필요하다 |
| On-Prem GPU 용도 | 단일 GPU 전용 (분산학습 제외) | DX 레이턴시(수 ms)가 NCCL 통신에 치명적이다. eval, 디버깅, 시각화에 적합하다 |
| 스케줄링 격리 | Taint + NodeSelector | 분산학습 Pod가 On-Prem 노드에 실수로 스케줄링되는 것을 방지한다 |
| 노드 등록 | SSM Hybrid Activation | On-Prem 노드에 별도 VPN 없이 SSM으로 안전하게 EKS에 등록할 수 있다 |

---

## Service Flow

### Hybrid Node 등록 흐름

```
On-Prem GPU Machine (RTX Pro 6000)
  │
  │ 1. Install SSM Agent + Hybrid Activation
  ▼
AWS Systems Manager
  │
  │ 2. Register as EKS node via nodeadm
  ▼
EKS Control Plane
  │
  │ 3. kubelet connects, node registered
  ▼
kubectl get nodes
  NAME              STATUS   ROLES    LABELS
  ip-10-100-0-xx    Ready    <none>   node-type=gpu
  ip-10-100-1-xx    Ready    <none>   node-type=management
  onprem-gpu-01     Ready    <none>   node-type=onprem-gpu    ◄── Hybrid Node
  onprem-gpu-02     Ready    <none>   node-type=onprem-gpu
  ...
```

### Hybrid Nodes Gateway 아키텍처

```
┌─────────────────────────────────────────────────────────────────────┐
│  AWS VPC (10.100.0.0/21)                                            │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Management Subnet (10.100.1.0/24)                           │   │
│  │                                                              │   │
│  │  ┌─────────────────────┐  ┌─────────────────────┐           │   │
│  │  │ Gateway Pod (Active) │  │ Gateway Pod (Standby)│           │   │
│  │  │                     │  │                     │           │   │
│  │  │ VXLAN Tunnel ───────┼──┼─────────────────────┼───┐       │   │
│  │  │ VPC Route Mgmt      │  │ Full VTEP State      │   │       │   │
│  │  │ CiliumVTEPConfig    │  │ (failover: 3-5s)    │   │       │   │
│  │  └─────────────────────┘  └─────────────────────┘   │       │   │
│  │                                                      │       │   │
│  │  ClickHouse  MLflow  Grafana  (← Pod 통신 자동 라우팅) │       │   │
│  └──────────────────────────────────────────────────────┘       │   │
│                                                                     │
│  VPC Route Table (Gateway 자동 관리)                                 │
│    On-Prem Pod CIDR → Gateway ENI (active)                          │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
                    Direct Connect (VXLAN over DX, UDP 8472)
                           │
┌──────────────────────────┴──────────────────────────────────────────┐
│  On-Prem (10.200.0.0/21)                                            │
│                                                                     │
│  ┌──────────────┐  ┌──────────────┐         ┌──────────────┐       │
│  │ onprem-gpu-01│  │ onprem-gpu-02│  ...    │ onprem-gpu-15│       │
│  │ RTX Pro 6000 │  │ RTX Pro 6000 │         │ RTX Pro 6000 │       │
│  │              │  │              │         │              │       │
│  │ Cilium Agent │  │ Cilium Agent │         │ Cilium Agent │       │
│  │ (VTEP 활성)  │  │ (VTEP 활성)  │         │ (VTEP 활성)  │       │
│  └──────────────┘  └──────────────┘         └──────────────┘       │
│                                                                     │
│  Pod CIDR: Cilium 자동 할당 (CiliumNode CRD)                         │
│  라우팅: Gateway VXLAN 자동 — BGP/Static Route 불필요                  │
└─────────────────────────────────────────────────────────────────────┘
```

### Gateway 이전/이후 비교

| 항목 | Gateway 이전 (수동) | Gateway 이후 (자동) |
|------|-------------------|--------------------|
| VPC Route Table에 Pod CIDR 추가 | 수동 (노드별 static route) | **자동** — Gateway가 CiliumNode watch |
| On-Prem 라우터 Per-Node 라우트 | 수동 설정 또는 BGP | **불필요** — VXLAN 터널 |
| Cilium BGP 설정 | 필요 (Pod CIDR 광고) | **불필요** — Gateway가 대체 |
| Webhook (VPC → On-Prem Pod) | Pod CIDR 라우팅 필수 | **자동** — VXLAN 경유 |
| ALB/NLB → Hybrid Pod | 불가 | **가능** — Gateway ENI 경유 |
| AMP → Hybrid Pod 스크래핑 | Pod CIDR 라우팅 필수 | **자동** — VXLAN 경유 |
| 노드 추가/제거 시 라우트 업데이트 | 수동 | **자동** |

### 트래픽 흐름

```
VPC → On-Prem Pod:
  VPC Route Table → Gateway ENI → VXLAN 캡슐화 (UDP 8472) → DX → Cilium 디캡슐화 → Pod

On-Prem Pod → VPC:
  Cilium (CiliumVTEPConfig 참조) → VXLAN 캡슐화 → DX → Gateway 디캡슐화 → VPC 네트워크

On-Prem Pod → On-Prem Pod (같은/다른 노드):
  표준 Cilium VXLAN overlay (Gateway 미경유)
```

### On-Prem → AWS 서비스 접근 경로

```
On-Prem GPU Node
  │
  ├── kubectl/kubelet ──── DX ────▶ EKS API (VPC Endpoint)
  │
  ├── docker pull ──────── DX ────▶ ECR (VPC Endpoint)
  │
  ├── checkpoint download ── DX ────▶ S3 (Gateway Endpoint)
  │
  ├── metrics push ──── VXLAN/DX ──▶ ClickHouse Pod (Management Subnet)
  │
  └── experiment log ── VXLAN/DX ──▶ MLflow Pod (Management Subnet)
```

### 스케줄링 격리

```
                     ┌─────────────────────────────────┐
                     │      Kubernetes Scheduler       │
                     └──────────┬──────────────────────┘
                                │
              ┌─────────────────┼───────────────────┐
              │                 │                   │
              ▼                 ▼                   ▼
    ┌──────────────┐  ┌──────────────┐   ┌────────────────┐
    │ AWS GPU Node │  │ Management   │   │ On-Prem GPU    │
    │              │  │ Node         │   │ Node           │
    │ Taint:       │  │              │   │ Taint:         │
    │ nvidia.com/  │  │ No Taint     │   │ workload-type= │
    │ gpu=:NoSched │  │              │   │ onprem-single- │
    │              │  │              │   │ gpu:NoSchedule │
    │ ✓ Distributed │  │ ✓ Mgmt Pods  │   │                │
    │ ✓ Multi-GPU   │  │ ✓ System Pods│   │ ✓ Single GPU   │
    │ ✗ Mgmt Pods   │  │ ✓ Gateway    │   │ ✗ Distributed  │
    │              │  │ ✗ GPU Jobs   │   │ ✗ Gateway      │
    └──────────────┘  └──────────────┘   └────────────────┘
```

---

## Steps

### 3-1. EKS Hybrid Nodes 활성화

```
1. EKS 클러스터에서 Hybrid Nodes 기능 활성화
2. Remote Node Network CIDR 등록 (On-Prem CIDR: 10.200.0.0/21)
3. IAM Role 생성: HybridNodeRole
   - eks:DescribeCluster
   - ecr:GetAuthorizationToken
   - ecr:BatchGetImage
   - s3:GetObject (training-data, checkpoints 버킷)
```

### 3-2. SSM Hybrid Activation

[SSM Hybrid Activation](https://docs.aws.amazon.com/systems-manager/latest/userguide/sysman-managed-instance-activation.html)을 사용하여 On-Prem 머신을 등록한다.

```
1. SSM Hybrid Activation 생성
   - IAM Role: HybridNodeRole
   - Registration Limit: 20 (15대 + 여유)
   - Expiration: 30일 (이후 재발급)

2. 각 On-Prem 머신에서:
   - SSM Agent 설치
   - Activation Code/ID로 등록
   - nodeadm 설치 및 EKS 노드 등록
```

각 On-Prem 머신에서 [nodeadm](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-nodeadm.html)을 사용하여 EKS 노드로 등록한다.

### 3-3. On-Prem 노드 레이블 및 Taint 설정

```yaml
Labels:
  node-type: onprem-gpu
  gpu-model: rtx-pro-6000

Taints:
  - key: workload-type
    value: onprem-single-gpu
    effect: NoSchedule
```

On-Prem 노드에는 분산학습 작업이 스케줄링되지 않도록 Taint를 설정한다. 단일 GPU 작업만 toleration으로 명시적 허용한다.

### 3-4. Hybrid Nodes Gateway 배포

[EKS Hybrid Nodes Gateway](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-gateway-overview.html)를 배포하여 VPC ↔ On-Prem Pod 간 네트워킹을 자동화한다. Gateway는 VXLAN 터널(UDP 8472)을 통해 Pod CIDR 라우팅을 자동 관리한다.

#### 3-4-1. Security Group 업데이트

Gateway EC2 노드와 On-Prem 방화벽에 VXLAN 포트를 허용한다.

```
SG-Mgmt-Node (Gateway가 배포되는 Management 노드):
  Inbound:  UDP 8472 from 10.200.0.0/21 (On-Prem CIDR)
  Outbound: UDP 8472 to 10.200.0.0/21

On-Prem Firewall:
  Inbound:  UDP 8472 from 10.100.1.0/24 (Management Subnet)
  Outbound: UDP 8472 to 10.100.1.0/24
```

#### 3-4-2. Gateway 노드 준비

Gateway Pod는 Management 노드그룹의 EC2 인스턴스에서 실행된다. 2대에 라벨을 추가한다.

```bash
# Management 노드 중 2대에 Gateway 라벨 적용 (서로 다른 AZ 권장)
kubectl label node <mgmt-node-1> hybrid-gateway-node=true
kubectl label node <mgmt-node-2> hybrid-gateway-node=true
```

Gateway 노드의 Primary ENI에서 Source/Destination Check를 비활성화한다.

```bash
# 각 Gateway 노드의 ENI ID 확인 후
aws ec2 modify-instance-attribute \
  --instance-id <INSTANCE_ID> \
  --no-source-dest-check
```

#### 3-4-3. Gateway IAM 설정

Gateway Pod가 VPC Route Table을 관리하기 위한 IAM 권한이 필요하다. [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)를 사용한다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeRouteTables",
        "ec2:CreateRoute",
        "ec2:ReplaceRoute",
        "ec2:DescribeInstances"
      ],
      "Resource": "*"
    }
  ]
}
```

#### 3-4-4. Helm 설치

```bash
helm install eks-hybrid-nodes-gateway \
  oci://public.ecr.aws/eks/eks-hybrid-nodes-gateway \
  --version 1.0.0 \
  --namespace eks-hybrid-nodes-gateway \
  --create-namespace \
  --set autoMode.enabled=false \
  --set vpcCIDR=10.100.0.0/21 \
  --set podCIDRs=<ON_PREM_POD_CIDRS> \
  --set routeTableIDs=<VPC_ROUTE_TABLE_IDS>
```

| Helm Value | 필수 | 설명 |
|------------|:---:|------|
| `vpcCIDR` | O | VPC CIDR (10.100.0.0/21) |
| `podCIDRs` | O | On-Prem Hybrid Node의 Pod CIDR (Cilium 할당) |
| `routeTableIDs` | O | Gateway가 관리할 VPC Route Table ID |
| `autoMode.enabled` | - | `false` (Managed Node Group 사용 시) |
| `replicas` | - | `2` (기본값, active-standby) |
| `nodeLabel` | - | `hybrid-gateway-node` (기본값) |

#### 3-4-5. Gateway 배포 검증

```bash
# Gateway Pod 상태 확인
kubectl get pods -n eks-hybrid-nodes-gateway
# NAME                                        READY   STATUS    AGE
# eks-hybrid-nodes-gateway-xxxxxxxxxx-xxxxx   1/1     Running   (active)
# eks-hybrid-nodes-gateway-xxxxxxxxxx-xxxxx   1/1     Running   (standby)

# CiliumVTEPConfig 생성 확인
kubectl get ciliumvtepconfig

# VPC Route Table에 On-Prem Pod CIDR 라우트 자동 생성 확인
aws ec2 describe-route-tables --route-table-ids <ROUTE_TABLE_ID> \
  --query 'RouteTables[].Routes[?DestinationCidrBlock!=`0.0.0.0/0`]'
```

#### 3-4-6. Cilium VTEP 설정 확인

On-Prem Hybrid Node의 Cilium Agent에 VTEP가 활성화되어 있는지 확인한다.

```bash
# Hybrid Node에서 Cilium 상태 확인
cilium status --verbose | grep VTEP

# VXLAN 터널 인터페이스 확인
ip link show hybrid_vxlan0
# hybrid_vxlan0: <BROADCAST,MULTICAST,UP> mtu 1450 ... vxlan id 2 ... dstport 8472
```

### 3-5. NVIDIA Device Plugin 확인

[NVIDIA Device Plugin](https://github.com/NVIDIA/k8s-device-plugin)이 On-Prem 노드에서 정상 동작하는지 확인한다.

```
1. On-Prem 노드에 NVIDIA Device Plugin DaemonSet 배포
2. kubectl describe node <onprem-node> 에서 nvidia.com/gpu 리소스 확인
3. GPU 할당 테스트 Pod 배포
```

### 3-6. On-Prem 네트워크 검증

| 테스트 | 명령 | 기대 결과 |
|--------|------|-----------|
| VPC 통신 | ping 10.100.1.x (Management 노드) | 응답 |
| S3 접근 | aws s3 ls s3://{prefix}-checkpoints | 목록 표시 |
| ECR 접근 | docker pull {account}.dkr.ecr.{region}.amazonaws.com/isaac-lab-training | 이미지 다운로드 |
| DNS 해석 | nslookup grafana.internal | ALB IP 반환 |
| ClickHouse | curl http://clickhouse.internal:8123/ping | Ok |
| **Gateway VXLAN** | **kubectl exec (on-prem pod) -- curl clickhouse.logging.svc.cluster.local:8123/ping** | **Ok (Pod-to-Pod via VXLAN)** |
| **VPC → On-Prem Pod** | **kubectl exec (vpc pod) -- curl \<on-prem-pod-ip\>:\<port\>** | **응답 (Gateway 경유)** |

### 3-7. On-Prem 워크로드 정의

On-Prem GPU는 단일 GPU 작업만 실행한다.

| 작업 | GPU | 설명 |
|------|-----|------|
| 모델 평가 (eval) | 1 | S3에서 체크포인트 다운로드 → 시뮬 실행 → 결과 ClickHouse 전송 |
| 코드 테스트 | 1 | 수정 후 50-100 iter 빠른 검증 |
| 디버깅 | 1 | num_envs=1로 step-by-step |
| 시각화/녹화 | 1 | 학습된 정책 렌더링 영상 생성 |
| 소규모 HPO 사전탐색 | 1 | trial당 GPU 1개, 짧은 iteration |

### 3-8. 샘플 작업 테스트

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: onprem-gpu-test
spec:
  template:
    spec:
      nodeSelector:
        node-type: onprem-gpu
      tolerations:
        - key: workload-type
          value: onprem-single-gpu
          effect: NoSchedule
      containers:
        - name: gpu-test
          image: nvidia/cuda:12.4.0-base-ubuntu22.04
          command: ["nvidia-smi"]
          resources:
            limits:
              nvidia.com/gpu: 1
      restartPolicy: Never
```

### 3-9. Gateway 모니터링

Gateway는 Prometheus 메트릭을 `:10080/metrics`로 노출한다. 기존 Prometheus 스택에 scrape target으로 추가한다.

```yaml
# prometheus-additional-scrape-configs
- job_name: hybrid-nodes-gateway
  kubernetes_sd_configs:
    - role: pod
      namespaces:
        names:
          - eks-hybrid-nodes-gateway
  relabel_configs:
    - source_labels: [__meta_kubernetes_pod_container_port_number]
      regex: "10080"
      action: keep
```

주요 메트릭:

| 메트릭 | 설명 |
|--------|------|
| VTEP operations | VXLAN 터널 생성/삭제 횟수 |
| Leader state | Active/Standby 상태 |
| Route table updates | VPC Route 생성/교체 횟수 |
| VXLAN rx/tx | 터널 트래픽 송수신량 |

---

## References

- [EKS Hybrid Nodes](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-overview.html)
- [EKS Hybrid Nodes Gateway](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-gateway-overview.html)
- [eks-hybrid-nodes-gateway (GitHub)](https://github.com/aws/eks-hybrid-nodes-gateway)
- [SSM Hybrid Activation](https://docs.aws.amazon.com/systems-manager/latest/userguide/sysman-managed-instance-activation.html)
- [nodeadm](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-nodeadm.html)
- [NVIDIA Device Plugin](https://github.com/NVIDIA/k8s-device-plugin)
- [Direct Connect](https://docs.aws.amazon.com/directconnect/latest/UserGuide/)
- [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [Cilium VTEP](https://docs.cilium.io/en/stable/network/vtep/)

## Validation Checklist

### Hybrid Nodes 등록
- [ ] On-Prem 노드 15대 EKS에 등록 (kubectl get nodes)
- [ ] nvidia.com/gpu 리소스 표시 확인
- [ ] Node Labels/Taints 적용 확인
- [ ] 단일 GPU 테스트 Job 성공
- [ ] 분산학습 Pod가 On-Prem 노드에 스케줄링되지 않는 것 확인

### Hybrid Nodes Gateway
- [ ] Gateway Pod 2대 Running (active-standby)
- [ ] CiliumVTEPConfig CRD 생성 확인
- [ ] VPC Route Table에 On-Prem Pod CIDR 라우트 자동 생성
- [ ] On-Prem Hybrid Node에서 VXLAN 인터페이스 (hybrid_vxlan0) 확인
- [ ] VPC Pod → On-Prem Pod 통신 (Gateway VXLAN 경유)
- [ ] On-Prem Pod → VPC Pod 통신 (ClickHouse, MLflow 접근)
- [ ] Gateway failover 테스트 (active Pod 삭제 → standby 승격, 3-5초)
- [ ] Prometheus에서 Gateway 메트릭 수집 확인

### 네트워크
- [ ] DX 경유 S3 접근 확인
- [ ] DX 경유 ECR 이미지 pull 확인
- [ ] Route53 DNS 해석 확인 (On-Prem에서 *.internal)
- [ ] UDP 8472 (VXLAN) 방화벽 양방향 허용 확인

## Next

→ [Phase 4: Gate](004-phase4-gate.md)
