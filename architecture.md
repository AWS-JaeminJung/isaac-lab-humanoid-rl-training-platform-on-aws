# Isaac Lab Production Architecture

## Overview

Isaac Lab RL 학습 파이프라인의 프로덕션 환경 아키텍처 문서.
모든 리소스는 Private Subnet에 배치되며, On-Prem과 Direct Connect로 연결된다.

---

## 1. Network Architecture

### 핵심 원칙

- 모든 인스턴스는 Private Subnet에만 위치
- NAT Gateway 없음 - 외부 트래픽은 Direct Connect -> On-Prem -> 인터넷
- Internal ALB로 내부 서비스 접근
- Direct Connect 전용선으로 On-Prem <-> AWS 연결
- VPC Endpoints로 AWS 서비스 접근 (PrivateLink)

### 트래픽 흐름

| 경로 | 흐름 |
|------|------|
| 개발자 -> MLflow/Grafana | On-Prem -> DX -> VGW -> Internal ALB -> Service |
| EKS -> ECR (이미지 pull) | VPC Endpoint (PrivateLink) |
| EKS -> S3 (체크포인트) | VPC Endpoint (Gateway) |
| Pod -> 외부 pip install | Pod -> VPC -> DX -> On-Prem Proxy -> Internet |
| On-Prem GPU -> ClickHouse | On-Prem -> DX -> VPC -> ClickHouse Pod |

### DX 비용 분석

- On-Prem -> AWS (Inbound): 무료
- AWS -> On-Prem (Outbound): ~$0.02/GB
- 월간 예상 Outbound: 체크포인트 다운로드 ~20GB = ~$0.40/월
- 결론: 모든 서비스를 AWS에 배치해도 DX 비용 무시 가능 (월 $5 미만)

---

## 2. VPC & Subnet Design

### Single AZ 선택 근거

| 요소 | 이유 |
|------|------|
| GPU 노드간 통신 | EFA (Elastic Fabric Adapter)는 같은 AZ 내에서만 동작 |
| FSx for Lustre | 단일 AZ 리소스, 같은 AZ 노드만 최적 throughput |
| NCCL AllReduce | 크로스 AZ 레이턴시 ~0.5-1ms 추가 -> 분산학습 성능 저하 |
| 데이터 전송비용 | 크로스 AZ 트래픽 $0.01/GB 양방향 |

### CIDR 설계

```
VPC Primary:  10.100.0.0/21  (2,048 IPs)
On-Prem:      10.200.0.0/21  (예시, VPC와 충돌 방지)
```

### 서브넷

| # | 서브넷 | CIDR | IPs | 용도 |
|---|--------|------|-----|------|
| 1 | GPU Compute | 10.100.0.0/24 | 254 | g6e.48xlarge 노드 + Pod (10대 + EFA) |
| 2 | Management | 10.100.1.0/24 | 254 | CPU 관리 노드 + Pod (MLflow, JupyterHub 등) |
| 3 | Infrastructure | 10.100.2.0/24 | 254 | VPC Endpoints, FSx, RDS, ALB |
| 4 | Reserved | 10.100.3.0/24 | 254 | 확장용 |
| 5-8 | 미할당 | 10.100.4.0/22 | 1,022 | 스케일업 시 서브넷 추가 |

총 할당: 1,016 / 2,048 (50%), 확장 여유 충분.

### 라우팅

```
Private Route Table:
  10.100.0.0/21   -> local              (VPC 내부)
  10.200.0.0/21   -> vgw-xxx            (On-Prem via DX)
  0.0.0.0/0       -> vgw-xxx            (DX -> On-Prem -> Internet)
  S3 prefix list  -> vpce-s3            (S3 Gateway Endpoint)
```

### VPC Endpoints

#### EKS 운영 필수

| Endpoint | Type | 용도 |
|----------|------|------|
| com.amazonaws.{region}.eks | Interface | EKS API server |
| com.amazonaws.{region}.eks-auth | Interface | EKS Pod Identity |
| com.amazonaws.{region}.ecr.api | Interface | ECR API |
| com.amazonaws.{region}.ecr.dkr | Interface | ECR Docker registry |
| com.amazonaws.{region}.s3 | Gateway | ECR 레이어 + 체크포인트 + 로그 아카이브 |
| com.amazonaws.{region}.sts | Interface | IAM 역할 assume (IRSA) |
| com.amazonaws.{region}.ec2 | Interface | ENI 관리 |
| com.amazonaws.{region}.elasticloadbalancing | Interface | ALB 컨트롤러 |

#### 로깅/모니터링

| Endpoint | Type | 용도 |
|----------|------|------|
| com.amazonaws.{region}.logs | Interface | CloudWatch Logs |
| com.amazonaws.{region}.monitoring | Interface | CloudWatch Metrics |

#### 학습 파이프라인

| Endpoint | Type | 용도 |
|----------|------|------|
| com.amazonaws.{region}.autoscaling | Interface | EKS 노드 오토스케일링 |
| com.amazonaws.{region}.sqs | Interface | Karpenter 인터럽션 큐 (Spot) |
| com.amazonaws.{region}.ssm | Interface | SSM Parameter Store |
| com.amazonaws.{region}.ssmmessages | Interface | SSM Session Manager |
| com.amazonaws.{region}.ec2messages | Interface | SSM 에이전트 |
| com.amazonaws.{region}.fsx | Interface | FSx for Lustre |

#### 보안

| Endpoint | Type | 용도 |
|----------|------|------|
| com.amazonaws.{region}.kms | Interface | 암호화 키 관리 |
| com.amazonaws.{region}.secretsmanager | Interface | 시크릿 관리 |

---

## 3. Compute

### GPU Cluster (AWS)

| 항목 | 값 |
|------|-----|
| Instance | g6e.48xlarge |
| GPU | 8x L40S per node |
| 대수 | 10대 (Karpenter 오토스케일 0-10) |
| 총 GPU | 80 GPUs |
| EFA | 활성화 (노드간 NCCL 통신) |
| 서브넷 | GPU Compute (10.100.0.0/24) |

### On-Prem GPU

| 항목 | 값 |
|------|-----|
| GPU | NVIDIA RTX Pro 6000 |
| 대수 | 15대 |
| 용도 | 단일 GPU 작업 전용 |
| 연결 | Direct Connect 경유 AWS 서비스 접근 |

#### On-Prem GPU 워크로드 (GPU 1개 작업만)

| 작업 | 설명 |
|------|------|
| 모델 평가 (eval) | 체크포인트 S3에서 다운로드 -> 시뮬 실행 -> 결과 ClickHouse 전송 |
| 코드 테스트 | 수정 후 50-100 iter 빠른 검증 |
| 디버깅 | num_envs=1로 step-by-step |
| 시각화/녹화 | 학습된 정책 렌더링 영상 생성 |
| 소규모 HPO 사전탐색 | trial당 GPU 1개, 짧은 iteration |

---

## 4. Storage

### FSx for Lustre

| 항목 | 값 |
|------|-----|
| Deployment Type | PERSISTENT_2 |
| 서브넷 | Infrastructure (10.100.2.0/24), GPU와 같은 AZ |
| 용도 | 체크포인트 (고속 I/O), 학습 데이터셋, 멀티노드 공유 |
| S3 연동 | Data Repository Association |

```
/mnt/fsx/
  ├── checkpoints/    학습 체크포인트 (고속 I/O)
  ├── datasets/       학습 데이터셋
  └── shared/         멀티노드 공유 스토리지
```

### S3

| 버킷 | 용도 |
|------|------|
| production-checkpoints | 체크포인트 백업 (FSx -> S3 주기적 동기화) |
| production-models | MLflow 모델 아티팩트 |
| production-logs-archive | ClickHouse 로그 아카이브 (180일+) |
| production-training-data | 학습 데이터 원본 |

### RDS PostgreSQL

| 항목 | 값 |
|------|-----|
| 용도 | Keycloak DB + MLflow Backend DB (별도 database) |
| Multi-AZ | Standby 권장 (primary는 같은 AZ) |
| 서브넷 | Infrastructure (10.100.2.0/24) |

---

## 5. Authentication & Access Control

### 구조: AD -> Keycloak -> OIDC

```
On-Prem AD (LDAP)
  |
  | LDAP Federation (15분 주기 동기화)
  v
Keycloak (Management Subnet, 2 replicas)
  |
  | OIDC / OAuth2
  +---> JupyterHub
  +---> Grafana
  +---> MLflow
  +---> Ray Dashboard
  +---> OSMO API
  +---> ArgoCD
```

### Keycloak 설정

```
Realm: isaac-lab-production
  Identity Provider: On-Prem AD (ldaps://ad.corp.internal:636)
  Sync: 15분 주기

  Clients (OIDC):
    - jupyterhub       (Authorization Code Flow)
    - grafana           (Authorization Code Flow)
    - mlflow            (Authorization Code Flow)
    - osmo-api          (Bearer-only, API 토큰 검증)
    - ray-dashboard     (Authorization Code Flow)
```

### 역할 (Role)

| 역할 | AD 그룹 매핑 | 설명 |
|------|-------------|------|
| researcher | CN=ML-Researchers | 학습 제출, 결과 조회, 노트북 사용 |
| engineer | CN=MLOps-Engineers | + 인프라 설정, ArgoCD |
| viewer | CN=ML-Managers | Grafana/MLflow 읽기 전용 |

### 서비스별 권한 매트릭스

| 서비스 | researcher | engineer | viewer |
|--------|:---:|:---:|:---:|
| JupyterHub 로그인 | O | O | X |
| OSMO 학습 제출 | O | O | X |
| OSMO GPU 쿼터 | 4 GPU | 10 GPU | - |
| Grafana 대시보드 보기 | O | O | O |
| Grafana 대시보드 편집 | X | O | X |
| MLflow 실험 조회 | O | O | O |
| MLflow 모델 등록/삭제 | O | O | X |
| Ray Dashboard | O | O | X |
| ClickHouse 쿼리 (Grafana 경유) | O | O | O |
| ArgoCD | X | O | X |

---

## 6. EKS Cluster

### 클러스터 설정

- Private Endpoint Only
- VPC CNI (WARM_IP_TARGET=2, MINIMUM_IP_TARGET=10)
- Single AZ (us-east-1a)

### 노드 그룹

#### GPU Node Group (Karpenter)

| 항목 | 값 |
|------|-----|
| Subnet | GPU Compute (10.100.0.0/24) |
| Instances | g6e.48xlarge |
| EFA | enabled |
| Labels | node-type=gpu |
| Taints | nvidia.com/gpu=:NoSchedule |
| Volume Mounts | FSx (/mnt/fsx) |
| Scaling | 0-10 (Karpenter) |

#### Management Node Group

| 항목 | 값 |
|------|-----|
| Subnet | Management (10.100.1.0/24) |
| Instances | m6i.2xlarge ~ m6i.4xlarge |
| Labels | node-type=management |
| 대수 | 3-5대 |

---

## 7. Logging Architecture

### 설계 원칙

stdout 파싱(regex)에 의존하지 않고, 학습 콜백에서 구조화 메트릭을 직접 ClickHouse에 전송한다.

### 데이터 흐름

```
학습 Pod (GPU Node)
  |
  |  rsl_rl 학습 루프
  |  +-- 콜백 --> HTTP POST --> ClickHouse (training_metrics)
  |  |   구조화 메트릭, 10 iter 배치 전송
  |  |   파싱 없음, 타입 보장, 내부 메트릭 포함
  |  |
  |  +-- stdout --> Fluent Bit --> ClickHouse (training_raw_logs)
  |      파싱 없이 텍스트 그대로 저장
  |      디버깅/에러 추적 용도
  v
ClickHouse
  +-- training_metrics     (콜백 직접 INSERT)
  +-- training_raw_logs    (Fluent Bit, raw 텍스트)
  +-- training_summary     (영구 보관, 학습 건당 1행)
```

### ClickHouse 테이블

#### training_metrics (구조화 메트릭)

```sql
CREATE TABLE training_metrics (
    timestamp            DateTime64(3),
    workflow_id          String,
    trial_id             String,
    sweep_id             String,
    task                 String,
    iteration            UInt32,
    -- 성능
    mean_reward          Float64,
    episode_length       Float64,
    -- 종료 조건
    base_contact         Float64,
    time_out_pct         Float64,
    -- 학습 내부 (stdout에 없는 메트릭)
    value_loss           Float64,
    policy_loss          Float64,
    entropy              Float64,
    kl_divergence        Float64,
    learning_rate_actual Float64,
    grad_norm            Float64,
    -- 보상 세부 항목
    reward_tracking      Float64,
    reward_lin_vel       Float64,
    reward_ang_vel       Float64,
    reward_joint_acc     Float64,
    reward_feet_air      Float64,
    -- 타이밍
    iteration_time       Float64,
    collection_time      Float64,
    learning_time        Float64
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (workflow_id, trial_id, iteration)
TTL timestamp + INTERVAL 180 DAY DELETE;
```

#### training_raw_logs (원본 텍스트)

```sql
CREATE TABLE training_raw_logs (
    timestamp     DateTime64(3),
    workflow_id   String,
    pod_name      String,
    node          String,
    raw_log       String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (workflow_id, timestamp)
TTL timestamp + INTERVAL 90 DAY DELETE;
```

#### training_summary (영구 보관)

```sql
CREATE TABLE training_summary (
    workflow_id        String,
    sweep_id           String,
    trial_id           String,
    task               String,
    started_at         DateTime,
    finished_at        DateTime,
    total_iterations   UInt32,
    best_reward        Float64,
    best_iteration     UInt32,
    final_reward       Float64,
    hp_learning_rate   Float64,
    hp_gamma           Float64,
    exit_code          Int16
)
ENGINE = MergeTree()
ORDER BY (started_at, workflow_id);
-- TTL 없음: 영구 보관
```

### ClickHouse Logger 콜백

학습 스크립트에서 rsl_rl 내부 로그 딕셔너리를 직접 가져와 HTTP INSERT로 전송.
10 iteration마다 배치 전송하여 네트워크 부하 최소화.
전송 실패 시 학습을 중단하지 않음 (try/except pass).

### 로그 Lifecycle

| 계층 | 기간 | 내용 | 저장소 |
|------|------|------|--------|
| Hot | 0-90일 | 전체 (raw_log + 메트릭) | ClickHouse EBS gp3 |
| Warm | 90-180일 | 메트릭만 (raw_log 삭제) | ClickHouse EBS gp3 |
| Summary | 영구 | 학습 건당 1행 요약 | ClickHouse EBS gp3 |
| Archive | 180일+ | raw 전체 (필요시) | S3 Glacier |
| 삭제 | 365일+ | 상세 로그 자동 삭제 | - |

---

## 8. Monitoring & Observability

### 도구 역할 분담

| 도구 | 역할 | 데이터 |
|------|------|--------|
| ClickHouse | 학습 로그 저장 + 분석 + 비교 | iteration 메트릭, raw 로그 |
| MLflow | 모델 레지스트리 + 실험 메타데이터 | 최종 메트릭, HP, 체크포인트 |
| Grafana | 통합 대시보드 | ClickHouse + Prometheus 데이터소스 |
| Prometheus | 인프라 메트릭 | GPU util, 노드 상태, Pod 리소스 |
| DCGM Exporter | GPU 상세 모니터링 | GPU 온도, 메모리, utilization |
| Fluent Bit | raw 로그 수집 | DaemonSet, 파싱 없이 텍스트 전송 |

### Grafana 대시보드

- Training Dashboard: reward 추이, loss curves, grad norm, GPU util
- HPO Dashboard: trial 비교, HP correlation, ASHA 스케줄러 상태
- Infrastructure Dashboard: 노드 상태, Pod 리소스, 네트워크
- Cost Dashboard: GPU 사용 시간, 노드 가동률

---

## 9. JupyterHub

### 역할

연구자의 통합 인터페이스. 학습을 직접 실행하지 않고, OSMO API를 통해 제출하는 "조종석".

| 기능 | 방식 |
|------|------|
| 코드 프로토타이핑 | 노트북에서 수정/테스트 |
| 학습 제출 | osmo-client로 OSMO API 호출 |
| 실시간 모니터링 | ClickHouse 쿼리 + inline 차트 |
| 결과 분석 | pandas + plotly 시각화 |
| HPO 결과 탐색 | SQL로 trial 필터/정렬/시각화 |
| 학습 간 비교 | SQL JOIN + 차트 |

### 리소스

| 컴포넌트 | CPU | Memory | 비고 |
|----------|-----|--------|------|
| Hub | 0.5 | 1Gi | 세션 관리 |
| Proxy | 0.2 | 256Mi | 트래픽 라우팅 |
| 유저 노트북 (x10) | 2 each | 4Gi each | CPU only, GPU 미할당 |

### 정책

- 30분 비활성 시 노트북 자동 종료 (리소스 절약)
- 8시간 후 강제 종료
- GPU는 할당하지 않음 (분석/제출 전용)
- Keycloak OIDC 인증

---

## 10. Management Subnet 워크로드

| 워크로드 | Replicas | CPU | Memory | 비고 |
|----------|----------|-----|--------|------|
| Keycloak | 2 | 1 each | 1.5Gi each | HA, RDS backend |
| JupyterHub | 1 | 0.5 | 1Gi | |
| JupyterHub Proxy | 1 | 0.2 | 256Mi | |
| User Notebooks | ~10 | 2 each | 4Gi each | 동시 접속 기준 |
| MLflow | 1 | 2 | 4Gi | RDS backend, S3 artifact |
| ClickHouse | 1 | 2 | 4Gi | EBS gp3 50Gi |
| Grafana | 1 | 0.5 | 1Gi | |
| Prometheus | 1 | 1 | 4Gi | EBS gp3 for TSDB |
| Ray Head | 1 | 4 | 16Gi | Dashboard + GCS |
| Karpenter | 1 | 1 | 1Gi | GPU 오토스케일 |
| ALB Ingress Controller | 1 | 0.5 | 512Mi | |
| Fluent Bit | DaemonSet | 0.2/node | 256Mi/node | 모든 노드 |
| CoreDNS | 2 | 0.5 each | 256Mi each | |
| OSMO Controller | 1 | 1 | 2Gi | |
| DCGM Exporter | DaemonSet (GPU) | 0.1/node | 128Mi/node | GPU 노드만 |

---

## 11. Security Groups

```
SG-GPU-Node
  Inbound:  SG-GPU-Node (all)         노드간 NCCL/EFA
  Inbound:  SG-Mgmt-Node:8265,6379    Ray Head -> Worker
  Inbound:  SG-Storage:988            FSx Lustre
  Outbound: SG-VPC-Endpoint:443, SG-Storage:988

SG-Mgmt-Node
  Inbound:  SG-ALB:80,443             ALB -> 서비스
  Inbound:  SG-GPU-Node               Ray Worker -> Head
  Outbound: SG-VPC-Endpoint:443, SG-Storage:5432,6379

SG-ALB (Internal)
  Inbound:  On-Prem CIDR (10.200.0.0/21):443
  Outbound: SG-Mgmt-Node

SG-VPC-Endpoint
  Inbound:  10.100.0.0/21:443         VPC 내부에서만

SG-Storage
  Inbound:  SG-GPU-Node:988           FSx
  Inbound:  SG-Mgmt-Node:5432         RDS
  Inbound:  SG-Mgmt-Node:6379         Redis (선택)
```

---

## 12. Internal ALB Routes

| Hostname | Target | Port |
|----------|--------|------|
| jupyter.internal | JupyterHub | 8000 |
| grafana.internal | Grafana | 3000 |
| mlflow.internal | MLflow | 5000 |
| keycloak.internal | Keycloak | 8080 |
| ray.internal | Ray Dashboard | 8265 |
| osmo.internal | OSMO API | 8080 |

DNS: Route53 Private Hosted Zone -> Internal ALB.
접근: On-Prem에서 Direct Connect를 통해서만 가능.

---

## 13. Workflow Submission Model

### 권장 조합

| 사용자 | 주 도구 | 용도 |
|--------|---------|------|
| ML 연구자 | JupyterHub | 실험, 제출, 분석 |
| MLOps 엔지니어 | GitOps + CLI | 프로덕션 배포, 인프라 |
| 팀 리드 | Grafana | 모니터링 |

### JupyterHub에서의 워크플로우

```
1. 코드 프로토타이핑 (노트북)
2. OSMO API로 학습 제출 (client.submit_workflow)
3. ClickHouse 쿼리로 실시간 추이 확인
4. 학습 완료 후 결과 분석/시각화
5. On-Prem GPU에 eval 작업 제출
```

---

## 14. Resilience & Backup

### 체크포인트 이중화

- 학습 중: FSx for Lustre (고속 I/O)
- 매 N iteration: S3에 비동기 백업
- AZ 장애 시: S3에서 복구 가능

### ClickHouse 백업

- EBS 스냅샷: 일 1회
- S3 아카이브: 180일 이상 데이터 자동 이관

### Direct Connect 이중화

- 권장: DX 1회선 + Site-to-Site VPN (백업)
- VPN은 인터넷 경유, 비상 시 최소 접근 보장
- 진행 중 학습은 AWS 내부 완결이므로 DX 장애와 무관

---

## 15. Open Decisions

| 항목 | 선택지 | 상태 |
|------|--------|------|
| 관리 서비스 Multi-AZ | A. 전부 Single AZ / B. 관리만 Multi-AZ | 미결정 |
| GPU 오토스케일 범위 | A. 상시 N대 / B. 0->10 Karpenter | 미결정 |
| On-Prem 작업 관리 방식 | A. 직접 실행 / B. Ray 클러스터 / C. k3s | 미결정 |
| IaC 도구 | A. Terraform / B. CDK / C. Pulumi | 미결정 |
| Spot 인스턴스 허용 여부 | A. On-Demand only / B. Spot 허용 | 미결정 |
