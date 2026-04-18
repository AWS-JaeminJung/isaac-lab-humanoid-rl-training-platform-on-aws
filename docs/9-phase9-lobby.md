# Phase 9: Lobby

연구자 인터페이스 — [JupyterHub](https://jupyterhub.readthedocs.io/), 노트북 이미지, 샘플 노트북

## Goal

연구자가 학습 제출, 실시간 모니터링, 결과 분석을 한 곳에서 수행할 수 있는 통합 인터페이스를 구축한다.

## Prerequisites

- Phase 4 완료 ([Keycloak OIDC](https://www.keycloak.org/docs/latest/securing_apps/) 클라이언트: jupyterhub)
- Phase 5 완료 (OSMO API 운영 중)
- Phase 6 완료 (MLflow 운영 중)
- Phase 7 완료 (ClickHouse 운영 중)

## Design Decisions

| 결정 | 선택 | 이유 |
|------|------|------|
| 연구자 인터페이스 | JupyterHub (CLI, 커스텀 UI 대신) | 연구자가 학습 제출/모니터링/분석/시각화를 한 곳에서 수행한다. 노트북 자체가 분석 기록이 된다 |
| 노트북 GPU | CPU 전용 (GPU 없음) | 노트북은 제출/분석 용도이다. GPU는 학습 Pod에 할당하여 유휴 GPU 낭비를 방지한다 |
| 세션 관리 | 30분 비활성 cull + 8시간 최대 | Management 노드 리소스를 보존한다. 동시 10명까지 지원하려면 자동 회수가 필수이다 |
| 사전 설치 패키지 | osmo-client, clickhouse-connect, mlflow, plotly | 연구자가 별도 설치 없이 바로 작업할 수 있다. 일관된 환경을 보장한다 |

---

## Service Flow

### 연구자 작업 흐름

```
연구자 (On-Prem 브라우저)
  │
  │ https://jupyter.internal
  ▼
┌─ Internal ALB ───────────────────────────────────────────────────┐
│  TLS termination (*.internal 인증서)                             │
└──────────────────────────┬───────────────────────────────────────┘
                           │
                           ▼
┌─ JupyterHub (Management Subnet) ─────────────────────────────────┐
│                                                                  │
│  ┌─────────┐  ┌──────────┐  ┌──────────────────────────────┐     │
│  │  Hub    │  │  Proxy   │  │  User Notebooks (x10)        │     │
│  │ 0.5C/1Gi│  │ 0.2C/256M│  │  2C/4Gi each, CPU only       │     │
│  │         │  │          │  │  30min idle cull             │     │
│  │ Keycloak│  │ Traffic  │  │  8hr max lifetime            │     │
│  │ OIDC    │  │ Routing  │  │                              │     │
│  └─────────┘  └──────────┘  │  Pre-installed:              │     │
│                              │  ├── osmo-client            │     │
│                              │  ├── clickhouse-connect     │     │
│                              │  ├── mlflow                 │     │
│                              │  ├── plotly, pandas         │     │
│                              │  └── boto3                  │     │
│                              └──────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
```

### 노트북에서의 서비스 연동

```
┌─ User Notebook (CPU only, 2C/4Gi) ────────────────────────────────┐
│                                                                   │
│  1. 학습 제출                                                     │
│     osmo-client ──── HTTPS ────▶ OSMO API (osmo.internal)         │
│     (Bearer JWT)                  → RayJob 생성                   │
│                                   → Karpenter → GPU 프로비저닝    │
│                                                                   │
│  2. 실시간 모니터링                                               │
│     clickhouse-connect ──────▶ ClickHouse (:8123)                 │
│     SQL query                   training_metrics                  │
│     → pandas DataFrame                                            │
│     → plotly 차트 (inline)                                        │
│                                                                   │
│  3. 실험 관리                                                     │
│     mlflow ──── HTTPS ────────▶ MLflow (mlflow.internal)          │
│     search_runs()                실험 목록, 파라미터 비교         │
│     register_model()             모델 등록/스테이지 변경          │
│                                                                   │
│  4. 결과 분석                                                     │
│     clickhouse-connect ──────▶ ClickHouse                         │
│     SQL JOIN (여러 학습 비교)                                     │
│     → pandas + plotly                                             │
│     → 노트북 자체가 분석 기록                                     │
│                                                                   │
│  5. 체크포인트 조회                                               │
│     boto3 ────────────────────▶ S3 (VPC Endpoint)                 │
│     체크포인트 목록/다운로드                                      │
└───────────────────────────────────────────────────────────────────┘
```

### JupyterHub 리소스 구조

```
Management Node (m6i.2xlarge)
  │
  ├── JupyterHub Pod
  │     Hub:    0.5 CPU, 1Gi    (세션 관리, OAuth)
  │     Proxy:  0.2 CPU, 256Mi  (트래픽 라우팅)
  │
  ├── User Notebook Pod (동적 생성)
  │     Per User: 2 CPU, 4Gi
  │     Max Concurrent: ~10명
  │     Storage: 10Gi PVC (EBS gp3)
  │     GPU: 없음 (제출/분석 전용)
  │
  │     Lifecycle:
  │       Login → Notebook Start → [작업] → 30min 비활성 → Auto Cull
  │       또는 8시간 경과 → 강제 종료
  │
  └── (다른 서비스 Pods ...)
```

---

## Steps

### 9-1. JupyterHub 배포

[Zero to JupyterHub](https://z2jh.jupyter.org/en/stable/) Helm 차트를 사용하여 배포한다.

```
helm repo add jupyterhub https://hub.jupyter.org/helm-chart/
helm install jupyterhub jupyterhub/jupyterhub \
  --namespace jupyterhub --create-namespace \
  -f jupyterhub-values.yaml
```

### 9-2. JupyterHub 설정

```yaml
# jupyterhub-values.yaml

hub:
  nodeSelector:
    node-type: management
  resources:
    requests:
      cpu: 500m
      memory: 1Gi

proxy:
  nodeSelector:
    node-type: management
  resources:
    requests:
      cpu: 200m
      memory: 256Mi

singleuser:
  nodeSelector:
    node-type: management
  cpu:
    limit: 2
    guarantee: 1
  memory:
    limit: 4G
    guarantee: 2G
  image:
    name: {ecr}/jupyterhub-notebook
    tag: v1.0.0
  defaultUrl: "/lab"
  storage:
    type: dynamic
    capacity: 10Gi
    storageClass: gp3

cull:
  enabled: true
  timeout: 1800       # 30분 비활성 시 종료
  maxAge: 28800       # 8시간 후 강제 종료

scheduling:
  userScheduler:
    enabled: false
```

### 9-3. Keycloak OIDC 연동

[JupyterHub OAuthenticator](https://oauthenticator.readthedocs.io/en/latest/)를 사용하여 [Keycloak OIDC](https://www.keycloak.org/docs/latest/securing_apps/)와 연동한다.

```yaml
hub:
  config:
    JupyterHub:
      authenticator_class: generic-oauth
    GenericOAuthenticator:
      client_id: jupyterhub
      client_secret: ${JUPYTERHUB_OAUTH_CLIENT_SECRET}
      oauth_callback_url: https://jupyter.internal/hub/oauth_callback
      authorize_url: https://keycloak.internal/realms/isaac-lab-production/protocol/openid-connect/auth
      token_url: https://keycloak.internal/realms/isaac-lab-production/protocol/openid-connect/token
      userdata_url: https://keycloak.internal/realms/isaac-lab-production/protocol/openid-connect/userinfo
      scope:
        - openid
        - profile
        - email
      username_claim: preferred_username
```

### 9-4. 노트북 이미지 빌드

노트북 이미지에는 [clickhouse-connect](https://clickhouse.com/docs/en/integrations/python), [MLflow Python API](https://mlflow.org/docs/latest/python_api/index.html), [plotly](https://plotly.com/python/) 등을 사전 설치한다.

```dockerfile
FROM jupyter/scipy-notebook:latest

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq && \
    rm -rf /var/lib/apt/lists/*

USER ${NB_UID}

RUN pip install --no-cache-dir \
    osmo-client \
    clickhouse-connect \
    mlflow \
    boto3 \
    plotly \
    ipywidgets \
    pandas \
    matplotlib
```

```
docker build -t {ecr}/jupyterhub-notebook:v1.0.0 .
docker push {ecr}/jupyterhub-notebook:v1.0.0
```

### 9-5. 샘플 노트북

#### 01-submit-training.ipynb

```python
from osmo_client import OsmoClient

client = OsmoClient(
    endpoint="https://osmo.internal",
    token=os.environ["OSMO_TOKEN"]
)

workflow = client.submit_workflow(
    name="h1-locomotion-exp-001",
    image="{ecr}/isaac-lab-training:v1.0.0",
    task="H1-v0",
    num_envs=4096,
    max_iterations=5000,
    gpu=8,
    num_nodes=2
)
print(f"Workflow ID: {workflow.id}")
```

#### 02-monitor-training.ipynb

```python
import clickhouse_connect
import plotly.express as px

client = clickhouse_connect.get_client(
    host="clickhouse.logging.svc.cluster.local", port=8123
)

df = client.query_df("""
    SELECT iteration, mean_reward, value_loss, grad_norm
    FROM training_metrics
    WHERE workflow_id = '{workflow_id}'
    ORDER BY iteration
""")

fig = px.line(df, x="iteration", y="mean_reward",
              title="Training Reward Curve")
fig.show()
```

#### 03-compare-experiments.ipynb

```python
df = client.query_df("""
    SELECT trial_id,
           max(mean_reward) AS best_reward,
           argMax(iteration, mean_reward) AS best_iter,
           any(hp_learning_rate) AS lr,
           any(hp_gamma) AS gamma
    FROM training_metrics
    WHERE sweep_id = '{sweep_id}'
    GROUP BY trial_id
    ORDER BY best_reward DESC
""")

fig = px.scatter(df, x="lr", y="best_reward", size="best_iter",
                 hover_data=["trial_id", "gamma"],
                 title="Learning Rate vs Best Reward")
fig.show()
```

#### 04-model-registry.ipynb

```python
import mlflow

mlflow.set_tracking_uri("https://mlflow.internal")

runs = mlflow.search_runs(
    experiment_ids=["1"],
    order_by=["metrics.best_reward DESC"]
)
print(runs[["run_id", "params.learning_rate", "metrics.best_reward"]].head())

mlflow.register_model(
    f"runs:/{best_run_id}/checkpoint",
    "h1-locomotion"
)
```

### 9-6. Ingress 설정

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jupyterhub
  namespace: jupyterhub
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internal
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: {acm-cert-arn}
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
spec:
  rules:
    - host: jupyter.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: proxy-public
                port:
                  number: 80
```

### 9-7. Route53 레코드

```
jupyter.internal → Internal ALB (Alias)
```

---

## References

- [JupyterHub Documentation](https://jupyterhub.readthedocs.io/)
- [Zero to JupyterHub with Kubernetes (Helm)](https://z2jh.jupyter.org/en/stable/)
- [JupyterHub OAuthenticator](https://oauthenticator.readthedocs.io/en/latest/)
- [Keycloak OIDC Securing Applications](https://www.keycloak.org/docs/latest/securing_apps/)
- [plotly Python Graphing Library](https://plotly.com/python/)
- [clickhouse-connect Python Client](https://clickhouse.com/docs/en/integrations/python)
- [MLflow Python API](https://mlflow.org/docs/latest/python_api/index.html)

## Validation Checklist

- [ ] JupyterHub Hub/Proxy 정상 Running
- [ ] https://jupyter.internal 접근 → Keycloak 로그인 리다이렉트
- [ ] 인증 후 JupyterLab 환경 시작
- [ ] 노트북에서 osmo-client import 성공
- [ ] 노트북에서 ClickHouse 쿼리 성공
- [ ] 노트북에서 MLflow API 호출 성공
- [ ] 30분 비활성 후 노트북 자동 종료 확인
- [ ] 동시 사용자 10명 테스트
- [ ] 샘플 노트북 4개 정상 실행

## Next

→ [Phase 10: Factory Floor](10-phase10-factory-floor.md)
