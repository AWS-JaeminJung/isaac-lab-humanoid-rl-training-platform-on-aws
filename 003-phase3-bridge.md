# Phase 3: Bridge

[EKS Hybrid Nodes](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-overview.html) — On-Prem GPU 환경 설정, DX 연결 확인, S3 접근 검증

## Goal

On-Prem RTX Pro 6000 머신을 EKS Hybrid Nodes로 등록하여 단일 GPU 작업(eval, 디버깅, 시각화)을 실행할 수 있게 한다.

## Prerequisites

- Phase 2 완료 (EKS 클러스터 운영 중)
- [Direct Connect](https://docs.aws.amazon.com/directconnect/latest/UserGuide/)로 On-Prem ↔ VPC 통신 확인
- On-Prem GPU 머신: Ubuntu 22.04+, NVIDIA Driver 설치

## Design Decisions

| 결정 | 선택 | 이유 |
|------|------|------|
| On-Prem 통합 | EKS Hybrid Nodes (별도 클러스터 대신) | 단일 컨트롤 플레인으로 통합 스케줄링. 별도 클러스터는 이중 관리 부담이 크다 |
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
  ├── metrics push ──────── DX ────▶ ClickHouse Pod (Management Subnet)
  │
  └── experiment log ────── DX ────▶ MLflow Pod (Management Subnet)
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
    │ ✗ Mgmt Pods   │  │ ✗ GPU Jobs   │   │ ✗ Distributed  │
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

### 3-4. NVIDIA Device Plugin 확인

[NVIDIA Device Plugin](https://github.com/NVIDIA/k8s-device-plugin)이 On-Prem 노드에서 정상 동작하는지 확인한다.

```
1. On-Prem 노드에 NVIDIA Device Plugin DaemonSet 배포
2. kubectl describe node <onprem-node> 에서 nvidia.com/gpu 리소스 확인
3. GPU 할당 테스트 Pod 배포
```

### 3-5. On-Prem 네트워크 검증

| 테스트 | 명령 | 기대 결과 |
|--------|------|-----------|
| VPC 통신 | ping 10.100.1.x (Management 노드) | 응답 |
| S3 접근 | aws s3 ls s3://{prefix}-checkpoints | 목록 표시 |
| ECR 접근 | docker pull {account}.dkr.ecr.{region}.amazonaws.com/isaac-lab-training | 이미지 다운로드 |
| DNS 해석 | nslookup grafana.internal | ALB IP 반환 |
| ClickHouse | curl http://clickhouse.internal:8123/ping | Ok |

### 3-6. On-Prem 워크로드 정의

On-Prem GPU는 단일 GPU 작업만 실행한다.

| 작업 | GPU | 설명 |
|------|-----|------|
| 모델 평가 (eval) | 1 | S3에서 체크포인트 다운로드 → 시뮬 실행 → 결과 ClickHouse 전송 |
| 코드 테스트 | 1 | 수정 후 50-100 iter 빠른 검증 |
| 디버깅 | 1 | num_envs=1로 step-by-step |
| 시각화/녹화 | 1 | 학습된 정책 렌더링 영상 생성 |
| 소규모 HPO 사전탐색 | 1 | trial당 GPU 1개, 짧은 iteration |

### 3-7. 샘플 작업 테스트

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

---

## References

- [EKS Hybrid Nodes](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-overview.html)
- [SSM Hybrid Activation](https://docs.aws.amazon.com/systems-manager/latest/userguide/sysman-managed-instance-activation.html)
- [nodeadm](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-nodeadm.html)
- [NVIDIA Device Plugin](https://github.com/NVIDIA/k8s-device-plugin)
- [Direct Connect](https://docs.aws.amazon.com/directconnect/latest/UserGuide/)

## Validation Checklist

- [ ] On-Prem 노드 15대 EKS에 등록 (kubectl get nodes)
- [ ] nvidia.com/gpu 리소스 표시 확인
- [ ] Node Labels/Taints 적용 확인
- [ ] DX 경유 S3 접근 확인
- [ ] DX 경유 ECR 이미지 pull 확인
- [ ] Route53 DNS 해석 확인 (On-Prem에서 *.internal)
- [ ] 단일 GPU 테스트 Job 성공
- [ ] 분산학습 Pod가 On-Prem 노드에 스케줄링되지 않는 것 확인

## Next

→ [Phase 4: Gate](004-phase4-gate.md)
