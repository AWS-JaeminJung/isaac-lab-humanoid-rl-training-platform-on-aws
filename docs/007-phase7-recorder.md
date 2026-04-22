# Phase 7: Recorder

학습 로그 — [ClickHouse](https://clickhouse.com/docs), [Fluent Bit](https://docs.fluentbit.io/manual/), 테이블 DDL, Lifecycle

## Goal

학습 iteration 메트릭과 raw 로그를 [ClickHouse](https://clickhouse.com/docs)에 저장하고, [Fluent Bit](https://docs.fluentbit.io/manual/)으로 Pod 로그를 수집한다.

## Prerequisites

- Phase 2 완료 (EKS, EBS CSI Driver)
- EBS gp3 StorageClass 사용 가능

## Design Decisions

| 결정 | 선택 | 이유 |
|------|------|------|
| 로그 저장소 | ClickHouse (Loki, Elasticsearch 대신) | 학습 메트릭은 반정형 시계열 데이터이다. SQL로 학습 간 비교/분석이 핵심이며, ClickHouse는 이에 최적화되어 있다 |
| 메트릭 수집 | 콜백 직접 INSERT (stdout 파싱 대신) | regex 파싱은 rsl_rl 버전 변경 시 silent failure가 발생한다. 콜백은 타입 보장과 내부 메트릭(grad_norm, kl_divergence) 접근이 가능하다 |
| Raw 로그 | Fluent Bit DaemonSet | 파싱 없이 원본 텍스트를 그대로 저장한다. 구조화는 콜백이 담당하고, Fluent Bit은 디버깅/에러 추적용이다 |
| 데이터 보존 | TTL 3단계 (90/180일/영구) | raw 로그(90일)는 빠르게 삭제하고, 구조화 메트릭(180일)은 더 오래 보관하며, 학습 요약은 영구 보관한다 |
| 전송 실패 처리 | try/except pass (학습 중단 안 함) | 메트릭 전송 실패가 학습을 중단시키면 안 된다. 로그 유실보다 학습 연속성이 중요하다 |
| 플랫폼 로그 수집 | 2티어 (Tier 1 수집, Tier 2 미수집) | 학습 파이프라인 critical path (OSMO, KubeRay, Karpenter)는 장애 추적을 위해 수집한다. 안정 서비스 (Keycloak, MLflow, JupyterHub)는 자체 로깅/audit 기능이 있어 kubectl logs로 충분하다 |
| 노드 시스템 로그 | Fluent Bit systemd INPUT → ClickHouse | GPU 노드의 NVIDIA Xid 에러, EFA 드라이버 실패, OOM kill은 node 레벨 로그에서만 확인 가능하다. 학습 중단 원인 추적에 필수이다 |
| EKS Control Plane 로그 | CloudWatch Logs (AWS 관리형) | API server, scheduler, controller manager 로그. 스케줄링/인증 문제 추적에 필요하며, EKS 설정 토글만으로 활성화된다 |
| ClickHouse 접근 제어 | 역할별 사용자 + Row Policy | researcher는 본인 학습 데이터만, engineer/admin은 전체 접근. 쓰기는 서비스 계정(writer)만. Keycloak 역할과 1:1 매핑하여 Phase 4 인증 체계를 재사용한다 |

---

## Service Flow

### 로깅 아키텍처 전체

```
┌─ Ray Worker Pod (GPU Node) ──────────────────────────────────────┐
│                                                                  │
│  rsl_rl training loop                                            │
│    │                                                             │
│    ├─ ClickHouseLogger callback                                  │
│    │   every 10 iteration batch                                  │
│    │   structured metrics direct INSERT                          │
│    │   (no parsing, type-safe)                                   │
│    │         │                                                   │
│    │         │ HTTP POST :8123                                   │
│    │         ▼                                                   │
│    │   ┌──────────────────────────────────────────────────┐      │
│    │   │          ClickHouse (Management Subnet)          │      │
│    │   │                                                  │      │
│    │   │  training_metrics    ◄── callback direct INSERT   │      │
│    │   │  (TTL: 180d)            structured, queryable    │      │
│    │   │                                                  │      │
│    │   │  training_raw_logs   ◄── Fluent Bit              │      │
│    │   │  (TTL: 90d)             raw text, no parsing     │      │
│    │   │                                                  │      │
│    │   │  training_summary    ◄── INSERT on completion    │      │
│    │   │  (permanent)            one row per training run  │      │
│    │   │                                                  │      │
│    │   │  Storage: EBS gp3 50Gi                           │      │
│    │   └──────────────────────────────────────────────────┘      │
│    │                                                             │
│    └─ stdout/stderr                                              │
│         │                                                        │
│         ▼                                                        │
│    ┌───────────────┐                                             │
│    │ Fluent Bit    │  DaemonSet (all nodes)                      │
│    │ (not sidecar) │  /var/log/containers/*training*.log        │
│    │               │  forward raw text, no parsing               │
│    └───────┬───────┘                                             │
│            │ HTTP POST :8123                                     │
│            └──────────────▶ training_raw_logs                    │
└──────────────────────────────────────────────────────────────────┘

┌─ Platform Pods (Management Node) ────────────────────────────────┐
│                                                                  │
│  OSMO Controller    (ns: osmo)                                   │
│  KubeRay Operator   (ns: kuberay)                                │
│  Karpenter          (ns: karpenter)                              │
│    │                                                             │
│    └─ stdout/stderr                                              │
│         │                                                        │
│         ▼                                                        │
│    ┌───────────────┐                                             │
│    │ Fluent Bit    │  /var/log/containers/*osmo*.log             │
│    │ (same DS)     │  /var/log/containers/*kuberay*.log          │
│    │               │  /var/log/containers/*karpenter*.log        │
│    └───────┬───────┘                                             │
│            │ HTTP POST :8123                                     │
│            └──────────────▶ platform_logs (TTL: 30 days)         │
└──────────────────────────────────────────────────────────────────┘

┌─ Node System (GPU + Management Nodes) ───────────────────────────┐
│                                                                  │
│  journald (systemd)                                              │
│    ├── kubelet          Pod scheduling, volume mount errors       │
│    ├── containerd       Container start failures, image pulls    │
│    └── kernel (dmesg)   NVIDIA Xid, EFA driver, OOM killer      │
│         │                                                        │
│         ▼                                                        │
│    ┌───────────────┐                                             │
│    │ Fluent Bit    │  systemd INPUT (GPU nodes only)             │
│    │ (same DS)     │  filter: nvidia, efa, oom, kubelet error    │
│    └───────┬───────┘                                             │
│            │ HTTP POST :8123                                     │
│            └──────────────▶ node_logs (TTL: 30 days)             │
└──────────────────────────────────────────────────────────────────┘

EKS Control Plane ──▶ CloudWatch Logs (AWS managed, Phase 2)
  api, scheduler, controller-manager, authenticator, audit
```

### 로그 수집 범위 (2티어)

학습 파이프라인 critical path는 수집하고, 자체 로깅/audit을 갖춘 안정 서비스는 수집하지 않는다.

| 티어 | 대상 | 이유 | 수집 |
|------|------|------|------|
| **Tier 1** | RL Training (Ray Worker) | 학습 메트릭, 디버깅 | ClickHouseLogger + Fluent Bit |
| **Tier 1** | OSMO Controller | RayJob 생성 실패 추적 | Fluent Bit → platform_logs |
| **Tier 1** | KubeRay Operator | Ray Cluster 라이프사이클 추적 | Fluent Bit → platform_logs |
| **Tier 1** | Karpenter | GPU 노드 프로비저닝 실패 추적 | Fluent Bit → platform_logs |
| **Tier 1** | Node system (GPU nodes) | NVIDIA Xid, EFA 에러, OOM kill, kubelet 에러 | Fluent Bit systemd → node_logs |
| **별도** | EKS Control Plane | API server, scheduler, controller 로그 | CloudWatch Logs (AWS 관리형) |
| **Tier 2** | Keycloak | 자체 admin event log + RDS audit | kubectl logs |
| **Tier 2** | MLflow | RDS 메타데이터 + 자체 UI | kubectl logs |
| **Tier 2** | JupyterHub | Hub 자체 로그로 충분 | kubectl logs |
| **Tier 2** | Grafana, Prometheus | 모니터링 도구 자체 문제는 빈도 낮음 | kubectl logs |

### 콜백 vs Fluent Bit 비교

```
                  ClickHouseLogger 콜백              Fluent Bit
                  ─────────────────────              ──────────
데이터 소스       rsl_rl 내부 딕셔너리               stdout 텍스트
데이터 형태       구조화 (Float64, UInt32)           raw 문자열
정보 범위         내부 메트릭 포함                    출력된 것만
                  (value_loss, grad_norm,
                   kl_divergence 등)
전송 주기         10 iteration 배치                  5초 flush
테이블           training_metrics                   training_raw_logs
용도              분석, 비교, 대시보드                디버깅, 에러 추적
TTL              180일                              90일
실패 시           학습 계속 (try/except)              로그 유실 (학습 무관)
```

### 로그 Lifecycle

```
Training starts
  │
  ▼
┌─────────────────────────────────────────────────────────────────┐
│ Hot (0~90 days)                                                 │
│   training_metrics    iteration metrics (callback)              │
│   training_raw_logs   raw text (Fluent Bit)                     │
│   training_summary    training summary (permanent)              │
│   platform_logs       OSMO/KubeRay/Karpenter (Fluent Bit)      │
│   node_logs           GPU node system logs (Fluent Bit)        │
└────────────────────────────┬────────────────────────────────────┘
                             │ after 90 days
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ Warm (90~180 days)                                              │
│   training_metrics    metrics only retained                     │
│   training_raw_logs   TTL expired (auto-deleted)                │
│   platform_logs       TTL expired (auto-deleted at 30 days)     │
│   node_logs           TTL expired (auto-deleted at 30 days)     │
│   training_summary    permanent                                 │
└────────────────────────────┬────────────────────────────────────┘
                             │ after 180 days
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ Archive (180+ days)                                             │
│   training_metrics    TTL expired (auto-deleted)                │
│   training_summary    permanent                                 │
│   S3 Glacier          full raw backup (restore on demand)       │
└─────────────────────────────────────────────────────────────────┘
```

---

## Steps

### 7-1. ClickHouse 배포

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: clickhouse
  namespace: logging
spec:
  serviceName: clickhouse
  replicas: 1
  selector:
    matchLabels:
      app: clickhouse
  template:
    metadata:
      labels:
        app: clickhouse
    spec:
      nodeSelector:
        node-type: management
      containers:
        - name: clickhouse
          image: clickhouse/clickhouse-server:24.8
          ports:
            - containerPort: 8123
              name: http
            - containerPort: 9000
              name: native
          volumeMounts:
            - name: data
              mountPath: /var/lib/clickhouse
          resources:
            requests:
              cpu: "2"
              memory: 4Gi
            limits:
              cpu: "2"
              memory: 4Gi
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: gp3
        resources:
          requests:
            storage: 50Gi
```

### 7-2. 테이블 DDL

테이블은 [MergeTree](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/mergetree) 엔진을 사용하며, TTL로 자동 삭제 정책을 적용한다.

#### training_metrics (구조화 메트릭 — 콜백 직접 INSERT)

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

#### training_raw_logs (원본 텍스트 — Fluent Bit)

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

#### platform_logs (플랫폼 컴포넌트 로그 — Fluent Bit)

```sql
CREATE TABLE platform_logs (
    timestamp     DateTime64(3),
    namespace     String,
    pod_name      String,
    container     String,
    node          String,
    raw_log       String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (namespace, timestamp)
TTL timestamp + INTERVAL 30 DAY DELETE;
```

학습 파이프라인 디버깅용. OSMO/KubeRay/Karpenter 로그를 30일간 보관한다. 학습 raw 로그(90일)보다 짧은 이유는 플랫폼 이벤트는 문제 발생 직후에만 참조하기 때문이다.

#### node_logs (노드 시스템 로그 — Fluent Bit systemd)

```sql
CREATE TABLE node_logs (
    timestamp     DateTime64(3),
    hostname      String,
    unit          String,
    priority      UInt8,
    raw_log       String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (hostname, timestamp)
TTL timestamp + INTERVAL 30 DAY DELETE;
```

GPU 노드의 커널/시스템 로그. NVIDIA Xid 에러, EFA 드라이버 실패, OOM kill, kubelet 에러를 30일간 보관한다. 학습이 중단되었을 때 해당 노드의 시스템 상태를 확인하는 용도이다.

### 7-3. ClickHouse Logger 콜백

[clickhouse-connect](https://clickhouse.com/docs/en/integrations/python) Python 클라이언트를 사용하여 구조화된 메트릭을 직접 INSERT한다.

```python
import os
import clickhouse_connect
from datetime import datetime

class ClickHouseLogger:
    def __init__(self, host="clickhouse.logging.svc.cluster.local",
                 port=8123, batch_size=10,
                 username="writer", password=None):
        self.client = clickhouse_connect.get_client(
            host=host, port=port,
            username=username,
            password=password or os.environ.get("CLICKHOUSE_WRITER_PASSWORD", ""),
        )
        self.buffer = []
        self.batch_size = batch_size

    def log(self, workflow_id, trial_id, sweep_id, task,
            iteration, log_dict):
        row = {
            "timestamp": datetime.utcnow(),
            "workflow_id": workflow_id,
            "trial_id": trial_id,
            "sweep_id": sweep_id,
            "task": task,
            "iteration": iteration,
            "mean_reward": log_dict.get("mean_reward", 0),
            "episode_length": log_dict.get("episode_length", 0),
            "value_loss": log_dict.get("value_loss", 0),
            "policy_loss": log_dict.get("policy_loss", 0),
            "entropy": log_dict.get("entropy", 0),
            "kl_divergence": log_dict.get("kl_divergence", 0),
            "grad_norm": log_dict.get("grad_norm", 0),
            # ... 기타 필드
        }
        self.buffer.append(row)

        if len(self.buffer) >= self.batch_size:
            self._flush()

    def _flush(self):
        try:
            self.client.insert("training_metrics",
                             [list(r.values()) for r in self.buffer],
                             column_names=list(self.buffer[0].keys()))
            self.buffer = []
        except Exception:
            pass  # 전송 실패 시 학습 중단 안 함

    def close(self):
        if self.buffer:
            self._flush()
```

핵심 설계:
- 10 iteration마다 배치 전송 (네트워크 부하 최소화)
- 전송 실패 시 학습을 중단하지 않음 (try/except pass)
- stdout 파싱이 아닌 rsl_rl 내부 딕셔너리 직접 접근 → 타입 보장, 버전 변경에도 안정적

### 7-4. Fluent Bit DaemonSet

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluent-bit
  namespace: logging
spec:
  selector:
    matchLabels:
      app: fluent-bit
  template:
    metadata:
      labels:
        app: fluent-bit
    spec:
      tolerations:
        - operator: Exists     # 모든 노드 (GPU 포함)
      containers:
        - name: fluent-bit
          image: fluent/fluent-bit:3.1
          volumeMounts:
            - name: varlog
              mountPath: /var/log
            - name: journal
              mountPath: /run/log/journal
              readOnly: true
            - name: machine-id
              mountPath: /etc/machine-id
              readOnly: true
            - name: config
              mountPath: /fluent-bit/etc/
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
      volumes:
        - name: varlog
          hostPath:
            path: /var/log
        - name: journal
          hostPath:
            path: /run/log/journal
        - name: machine-id
          hostPath:
            path: /etc/machine-id
        - name: config
          configMap:
            name: fluent-bit-config
```

### 7-5. Fluent Bit 설정

```ini
[SERVICE]
    Flush        5
    Log_Level    info

[INPUT]
    Name         tail
    Path         /var/log/containers/*training*.log
    Tag          training.*
    Parser       docker
    Mem_Buf_Limit 5MB

[FILTER]
    Name         kubernetes
    Match        training.*
    Kube_Tag_Prefix training.var.log.containers.
    Merge_Log    Off

[OUTPUT]
    Name         http
    Match        training.*
    Host         clickhouse.logging.svc.cluster.local
    Port         8123
    URI          /?query=INSERT+INTO+training_raw_logs+FORMAT+JSONEachRow
    Format       json_stream
    json_date_key timestamp
    json_date_format iso8601

# --- Tier 1 Platform Logs (OSMO, KubeRay, Karpenter) ---

[INPUT]
    Name         tail
    Path         /var/log/containers/*osmo*.log,/var/log/containers/*kuberay*.log,/var/log/containers/*karpenter*.log
    Tag          platform.*
    Parser       docker
    Mem_Buf_Limit 5MB

[FILTER]
    Name         kubernetes
    Match        platform.*
    Kube_Tag_Prefix platform.var.log.containers.
    Merge_Log    Off

[OUTPUT]
    Name         http
    Match        platform.*
    Host         clickhouse.logging.svc.cluster.local
    Port         8123
    URI          /?query=INSERT+INTO+platform_logs+FORMAT+JSONEachRow
    Format       json_stream
    json_date_key timestamp
    json_date_format iso8601

# --- Node System Logs (GPU nodes: Xid, EFA, OOM, kubelet) ---

[INPUT]
    Name         systemd
    Tag          node.*
    Path         /run/log/journal
    Read_From_Tail On
    Systemd_Filter _SYSTEMD_UNIT=kubelet.service
    Systemd_Filter _SYSTEMD_UNIT=containerd.service
    Systemd_Filter SYSLOG_IDENTIFIER=kernel

[FILTER]
    Name         grep
    Match        node.*
    Regex        MESSAGE (Xid|xid|EFA|efa|nccl|NCCL|oom|OOM|Out of memory|killed process|error|Error|fatal|Fatal|GPU fell off|fallen off)

[OUTPUT]
    Name         http
    Match        node.*
    Host         clickhouse.logging.svc.cluster.local
    Port         8123
    URI          /?query=INSERT+INTO+node_logs+FORMAT+JSONEachRow
    Format       json_stream
    json_date_key timestamp
    json_date_format iso8601
```

Fluent Bit은 파싱하지 않는다. raw 텍스트 그대로 ClickHouse에 저장. 구조화 메트릭은 콜백이 담당한다. Node system logs는 GPU 관련 키워드(Xid, EFA, OOM 등)가 포함된 메시지만 필터링하여 저장 볼륨을 최소화한다. [Fluent Bit HTTP Output](https://docs.fluentbit.io/manual/pipeline/outputs/http), [Kubernetes Filter](https://docs.fluentbit.io/manual/pipeline/filters/kubernetes), [Systemd Input](https://docs.fluentbit.io/manual/pipeline/inputs/systemd)을 활용한다.

### 7-6. ClickHouse 백업

[AWS Backup](https://docs.aws.amazon.com/aws-backup/latest/devguide/)을 통해 EBS 스냅샷을 관리한다.

```
1. EBS 스냅샷: 일 1회 (AWS Backup)
2. S3 아카이브: 180일 이상 데이터
   - clickhouse-backup 도구 사용
   - IRSA로 S3 logs-archive 버킷 write 권한
3. 복구 테스트: 월 1회 스냅샷 → 별도 볼륨 마운트 → 쿼리 검증
```

### 7-7. ClickHouse 접근 제어

역할별 사용자를 생성하고, 테이블/행 수준 권한을 적용한다. Keycloak 역할(researcher, engineer, admin)과 1:1 매핑한다.

#### 역할별 권한 매트릭스

| 테이블 | writer (서비스) | researcher | engineer | admin |
|--------|----------------|------------|----------|-------|
| training_metrics | INSERT | SELECT (본인 workflow만) | SELECT (전체) | SELECT (전체) |
| training_raw_logs | INSERT | SELECT (본인 workflow만) | SELECT (전체) | SELECT (전체) |
| training_summary | INSERT | SELECT (전체) | SELECT (전체) | SELECT (전체) |
| platform_logs | INSERT | 접근 불가 | SELECT (전체) | SELECT (전체) |
| node_logs | INSERT | 접근 불가 | SELECT (전체) | SELECT (전체) |
| DDL / SYSTEM | - | - | - | 전체 |

#### 사용자 및 역할 생성

```sql
-- 서비스 계정 (콜백, Fluent Bit INSERT 전용)
CREATE USER writer IDENTIFIED BY '${CLICKHOUSE_WRITER_PASSWORD}';
CREATE ROLE role_writer;
GRANT INSERT ON training_metrics TO role_writer;
GRANT INSERT ON training_raw_logs TO role_writer;
GRANT INSERT ON training_summary TO role_writer;
GRANT INSERT ON platform_logs TO role_writer;
GRANT INSERT ON node_logs TO role_writer;
GRANT role_writer TO writer;

-- researcher (본인 데이터만 조회)
CREATE USER researcher IDENTIFIED BY '${CLICKHOUSE_RESEARCHER_PASSWORD}';
CREATE ROLE role_researcher;
GRANT SELECT ON training_metrics TO role_researcher;
GRANT SELECT ON training_raw_logs TO role_researcher;
GRANT SELECT ON training_summary TO role_researcher;
-- platform_logs: 권한 없음
GRANT role_researcher TO researcher;

-- engineer (전체 조회)
CREATE USER engineer IDENTIFIED BY '${CLICKHOUSE_ENGINEER_PASSWORD}';
CREATE ROLE role_engineer;
GRANT SELECT ON training_metrics TO role_engineer;
GRANT SELECT ON training_raw_logs TO role_engineer;
GRANT SELECT ON training_summary TO role_engineer;
GRANT SELECT ON platform_logs TO role_engineer;
GRANT SELECT ON node_logs TO role_engineer;
GRANT role_engineer TO engineer;

-- admin (전체 권한)
CREATE USER ch_admin IDENTIFIED BY '${CLICKHOUSE_ADMIN_PASSWORD}';
GRANT ALL ON *.* TO ch_admin WITH GRANT OPTION;
```

#### Row-Level Security (researcher는 본인 workflow만)

ClickHouse [Row Policy](https://clickhouse.com/docs/en/sql-reference/statements/create/row-policy)를 사용하여 researcher가 본인이 제출한 학습 데이터만 조회하도록 제한한다.

workflow_id에 제출자 username을 prefix로 포함하는 네이밍 컨벤션을 사용한다 (예: `jsmith-h1-exp-001`).

```sql
-- training_metrics: researcher는 본인 workflow만
CREATE ROW POLICY researcher_own_metrics
ON training_metrics
FOR SELECT
USING workflow_id LIKE concat(currentUser(), '-%')
TO role_researcher;

-- 전체 접근 (engineer, admin)
CREATE ROW POLICY engineer_all_metrics
ON training_metrics
FOR SELECT
USING 1=1
TO role_engineer;

-- training_raw_logs: researcher는 본인 workflow만
CREATE ROW POLICY researcher_own_raw_logs
ON training_raw_logs
FOR SELECT
USING workflow_id LIKE concat(currentUser(), '-%')
TO role_researcher;

CREATE ROW POLICY engineer_all_raw_logs
ON training_raw_logs
FOR SELECT
USING 1=1
TO role_engineer;
```

training_summary는 row policy 없이 전체 조회를 허용한다. 학습 건당 1행으로 민감 데이터가 없고, 연구자 간 비교가 유용하다.

#### 접근 경로별 자격증명

| 접근 경로 | 사용자 결정 방식 | 비고 |
|-----------|-----------------|------|
| ClickHouseLogger callback | `writer` 고정 | Pod env에 writer 자격증명 주입 (Secret) |
| Fluent Bit | `writer` 고정 | ConfigMap URI에 `user=writer&password=...` 추가 |
| Grafana datasource | 역할별 2개 datasource | `ClickHouse-Researcher`, `ClickHouse-Engineer` |
| JupyterHub notebook | Keycloak role → 자격증명 매핑 | Hub spawner가 role에 따라 env 주입 |

#### Grafana: 역할별 ClickHouse 데이터소스

Grafana에 ClickHouse datasource를 2개 생성하고, [Grafana RBAC](https://grafana.com/docs/grafana/latest/administration/roles-and-permissions/)로 역할별 접근을 제한한다.

```yaml
datasources:
  - name: ClickHouse-Researcher
    type: grafana-clickhouse-datasource
    url: http://clickhouse.logging.svc.cluster.local:8123
    jsonData:
      defaultDatabase: default
      username: researcher
    secureJsonData:
      password: ${CLICKHOUSE_RESEARCHER_PASSWORD}

  - name: ClickHouse-Engineer
    type: grafana-clickhouse-datasource
    url: http://clickhouse.logging.svc.cluster.local:8123
    jsonData:
      defaultDatabase: default
      username: engineer
    secureJsonData:
      password: ${CLICKHOUSE_ENGINEER_PASSWORD}
```

대시보드 권한:
- Training Dashboard, HPO Dashboard → `ClickHouse-Researcher` datasource, Viewer 이상 접근
- Platform Pipeline Dashboard → `ClickHouse-Engineer` datasource, Editor 이상 접근
- Infrastructure Dashboard, Cost Dashboard → Prometheus datasource, Viewer 이상 접근

#### JupyterHub: 역할별 ClickHouse 자격증명 주입

JupyterHub spawner에서 Keycloak JWT의 role claim을 읽어 적절한 ClickHouse 자격증명을 환경변수로 주입한다.

```python
# jupyterhub_config.py (hub.extraConfig)
async def pre_spawn_hook(spawner):
    auth_state = await spawner.user.get_auth_state()
    roles = auth_state.get("oauth_user", {}).get("roles", [])

    if "engineer" in roles or "admin" in roles:
        spawner.environment["CLICKHOUSE_USER"] = "engineer"
        spawner.environment["CLICKHOUSE_PASSWORD"] = os.environ["CLICKHOUSE_ENGINEER_PASSWORD"]
    else:
        spawner.environment["CLICKHOUSE_USER"] = "researcher"
        spawner.environment["CLICKHOUSE_PASSWORD"] = os.environ["CLICKHOUSE_RESEARCHER_PASSWORD"]

c.Spawner.pre_spawn_hook = pre_spawn_hook
```

노트북에서는 환경변수를 사용하여 접속한다:

```python
import clickhouse_connect
import os

client = clickhouse_connect.get_client(
    host="clickhouse.logging.svc.cluster.local",
    port=8123,
    username=os.environ["CLICKHOUSE_USER"],
    password=os.environ["CLICKHOUSE_PASSWORD"],
)
```

researcher가 `platform_logs`를 쿼리하면 권한 에러가 반환된다. 본인 workflow 외 데이터를 조회하면 빈 결과가 반환된다 (row policy).

### 7-8. 유용한 쿼리 예시

```sql
-- 특정 학습의 reward 추이
SELECT iteration, mean_reward
FROM training_metrics
WHERE workflow_id = 'wf-001'
ORDER BY iteration;

-- HPO trial 비교
SELECT trial_id,
       max(mean_reward) AS best_reward,
       argMax(iteration, mean_reward) AS best_iter
FROM training_metrics
WHERE sweep_id = 'sweep-001'
GROUP BY trial_id
ORDER BY best_reward DESC;

-- 최근 1주 학습 요약
SELECT workflow_id, task,
       min(timestamp) AS started,
       max(iteration) AS total_iter,
       max(mean_reward) AS best_reward
FROM training_metrics
WHERE timestamp > now() - INTERVAL 7 DAY
GROUP BY workflow_id, task
ORDER BY started DESC;

-- 에러 로그 검색
SELECT timestamp, pod_name, raw_log
FROM training_raw_logs
WHERE workflow_id = 'wf-001'
  AND raw_log LIKE '%Error%'
ORDER BY timestamp;

-- OSMO Controller 에러 (학습 제출 실패 디버깅)
SELECT timestamp, pod_name, raw_log
FROM platform_logs
WHERE namespace = 'osmo'
  AND raw_log LIKE '%Error%'
ORDER BY timestamp DESC
LIMIT 50;

-- Karpenter 노드 프로비저닝 이벤트
SELECT timestamp, raw_log
FROM platform_logs
WHERE namespace = 'karpenter'
  AND raw_log LIKE '%provisioned%' OR raw_log LIKE '%failed%'
ORDER BY timestamp DESC
LIMIT 50;

-- 학습 파이프라인 전체 추적 (OSMO → KubeRay → Karpenter)
SELECT timestamp, namespace, pod_name, raw_log
FROM platform_logs
WHERE timestamp BETWEEN '2025-01-01 10:00:00' AND '2025-01-01 11:00:00'
ORDER BY timestamp;

-- GPU 노드 Xid 에러 (학습 중단 원인 추적)
SELECT timestamp, hostname, unit, raw_log
FROM node_logs
WHERE raw_log LIKE '%Xid%' OR raw_log LIKE '%xid%'
ORDER BY timestamp DESC
LIMIT 50;

-- 특정 노드의 OOM kill 이벤트
SELECT timestamp, hostname, raw_log
FROM node_logs
WHERE hostname = 'ip-10-100-0-42'
  AND raw_log LIKE '%oom%' OR raw_log LIKE '%Out of memory%'
ORDER BY timestamp DESC;

-- 학습 중단 크로스 디버깅: 학습 마지막 메트릭 + 같은 시간대 노드 에러
-- Step 1: 학습이 중단된 시점 확인
SELECT max(timestamp) AS last_metric_time, max(iteration) AS last_iter
FROM training_metrics
WHERE workflow_id = 'wf-001';

-- Step 2: 해당 시간대의 노드 시스템 에러 확인
SELECT timestamp, hostname, unit, raw_log
FROM node_logs
WHERE timestamp BETWEEN '2025-01-01 14:30:00' AND '2025-01-01 15:00:00'
ORDER BY timestamp;

-- Step 3: 같은 시간대의 플랫폼 이벤트 (Karpenter, KubeRay) 확인
SELECT timestamp, namespace, pod_name, raw_log
FROM platform_logs
WHERE timestamp BETWEEN '2025-01-01 14:30:00' AND '2025-01-01 15:00:00'
ORDER BY timestamp;
```

---

## References

- [ClickHouse Documentation](https://clickhouse.com/docs)
- [ClickHouse MergeTree Engine](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/mergetree)
- [clickhouse-connect Python Client](https://clickhouse.com/docs/en/integrations/python)
- [Fluent Bit Manual](https://docs.fluentbit.io/manual/)
- [Fluent Bit Kubernetes Filter](https://docs.fluentbit.io/manual/pipeline/filters/kubernetes)
- [Fluent Bit HTTP Output](https://docs.fluentbit.io/manual/pipeline/outputs/http)
- [Fluent Bit Systemd Input](https://docs.fluentbit.io/manual/pipeline/inputs/systemd)
- [EKS Control Plane Logging](https://docs.aws.amazon.com/eks/latest/userguide/control-plane-logs.html)
- [NVIDIA GPU Xid Errors](https://docs.nvidia.com/deploy/xid-errors/)
- [AWS Backup](https://docs.aws.amazon.com/aws-backup/latest/devguide/)
- [ClickHouse Access Control](https://clickhouse.com/docs/en/operations/access-rights)
- [ClickHouse Row Policy](https://clickhouse.com/docs/en/sql-reference/statements/create/row-policy)
- [Grafana RBAC](https://grafana.com/docs/grafana/latest/administration/roles-and-permissions/)

## Validation Checklist

- [ ] ClickHouse StatefulSet 정상 Running
- [ ] PVC 50Gi 마운트 확인
- [ ] 5개 테이블 생성 확인 (DDL 실행)
- [ ] 테스트 INSERT → SELECT 동작 확인
- [ ] Fluent Bit DaemonSet 모든 노드에 배포 확인
- [ ] 테스트 Pod 로그 → training_raw_logs 테이블에 저장 확인
- [ ] OSMO/KubeRay/Karpenter 로그 → platform_logs 테이블에 저장 확인
- [ ] ClickHouse HTTP API 접근 확인 (8123 포트)
- [ ] ClickHouse 사용자 4개 생성 확인 (writer, researcher, engineer, ch_admin)
- [ ] Row Policy 동작: researcher 사용자로 타인 workflow 조회 → 빈 결과
- [ ] Row Policy 동작: engineer 사용자로 전체 workflow 조회 → 정상
- [ ] researcher 사용자로 platform_logs, node_logs 조회 → 권한 에러
- [ ] GPU 노드 journald 로그 → node_logs 테이블에 저장 확인
- [ ] node_logs에서 Xid/EFA/OOM 키워드 필터링 동작 확인
- [ ] Grafana ClickHouse-Researcher / ClickHouse-Engineer datasource 연결 확인
- [ ] JupyterHub spawner role 기반 자격증명 주입 확인
- [ ] EBS 스냅샷 스케줄 설정

## Next

→ [Phase 8: Control Room](008-phase8-control-room.md)
