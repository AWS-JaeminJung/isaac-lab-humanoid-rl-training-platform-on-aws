# Isaac Lab Production Architecture Diagrams

## 1. Full Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│  ON-PREMISES (10.200.0.0/21)                                                            │
│                                                                                         │
│  ┌───────────┐   ┌──────────────────────────────────────────────────────────────┐       │
│  │  AD Server │   │  RTX Pro 6000 x15 (단일 GPU 작업 전용)                      │       │
│  │  (LDAP)    │   │  eval, debug, 시각화, 소규모 HPO 사전탐색                   │       │
│  └─────┬─────┘   │                                                              │       │
│        │          │  ClickHouse Logger ──→ (DX) ──→ ClickHouse                  │       │
│        │          │  S3 checkpoint pull ←── (DX) ←── S3                          │       │
│        │          └──────────────────────────────────┬───────────────────────────┘       │
│        │                                             │                                   │
│  ┌─────┴─────┐   ┌──────────────┐                   │                                   │
│  │ 연구자     │   │ Proxy / FW   │──── Internet      │                                   │
│  │ (브라우저) │   │ (외부 트래픽)│                    │                                   │
│  └─────┬─────┘   └──────┬───────┘                    │                                   │
│        │                │                             │                                   │
│  ======│================│=============================│================================  │
│        │    Direct Connect (전용선)                   │   Site-to-Site VPN (백업)         │
│  ======│================│=============================│================================  │
└────────│────────────────│─────────────────────────────│──────────────────────────────────┘
         │                │                             │
┌────────│────────────────│─────────────────────────────│──────────────────────────────────┐
│  AWS VPC (10.100.0.0/21)│  Single AZ: us-east-1a     │                                  │
│        │                │                             │                                  │
│  ┌─────┴────────────────┴─────────────────────────────┘                                  │
│  │  Virtual Private Gateway (vgw)                                                        │
│  └─────┬──────────────────────────────────────────────────────────────────────────────┐  │
│        │                                                                              │  │
│  ┌─────┴──────────────────────────────────────────────────────────────────────────┐   │  │
│  │  INFRASTRUCTURE SUBNET (10.100.2.0/24)                                         │   │  │
│  │                                                                                │   │  │
│  │  ┌────────────┐  ┌──────────┐  ┌───────────┐  ┌──────────────────────────────┐│   │  │
│  │  │ Internal   │  │ RDS      │  │ FSx for   │  │ VPC Endpoints (x18)          ││   │  │
│  │  │ ALB        │  │ Postgres │  │ Lustre    │  │                              ││   │  │
│  │  │            │  │          │  │           │  │ ECR, EKS, S3, STS, EC2,      ││   │  │
│  │  │ *.internal │  │ Keycloak │  │ /mnt/fsx/ │  │ ELB, Logs, Monitoring,       ││   │  │
│  │  │ Route53    │  │ DB +     │  │ ├ ckpt/   │  │ SSM, SQS, FSx, KMS,         ││   │  │
│  │  │ Private HZ │  │ MLflow   │  │ ├ data/   │  │ SecretsManager, Autoscaling  ││   │  │
│  │  │            │  │ DB       │  │ └ shared/  │  │                              ││   │  │
│  │  └──────┬─────┘  └─────────┘  └───────┬───┘  └──────────────────────────────┘│   │  │
│  │         │                              │         ▲                             │   │  │
│  └─────────│──────────────────────────────│─────────│─────────────────────────────┘   │  │
│            │                              │         │                                 │  │
│            │  ┌───────────────────────────│─────────│──────────────────────────────┐  │  │
│            │  │  MANAGEMENT SUBNET (10.100.1.0/24)  │                              │  │  │
│            │  │  Node: m6i.2xlarge x3~5             │                              │  │  │
│            │  │                                     │                              │  │  │
│            │  │  ┌─────────── Auth ──────────────┐  │                              │  │  │
│            │  │  │                               │  │                              │  │  │
│  ┌─── OIDC─│──│──│── Keycloak (x2 HA) ←── AD (LDAP via DX)                       │  │  │
│  │         │  │  │       │                       │  │                              │  │  │
│  │         │  │  │  OIDC │ Token Validation      │  │                              │  │  │
│  │         │  │  │       ▼                       │  │                              │  │  │
│  │         │  │  ├─────────── User Interface ────│──│──────────────────────────┐   │  │  │
│  │         │  │  │                               │  │                          │   │  │  │
│  │         ▼  │  │  JupyterHub ──→ OSMO API ─────│──│──→ (워크플로우 제출)     │   │  │  │
│  │  ALB ──────│──│──→ *.internal   │             │  │                          │   │  │  │
│  │         │  │  │                 ▼             │  │                          │   │  │  │
│  │         │  │  ├─── Workflow Engine ───────────│──│──────────────────────┐   │   │  │  │
│  │         │  │  │                               │  │                      │   │   │  │  │
│  │         │  │  │  OSMO Controller              │  │                      │   │   │  │  │
│  │         │  │  │       │                       │  │                      │   │   │  │  │
│  │         │  │  │       ▼                       │  │                      │   │   │  │  │
│  │         │  │  │  KubeRay Operator             │  │                      │   │   │  │  │
│  │         │  │  │       │  (RayJob CRD)         │  │                      │   │   │  │  │
│  │         │  │  │       ▼                       │  │                      │   │   │  │  │
│  │         │  │  │  Ray Head (CPU 4, 16Gi)       │  │                      │   │   │  │  │
│  │         │  │  │       │                       │  │                      │   │   │  │  │
│  │         │  │  ├───────│── Data & Logging ─────│──│──────────────────┐   │   │   │  │  │
│  │         │  │  │       │                       │  │                  │   │   │   │  │  │
│  │         │  │  │  ClickHouse (2C,4Gi,EBS 50G)  │  │                  │   │   │   │  │  │
│  │         │  │  │       ▲                       │  │                  │   │   │   │  │  │
│  │         │  │  │       │ HTTP INSERT           │  │                  │   │   │   │  │  │
│  │         │  │  │  MLflow (RDS + S3 artifacts)  │  │                  │   │   │   │  │  │
│  │         │  │  │                               │  │                  │   │   │   │  │  │
│  │         │  │  ├───────│── Monitoring ─────────│──│──────────────┐   │   │   │   │  │  │
│  │         │  │  │       │                       │  │              │   │   │   │   │  │  │
│  │         │  │  │  Grafana ──→ ClickHouse DS    │  │              │   │   │   │   │  │  │
│  │         │  │  │         ──→ Prometheus DS      │  │              │   │   │   │   │  │  │
│  │         │  │  │  Prometheus + AlertManager     │  │              │   │   │   │   │  │  │
│  │         │  │  │  Fluent Bit (DaemonSet)        │  │              │   │   │   │   │  │  │
│  │         │  │  │  Kubecost                      │  │              │   │   │   │   │  │  │
│  │         │  │  │                               │  │              │   │   │   │   │  │  │
│  │         │  │  ├─────────── Infra ─────────────│──│──────────┐   │   │   │   │   │  │  │
│  │         │  │  │                               │  │          │   │   │   │   │   │  │  │
│  │         │  │  │  Karpenter                    │  │          │   │   │   │   │   │  │  │
│  │         │  │  │  ALB Ingress Controller       │  │          │   │   │   │   │   │  │  │
│  │         │  │  │  CoreDNS (x2)                 │  │          │   │   │   │   │   │  │  │
│  │         │  │  │  EBS CSI Driver               │  │          │   │   │   │   │   │  │  │
│  │         │  │  │  FSx CSI Driver               │  │          │   │   │   │   │   │  │  │
│  │         │  │  │  External Secrets Operator     │  │          │   │   │   │   │   │  │  │
│  │         │  │  │                               │  │          │   │   │   │   │   │  │  │
│  │         │  │  └───────────────────────────────┘  │          │   │   │   │   │   │  │  │
│  │         │  └─────────────────────────────────────│──────────│───│───│───│───│───┘  │  │
│  │         │                                        │          │   │   │   │   │      │  │
│  │         │  ┌─────────────────────────────────────│──────────│───│───│───│───│──┐   │  │
│  │         │  │  GPU COMPUTE SUBNET (10.100.0.0/24) │          │   │   │   │   │  │   │  │
│  │         │  │  Node: g6e.48xlarge x0~10 (Karpenter)          │   │   │   │   │  │   │  │
│  │         │  │                                     │          │   │   │   │   │  │   │  │
│  │         │  │  ┌──────────────────┐  ┌────────────│──────────┘   │   │   │   │  │   │  │
│  │         │  │  │  g6e Node 1      │  │  g6e Node 2│              │   │   │   │  │   │  │
│  │         │  │  │  8x L40S + EFA   │  │  8x L40S + EFA           │   │   │   │  │   │  │
│  │         │  │  │                  │  │            │              │   │   │   │  │   │  │
│  │         │  │  │  ┌────────────┐  │  │  ┌────────│──────────┐   │   │   │   │  │   │  │
│  │         │  │  │  │Training Pod│  │  │  │Training│Pod       │   │   │   │   │  │   │  │
│  │         │  │  │  │            │  │  │  │        │          │   │   │   │   │  │   │  │
│  │         │  │  │  │ rsl_rl ────│──│──│──│──NCCL/EFA─────────│   │   │   │   │  │   │  │
│  │         │  │  │  │   │        │  │  │  │        │          │   │   │   │   │  │   │  │
│  │         │  │  │  │   │callback│  │  │  │        │          │   │   │   │   │  │   │  │
│  │         │  │  │  │   ▼        │  │  │  │        │          │   │   │   │   │  │   │  │
│  │         │  │  │  │ CH Logger ─│──│──│──│────────│──────────│───│───│───│───┘  │  │   │  │
│  │         │  │  │  │   │        │  │  │  │        │          │   │   │   │      │  │   │  │
│  │         │  │  │  │   ▼        │  │  │  │        │          │   │   │   │      │  │   │  │
│  │         │  │  │  │ stdout ────│──│──│──│────────│──────────│───│───│───┘      │  │   │  │
│  │         │  │  │  │   │FluentB │  │  │  │        │          │   │   │          │  │   │  │
│  │         │  │  │  │   ▼        │  │  │  │        ▼          │   │   │          │  │   │  │
│  │         │  │  │  │ /mnt/fsx ──│──│──│──│── FSx mount ──────│───┘   │          │  │   │  │
│  │         │  │  │  │            │  │  │  │                   │       │          │  │   │  │
│  │         │  │  │  │ DCGM Exp ──│──│──│──│───────────────────│───────┘          │  │   │  │
│  │         │  │  │  └────────────┘  │  │  └───────────────────┘                  │  │   │  │
│  │         │  │  │                  │  │                                          │  │   │  │
│  │         │  │  │  ... (Node 3~10) │  │                                          │  │   │  │
│  │         │  │  │                  │  │                                          │  │   │  │
│  │         │  │  │  Ray Worker ←────│──│─── Ray Head (Management Subnet)          │  │   │  │
│  │         │  │  └──────────────────┘  └──────────────────────────────────────────┘  │   │  │
│  │         │  └──────────────────────────────────────────────────────────────────────┘   │  │
│  │         │                                                                             │  │
│  │         │   ┌──── S3 (VPC Gateway Endpoint) ──────────────────────────────────────┐   │  │
│  │         │   │  production-checkpoints   (FSx <-> S3 동기화)                       │   │  │
│  │         │   │  production-models        (MLflow 아티팩트)                          │   │  │
│  │         │   │  production-logs-archive  (ClickHouse -> S3, 180일+)                │   │  │
│  │         │   │  production-training-data (학습 데이터 원본)                         │   │  │
│  │         │   └─────────────────────────────────────────────────────────────────────┘   │  │
│  │         │                                                                             │  │
│  │         │   ┌──── ECR (VPC Interface Endpoint) ───────────────────────────────────┐   │  │
│  │         │   │  isaac-lab-training   (학습 이미지)                                  │   │  │
│  │         │   │  jupyter-isaac        (노트북 이미지)                                │   │  │
│  │         │   └─────────────────────────────────────────────────────────────────────┘   │  │
│  │         │                                                                             │  │
│  └─────────┘                                                                             │  │
│                                                                                          │  │
└──────────────────────────────────────────────────────────────────────────────────────────┘  │
                                                                                              │
  Route53 Resolver Inbound Endpoint ←── On-Prem DNS (*.internal 쿼리 전달) ───────────────────┘
```

---

## 2. Authentication Flow

```
┌──────────┐     ┌─────────┐     ┌──────────┐     ┌────────────────────────────┐
│ On-Prem  │     │ Direct  │     │ Internal │     │ Keycloak                   │
│ 연구자   │────→│ Connect │────→│ ALB      │────→│ (OIDC Provider)            │
│ 브라우저 │     │         │     │          │     │                            │
└──────────┘     └─────────┘     └──────────┘     │  ┌────────────────────┐   │
                                                   │  │ Realm:             │   │
                                                   │  │ isaac-lab-prod     │   │
     ┌──────────────────────────────────────────── │  │                    │   │
     │  LDAP Federation (DX 경유, 15분 동기화)     │  │ Identity Provider: │   │
     │                                             │  │ On-Prem AD (LDAPS) │   │
     ▼                                             │  └────────────────────┘   │
┌──────────┐                                       │                            │
│ On-Prem  │                                       │  Clients (OIDC):           │
│ AD Server│                                       │  ├─ jupyterhub             │
│ (LDAP)   │                                       │  ├─ grafana                │
└──────────┘                                       │  ├─ mlflow                 │
                                                   │  ├─ osmo-api (bearer-only) │
  AD Group            Keycloak Role                │  └─ ray-dashboard          │
  ─────────────────── ───────────────              │                            │
  CN=ML-Researchers → researcher                   │  Role → Service 권한:      │
  CN=MLOps-Engineers→ engineer                     │  ├─ researcher: 4 GPU 쿼터 │
  CN=ML-Managers    → viewer                       │  ├─ engineer:  10 GPU 쿼터 │
                                                   │  └─ viewer:    읽기 전용   │
                                                   └────────────────────────────┘
                                                          │
                                        OIDC Token        │
                          ┌───────────────────────────────┤
                          ▼               ▼               ▼
                   ┌────────────┐  ┌───────────┐  ┌────────────┐
                   │ JupyterHub │  │  Grafana   │  │   MLflow   │
                   │            │  │            │  │            │
                   │ researcher │  │ viewer+    │  │ researcher │
                   │ engineer   │  │            │  │ viewer     │
                   └────────────┘  └───────────┘  └────────────┘
```

---

## 3. Training Data Flow

```
연구자 (JupyterHub)
  │
  │  client.submit_workflow(task="H1", num_gpus=4, num_nodes=2)
  ▼
OSMO API ──→ OSMO Controller ──→ RayJob CRD 생성
                                       │
                          KubeRay Operator
                                       │
                    ┌──────────────────┐│┌──────────────────┐
                    │                  │▼│                  │
                    │   Ray Head (CPU) ─┘│                  │
                    │        │          │                  │
                    │   ┌────┴────┐     │                  │
                    │   ▼         ▼     │                  │
                    │  Worker    Worker  │                  │
                    │  GPU 0,1   GPU 2,3│                  │
                    │  (rank 0,1)(rank 2,3)                │
                    │   │         │     │                  │
                    │   └──NCCL/EFA─────┘                  │
                    │   (g6e Node A)    │  (g6e Node B)    │
                    └──────────────────┘└──────────────────┘
                         │         │              │
              ┌──────────┘         │              │
              ▼                    ▼              ▼
    ┌──────────────┐     ┌──────────────┐  ┌──────────┐
    │  ClickHouse  │     │  FSx Lustre  │  │ stdout   │
    │              │     │              │  │          │
    │  콜백 직접   │     │ /mnt/fsx/    │  │ Fluent   │
    │  HTTP INSERT │     │ checkpoints/ │  │ Bit      │
    │              │     │              │  │    │     │
    │ training_    │     │   매 N iter  │  │    ▼     │
    │  metrics     │     │      │       │  │ ClickHouse│
    │              │     │      ▼       │  │ raw_logs │
    └──────┬───────┘     │  ┌───────┐   │  └──────────┘
           │             │  │  S3   │   │
           │             │  │ 백업  │   │
           ▼             │  └───────┘   │
    ┌────────────┐       └──────────────┘
    │  Grafana   │              │
    │  Dashboard │              │  학습 완료 후
    │            │              ▼
    │ - Reward   │       ┌────────────┐
    │ - Loss     │       │  MLflow    │
    │ - GradNorm │       │            │
    │ - GPU Util │       │ 최종 메트릭│
    └────────────┘       │ 모델 등록  │
                         │ S3 artifact│
                         └────────────┘
```

---

## 4. HPO Flow

```
연구자 (JupyterHub)
  │
  │  client.submit_workflow(template="h1-ray-tune", num_trials=8)
  ▼
OSMO ──→ RayJob (tune.py)
              │
              ▼
         Ray Tune (ASHA Scheduler)
              │
    ┌─────────┼─────────┬─────────┬─────────┐
    ▼         ▼         ▼         ▼         │
 Trial 0   Trial 1   Trial 2   Trial 3     ...
 lr=1e-3   lr=5e-4   lr=2e-3   lr=8e-4
 GPU 0,1   GPU 2,3   GPU 4,5   GPU 6,7
    │         │         │         │
    │   ClickHouse: trial_id로 분리 저장
    │         │         │         │
    ▼         ▼         ▼         ▼
 iter 30:  iter 30:  iter 30:  iter 30:    ← ASHA grace period
 reward=2  reward=5  reward=1  reward=4
    │         │         │         │
    ×         │         ×         │         ← 하위 trial 중단
 (stopped)   │      (stopped)    │
              │                   │
              ▼                   ▼
           iter 200:           iter 200:   ← 생존 trial 계속
           reward=16           reward=14
              │                   │
              ▼                   ▼
           MLflow               MLflow
           모델 등록             모델 등록
              │                   │
              ▼                   ▼
         ┌────────────────────────────┐
         │  Grafana HPO Dashboard     │
         │                            │
         │  Trial Ranking:            │
         │  1. Trial 1  reward=16 ✓   │
         │  2. Trial 3  reward=14 ✓   │
         │  3. Trial 0  reward=2  ×30 │
         │  4. Trial 2  reward=1  ×30 │
         │                            │
         │  HP Correlation:           │
         │  lr ● ●  ● ●  r=0.72      │
         └────────────────────────────┘
```

---

## 5. Logging Lifecycle

```
학습 실행
  │
  ▼                              ClickHouse
Day 0 ─────────────────────── training_metrics (구조화 메트릭)
  │                            training_raw_logs (원본 텍스트)
  │                            training_summary  (건당 1행)
  │
  │  Hot (전체 데이터)
  │  EBS gp3, 쿼리 < 1초
  │
Day 90 ──────────────────────  training_raw_logs: TTL 만료, 자동 삭제
  │                            training_metrics: 유지
  │                            training_summary: 유지
  │  Warm (메트릭만)
  │  EBS gp3 (압축)
  │
Day 180 ─────────────────────  training_metrics: S3 Parquet export 후 삭제
  │                            training_summary: 유지 (영구)
  │
  │  Archive (필요시 조회)
  │  S3 → Glacier
  │
Day 365 ─────────────────────  S3 Glacier 보관 또는 삭제
  │
  ▼
  ∞  training_summary만 영구 보관 (학습 건당 1행, 용량 미미)
```

---

## 6. Network & Security Groups

```
On-Prem (10.200.0.0/21)
  │
  │ :443
  ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ SG-ALB                                                                   │
│ ┌──────────────────┐                                                     │
│ │ Internal ALB     │ Inbound:  10.200.0.0/21:443 (On-Prem)              │
│ │ *.internal       │ Outbound: SG-Mgmt-Node                             │
│ └────────┬─────────┘                                                     │
│          │ :80,443                                                        │
│          ▼                                                                │
│ SG-Mgmt-Node                                                             │
│ ┌──────────────────────────────────────────────────────────────────────┐ │
│ │ Management Subnet (10.100.1.0/24)                                    │ │
│ │                                                                      │ │
│ │ Inbound:  SG-ALB:80,443                                             │ │
│ │           SG-GPU-Node (Ray Worker → Head)                            │ │
│ │ Outbound: SG-VPC-Endpoint:443                                        │ │
│ │           SG-Storage:5432,6379                                       │ │
│ │                                                                      │ │
│ │ Keycloak, JupyterHub, MLflow, ClickHouse, Grafana,                  │ │
│ │ Prometheus, Ray Head, OSMO, Karpenter, CoreDNS                      │ │
│ └──────────────────────────────┬───────────────────────────────────────┘ │
│                                │ :8265,6379 (Ray)                        │
│                                ▼                                         │
│ SG-GPU-Node                                                              │
│ ┌──────────────────────────────────────────────────────────────────────┐ │
│ │ GPU Subnet (10.100.0.0/24)                                           │ │
│ │                                                                      │ │
│ │ Inbound:  SG-GPU-Node (all)        ← NCCL/EFA 노드간               │ │
│ │           SG-Mgmt-Node:8265,6379   ← Ray Head                       │ │
│ │           SG-Storage:988           ← FSx Lustre                     │ │
│ │ Outbound: SG-VPC-Endpoint:443                                        │ │
│ │           SG-Storage:988                                             │ │
│ │                                                                      │ │
│ │ g6e.48xlarge x10, Training Pods, DCGM Exporter, Fluent Bit          │ │
│ └──────────────────────────────┬───────────────────────────────────────┘ │
│                                │ :988 (Lustre), :5432 (PG), :6379 (Redis)│
│                                ▼                                         │
│ SG-Storage                                                               │
│ ┌──────────────────────────────────────────────────────────────────────┐ │
│ │ Infrastructure Subnet (10.100.2.0/24)                                │ │
│ │                                                                      │ │
│ │ Inbound:  SG-GPU-Node:988         ← FSx                             │ │
│ │           SG-Mgmt-Node:5432       ← RDS                             │ │
│ │           SG-Mgmt-Node:6379       ← Redis                           │ │
│ │                                                                      │ │
│ │ FSx for Lustre, RDS PostgreSQL, VPC Endpoints                       │ │
│ └──────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│ SG-VPC-Endpoint                                                          │
│ Inbound: 10.100.0.0/21:443 (VPC 전체)                                   │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 7. Setup Phases

```
Phase 1                Phase 2              Phase 2.5
Network                EKS + Storage        OSMO + Ray
┌─────────────┐       ┌──────────────┐     ┌──────────────┐
│ VPC         │       │ EKS Cluster  │     │ OSMO         │
│ Subnets     │──────→│ Mgmt Nodes   │────→│ Controller   │
│ DX + VPN    │       │ RDS, S3, FSx │     │ KubeRay      │
│ VPC Endpts  │       │ CSI Drivers  │     │ Operator     │
│ SGs         │       │ Karpenter    │     │ (CPU test)   │
│ Route53     │       │ ECR, IRSA    │     │              │
│ TLS Certs   │       │ Secrets Mgr  │     │              │
└─────────────┘       └──────────────┘     └──────┬───────┘
                                                   │
              ┌────────────────────────────────────┘
              ▼
Phase 3                Phase 4              Phase 5
Auth                   Core Services        Monitoring
┌─────────────┐       ┌──────────────┐     ┌──────────────┐
│ Keycloak    │       │ MLflow       │     │ Prometheus   │
│ AD LDAP     │──────→│ ClickHouse   │────→│ Grafana      │
│ OIDC Clients│       │ 테이블 생성  │     │ Fluent Bit   │
│ Roles       │       │ RDS 백업     │     │ DCGM Exporter│
│             │       │ S3 Lifecycle │     │ Kubecost     │
│             │       │              │     │ Dashboards   │
└─────────────┘       └──────────────┘     └──────┬───────┘
                                                   │
              ┌────────────────────────────────────┘
              ▼
Phase 6                Phase 7              Phase 8
JupyterHub             GPU Pipeline         On-Prem
┌─────────────┐       ┌──────────────┐     ┌──────────────┐
│ Helm 설치   │       │ GPU 노드 ON  │     │ RTX Pro 6000 │
│ OIDC 연동   │──────→│ Docker Image │────→│ 환경 설정    │
│ 노트북 이미지│       │ 1GPU → 8GPU │     │ DX 연결 확인 │
│ OSMO 연동   │       │ → Multi-Node │     │ eval 파이프라인│
│ 샘플 노트북 │       │ → HPO        │     │ 작업 관리    │
│             │       │ DCGM 확인    │     │              │
└─────────────┘       └──────────────┘     └──────────────┘
```
