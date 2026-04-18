# Phase 5: Orchestrator

워크플로우 엔진 — [NVIDIA OSMO](https://docs.nvidia.com/osmo/) Controller, [KubeRay](https://docs.ray.io/en/latest/cluster/kubernetes/index.html) Operator, RBAC, CPU 테스트

## Goal

학습 워크플로우를 제출하고 관리하는 오케스트레이션 계층을 구축한다. GPU 투입 전 CPU 모드로 파이프라인을 검증한다.

## Prerequisites

- Phase 2 완료 (EKS, [Karpenter](https://karpenter.sh/docs/))
- Phase 4 완료 (Keycloak OIDC 클라이언트: osmo-api, ray-dashboard)
- ECR에 학습 이미지 push 완료

---

## Service Flow

### 워크플로우 제출 → 실행 흐름

```
연구자 (JupyterHub 또는 CLI)
  │
  │  POST /api/workflows
  │  Authorization: Bearer <jwt>
  ▼
┌───────────────────────────────────────────────────────────┐
│ OSMO Controller (Management Subnet)                       │
│                                                           │
│  1. JWT 검증 (Keycloak issuer)                           │
│  2. gpu_quota 확인 (researcher: 4, engineer: 10)         │
│  3. 워크플로우 파라미터 검증                              │
│  4. RayJob CRD 생성                                      │
└───────────────────┬───────────────────────────────────────┘
                    │
                    │ RayJob CRD
                    ▼
┌───────────────────────────────────────────────────────────┐
│ KubeRay Operator                                          │
│                                                           │
│  1. RayJob 감지                                          │
│  2. Ray Cluster 생성 (Head + Workers)                    │
│  3. 학습 entrypoint 실행                                 │
│  4. 완료 후 Ray Cluster 자동 삭제                        │
└───────────────────┬───────────────────────────────────────┘
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
┌──────────────┐      ┌──────────────────────────────────┐
│ Ray Head     │      │ Ray Workers (GPU Nodes)           │
│ (Mgmt Node)  │      │                                   │
│              │      │  Karpenter가 g6e.48xlarge         │
│ Dashboard    │◄────▶│  프로비저닝                       │
│ GCS          │ :6379│                                   │
│ :8265        │      │  Worker 1: 8x L40S                │
│              │      │  Worker 2: 8x L40S                │
│              │      │  ...                               │
└──────────────┘      └──────────────────────────────────┘
```

### GPU 프로비저닝 흐름

```
RayJob 생성 (gpu: 8, num_nodes: 2)
  │
  ▼
Kubernetes Scheduler
  │  Pending Pod (nvidia.com/gpu: 8)
  ▼
Karpenter
  │  1. Pending Pod 감지
  │  2. NodePool: gpu-pool 매칭
  │  3. EC2 API → g6e.48xlarge 시작
  │  4. EFA 활성화, FSx mount
  ▼
GPU Node Ready
  │
  ▼
Pod Scheduled → 학습 시작
  │
  │  (학습 완료)
  ▼
Ray Cluster 삭제
  │
  ▼
Karpenter consolidation
  │  consolidateAfter: 5m
  ▼
GPU Node 종료 (비용 절감)
```

### 학습 실행 중 데이터 흐름

```
┌─ Ray Worker Pod (GPU Node) ─────────────────────────────────┐
│                                                              │
│  Isaac Lab + rsl_rl 학습 루프                               │
│    │                                                         │
│    ├── 체크포인트 저장 ──▶ /mnt/fsx/checkpoints/            │
│    │                          │                              │
│    │                     FSx → S3 (비동기 백업)             │
│    │                                                         │
│    ├── 콜백 (10 iter 배치) ──▶ ClickHouse (HTTP :8123)     │
│    │   training_metrics        (Phase 7)                     │
│    │                                                         │
│    ├── 학습 완료 시 ──────▶ MLflow (HTTPS)                  │
│    │   params, final metrics    (Phase 6)                    │
│    │   model artifact → S3                                   │
│    │                                                         │
│    └── stdout ──▶ Fluent Bit ──▶ ClickHouse                 │
│                   (DaemonSet)   training_raw_logs (Phase 7)  │
└──────────────────────────────────────────────────────────────┘
```

---

## Steps

### 5-1. KubeRay Operator 설치

```
1. Helm 설치
   helm repo add kuberay https://ray-project.github.io/kuberay-helm/
   helm install kuberay-operator kuberay/kuberay-operator \
     --namespace ray-system --create-namespace

2. CRD 확인
   - RayCluster
   - RayJob
   - RayService
```

[KubeRay Operator](https://docs.ray.io/en/latest/cluster/kubernetes/index.html)는 [RayJob](https://docs.ray.io/en/latest/cluster/kubernetes/getting-started/rayjob-quick-start.html) CRD를 watch하여 [Ray](https://docs.ray.io/en/latest/) 클러스터를 자동 생성/삭제한다. [KubeRay Helm Chart](https://ray-project.github.io/kuberay/) `v1.6.0` 버전을 사용한다.

### 5-2. Ray 클러스터 구성 템플릿

```yaml
# GPU 학습용 Ray 클러스터 템플릿
headGroupSpec:
  rayStartParams:
    dashboard-host: "0.0.0.0"
  template:
    spec:
      nodeSelector:
        node-type: management
      containers:
        - name: ray-head
          image: {ecr}/isaac-lab-training:latest
          resources:
            requests:
              cpu: "4"
              memory: "16Gi"
          ports:
            - containerPort: 6379   # GCS
            - containerPort: 8265   # Dashboard

workerGroupSpecs:
  - groupName: gpu-workers
    replicas: 1
    minReplicas: 1
    maxReplicas: 10
    rayStartParams: {}
    template:
      spec:
        nodeSelector:
          node-type: gpu
        tolerations:
          - key: nvidia.com/gpu
            operator: Exists
            effect: NoSchedule
        containers:
          - name: ray-worker
            image: {ecr}/isaac-lab-training:latest
            resources:
              requests:
                cpu: "48"
                memory: "384Gi"
                nvidia.com/gpu: "8"
              limits:
                nvidia.com/gpu: "8"
            volumeMounts:
              - name: fsx
                mountPath: /mnt/fsx
        volumes:
          - name: fsx
            persistentVolumeClaim:
              claimName: fsx-pvc
```

### 5-3. NVIDIA OSMO Controller 설치

```
1. OSMO Controller 배포
   Namespace: osmo-system
   Node Selector: node-type=management
   Resources:
     CPU: 1
     Memory: 2Gi

2. OSMO 설정
   - KubeRay 연동 (RayJob CRD 생성)
   - Keycloak OIDC 연동 (Bearer token 검증)
   - GPU 쿼터 적용 (JWT gpu_quota claim)
   - Namespace isolation
```

### 5-4. OSMO API Ingress

[AWS ALB Ingress](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)를 통해 OSMO API를 노출한다.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: osmo-api
  namespace: osmo-system
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internal
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: {acm-cert-arn}
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
spec:
  rules:
    - host: osmo.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: osmo-api
                port:
                  number: 8080
```

### 5-5. Ray Dashboard Ingress

```yaml
spec:
  rules:
    - host: ray.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ray-head-svc
                port:
                  number: 8265
```

Ray Dashboard에 Keycloak OIDC 인증을 적용한다 (OAuth2 Proxy 또는 Ray 자체 인증).

### 5-6. RBAC 설정

```yaml
# 학습 작업 실행을 위한 Namespace
apiVersion: v1
kind: Namespace
metadata:
  name: training

---
# ResourceQuota (네임스페이스별 GPU 상한)
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gpu-quota
  namespace: training
spec:
  hard:
    requests.nvidia.com/gpu: "80"
    limits.nvidia.com/gpu: "80"
```

### 5-7. ECR 학습 이미지 준비

```dockerfile
# 기존 테스트 이미지 기반
FROM nvcr.io/nvidia/isaac-lab:2.2.0

# 추가 패키지
RUN pip install \
    ray[default]==2.42.1 \
    clickhouse-connect \
    mlflow \
    boto3

# 학습 스크립트
COPY scripts/ /workspace/scripts/

# ClickHouse Logger 콜백
COPY callbacks/ /workspace/callbacks/
```

```
docker build -t {ecr}/isaac-lab-training:v1.0.0 .
docker push {ecr}/isaac-lab-training:v1.0.0
```

### 5-8. CPU 모드 테스트 (GPU 없이 파이프라인 검증)

GPU를 투입하기 전에 CPU 모드로 전체 파이프라인을 검증한다.

```yaml
# CPU-only 테스트 RayJob
apiVersion: ray.io/v1
kind: RayJob
metadata:
  name: cpu-pipeline-test
  namespace: training
spec:
  entrypoint: >
    python /workspace/scripts/train.py
    --task H1-v0
    --num_envs 4
    --max_iterations 10
    --headless
    --device cpu
  rayClusterSpec:
    headGroupSpec:
      template:
        spec:
          nodeSelector:
            node-type: management
          containers:
            - name: ray-head
              image: {ecr}/isaac-lab-training:v1.0.0
              resources:
                requests:
                  cpu: "2"
                  memory: "4Gi"
```

검증 항목:
- RayJob 생성 → Ray 클러스터 자동 생성
- 학습 스크립트 실행 (CPU, 짧은 iteration)
- ClickHouse에 메트릭 기록 확인 (Phase 7 이후)
- MLflow에 실험 기록 확인 (Phase 6 이후)
- 작업 완료 후 Ray 클러스터 자동 삭제

### 5-9. Route53 레코드

```
osmo.internal → Internal ALB (Alias)
ray.internal  → Internal ALB (Alias)
```

---

## References

- [NVIDIA OSMO](https://docs.nvidia.com/osmo/)
- [KubeRay](https://docs.ray.io/en/latest/cluster/kubernetes/index.html)
- [KubeRay Helm Chart](https://ray-project.github.io/kuberay/)
- [Ray](https://docs.ray.io/en/latest/)
- [RayJob Quick Start](https://docs.ray.io/en/latest/cluster/kubernetes/getting-started/rayjob-quick-start.html)
- [Karpenter](https://karpenter.sh/docs/)
- [AWS ALB Ingress Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)

## Validation Checklist

- [ ] KubeRay Operator 정상 Running
- [ ] OSMO Controller 정상 Running
- [ ] RayJob CRD 생성 가능
- [ ] https://osmo.internal API 접근 확인
- [ ] https://ray.internal Dashboard 접근 확인
- [ ] OIDC 인증 동작 (Keycloak 토큰으로 API 호출)
- [ ] GPU 쿼터 적용 확인
- [ ] CPU 모드 RayJob 제출 → 실행 → 완료 → 클러스터 삭제
- [ ] ECR 이미지 pull 성공 (VPC Endpoint 경유)
- [ ] RBAC: training namespace 리소스 쿼터 적용 확인

## Next

→ [Phase 6: Registry](phase6-registry.md)
