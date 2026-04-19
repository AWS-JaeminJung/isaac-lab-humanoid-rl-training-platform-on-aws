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
```

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
└────────────────────────────┬────────────────────────────────────┘
                             │ after 90 days
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ Warm (90~180 days)                                              │
│   training_metrics    metrics only retained                     │
│   training_raw_logs   TTL expired (auto-deleted)                │
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

### 7-3. ClickHouse Logger 콜백

[clickhouse-connect](https://clickhouse.com/docs/en/integrations/python) Python 클라이언트를 사용하여 구조화된 메트릭을 직접 INSERT한다.

```python
import clickhouse_connect
from datetime import datetime

class ClickHouseLogger:
    def __init__(self, host="clickhouse.logging.svc.cluster.local",
                 port=8123, batch_size=10):
        self.client = clickhouse_connect.get_client(host=host, port=port)
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
```

Fluent Bit은 파싱하지 않는다. raw 텍스트 그대로 ClickHouse에 저장. 구조화 메트릭은 콜백이 담당한다. [Fluent Bit HTTP Output](https://docs.fluentbit.io/manual/pipeline/outputs/http)과 [Kubernetes Filter](https://docs.fluentbit.io/manual/pipeline/filters/kubernetes)를 활용한다.

### 7-6. ClickHouse 백업

[AWS Backup](https://docs.aws.amazon.com/aws-backup/latest/devguide/)을 통해 EBS 스냅샷을 관리한다.

```
1. EBS 스냅샷: 일 1회 (AWS Backup)
2. S3 아카이브: 180일 이상 데이터
   - clickhouse-backup 도구 사용
   - IRSA로 S3 logs-archive 버킷 write 권한
3. 복구 테스트: 월 1회 스냅샷 → 별도 볼륨 마운트 → 쿼리 검증
```

### 7-7. 유용한 쿼리 예시

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
```

---

## References

- [ClickHouse Documentation](https://clickhouse.com/docs)
- [ClickHouse MergeTree Engine](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/mergetree)
- [clickhouse-connect Python Client](https://clickhouse.com/docs/en/integrations/python)
- [Fluent Bit Manual](https://docs.fluentbit.io/manual/)
- [Fluent Bit Kubernetes Filter](https://docs.fluentbit.io/manual/pipeline/filters/kubernetes)
- [Fluent Bit HTTP Output](https://docs.fluentbit.io/manual/pipeline/outputs/http)
- [AWS Backup](https://docs.aws.amazon.com/aws-backup/latest/devguide/)

## Validation Checklist

- [ ] ClickHouse StatefulSet 정상 Running
- [ ] PVC 50Gi 마운트 확인
- [ ] 3개 테이블 생성 확인 (DDL 실행)
- [ ] 테스트 INSERT → SELECT 동작 확인
- [ ] Fluent Bit DaemonSet 모든 노드에 배포 확인
- [ ] 테스트 Pod 로그 → training_raw_logs 테이블에 저장 확인
- [ ] ClickHouse HTTP API 접근 확인 (8123 포트)
- [ ] EBS 스냅샷 스케줄 설정

## Next

→ [Phase 8: Control Room](008-phase8-control-room.md)
