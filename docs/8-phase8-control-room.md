# Phase 8: Control Room

모니터링/알림 — [Prometheus](https://prometheus.io/docs/), [Grafana](https://grafana.com/docs/grafana/latest/), [DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter), 비용 모니터링

## Goal

인프라/GPU 모니터링과 학습 메트릭 대시보드를 구축한다. [ClickHouse](https://clickhouse.com/docs) + [Prometheus](https://prometheus.io/docs/) 데이터소스를 [Grafana](https://grafana.com/docs/grafana/latest/)에 통합한다.

## Prerequisites

- Phase 2 완료 (EKS, EBS CSI Driver)
- Phase 4 완료 (Keycloak OIDC 클라이언트: grafana)
- Phase 7 완료 (ClickHouse 운영 중)

## Design Decisions

| 결정 | 선택 | 이유 |
|------|------|------|
| 모니터링 스택 | kube-prometheus-stack | Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics를 하나의 Helm Chart로 통합 배포한다 |
| GPU 모니터링 | DCGM Exporter | NVIDIA 공식 GPU 모니터링 도구이다. nvidia-smi보다 상세한 메트릭(온도, 전력, 메모리, ECC 에러)을 제공한다 |
| Grafana 데이터소스 | Prometheus + ClickHouse 이중 | 인프라 실시간 메트릭은 Prometheus, 학습 분석 메트릭은 ClickHouse. 데이터를 중복 저장하지 않는다 |
| 알림 라우팅 | severity 3단계 | critical은 Slack + PagerDuty 즉시 대응, warning은 Slack 알림, info는 Grafana annotation만 기록한다 |

---

## Service Flow

### 모니터링 데이터 흐름

```
┌─ GPU Node ───────────────────────┐   ┌─ Management Node ──────────────┐
│                                  │   │                                │
│  ┌──────────────┐                │   │  ┌──────────────────────────┐  │
│  │ DCGM Exporter│                │   │  │ kube-state-metrics       │  │
│  │ (DaemonSet)  │                │   │  │ node-exporter            │  │
│  │              │                │   │  │ Karpenter metrics        │  │
│  │ GPU util     │                │   │  └────────────┬─────────────┘  │
│  │ GPU temp     │                │   │               │                │
│  │ GPU memory   │                │   │               │                │
│  │ Power usage  │                │   │               │                │
│  └──────┬───────┘                │   │               │                │
│         │ :9400                  │   │               │                │
└─────────┼────────────────────────┘   └───────────────┼────────────────┘
          │                                            │
          └──────────────┬─────────────────────────────┘
                         │ scrape (pull)
                         ▼
              ┌───────────────────────┐
              │ Prometheus            │
              │ (Management Subnet)   │
              │                       │
              │ Retention: 15일       │
              │ Storage: EBS gp3 50Gi │
              │                       │
              │ Alertmanager          │
              │ → Slack / Email       │
              └───────────┬───────────┘
                          │
                          │ Prometheus 데이터소스
                          ▼
              ┌────────────────────────────────────────────┐
              │ Grafana (Management Subnet)                │
              │                                            │
              │  데이터소스:                               │
              │    ├── Prometheus  (인프라, GPU 메트릭)    │
              │    └── ClickHouse  (학습 메트릭, raw 로그) │
              │                                            │
              │  대시보드:                                 │
              │    ├── Training     (reward, loss, timing) │
              │    ├── HPO          (trial 비교, HP 분석)  │
              │    ├── Infrastructure (노드, Pod, 디스크)  │
              │    └── Cost         (GPU 시간, 노드 가동)  │
              │                                            │
              │  Auth: Keycloak OIDC                       │
              │    engineer → Editor                       │
              │    researcher, viewer → Viewer             │
              └────────────────────────────────────────────┘
                          │
                          │ HTTPS (Internal ALB)
                          ▼
              연구자 브라우저 (On-Prem via DX)
```

### 알림 흐름

```
Prometheus Alert Rules
  │
  │ 조건 충족 (e.g. GPU temp > 85°C, 5분 지속)
  ▼
Alertmanager
  │
  ├── severity: critical ──▶ Slack #alerts-critical
  │                          + PagerDuty (선택)
  │
  ├── severity: warning ──▶ Slack #alerts-warning
  │
  └── severity: info ──────▶ Grafana annotation only

Alert Examples:
  ├── GPUTemperatureHigh     (GPU 온도 > 85°C)
  ├── GPUMemoryFull          (GPU 메모리 > 95%)
  ├── TrainingStalled        (30분간 새 메트릭 없음)
  ├── NodeNotReady           (노드 NotReady 5분)
  └── PVCAlmostFull          (PVC 사용량 > 90%)
```

---

## Steps

### 8-1. Prometheus 배포

[kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) Helm Chart (v72.6.2 권장) 사용을 권장한다 (Prometheus + [Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/) + Grafana + node-exporter + kube-state-metrics 통합).

```
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set prometheus.prometheusSpec.retention=15d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=gp3 \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi \
  --set prometheus.prometheusSpec.nodeSelector.node-type=management \
  --set grafana.nodeSelector.node-type=management
```

### 8-2. [DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter) (GPU 메트릭)

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dcgm-exporter
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: dcgm-exporter
  template:
    metadata:
      labels:
        app: dcgm-exporter
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9400"
    spec:
      nodeSelector:
        node-type: gpu
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: dcgm-exporter
          image: nvcr.io/nvidia/k8s/dcgm-exporter:3.3.8-3.6.0-ubuntu22.04
          ports:
            - containerPort: 9400
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
          securityContext:
            runAsNonRoot: false
            runAsUser: 0
          volumeMounts:
            - name: device
              mountPath: /dev
      volumes:
        - name: device
          hostPath:
            path: /dev
```

수집 메트릭:
- DCGM_FI_DEV_GPU_UTIL: GPU utilization
- DCGM_FI_DEV_MEM_COPY_UTIL: Memory utilization
- DCGM_FI_DEV_GPU_TEMP: GPU temperature
- DCGM_FI_DEV_POWER_USAGE: Power consumption
- DCGM_FI_DEV_FB_USED: Framebuffer memory used

### 8-3. Grafana [Keycloak OIDC](https://www.keycloak.org/docs/latest/securing_apps/) 설정

```yaml
grafana.ini:
  auth.generic_oauth:
    enabled: true
    name: Keycloak
    client_id: grafana
    client_secret: ${GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET}
    scopes: openid profile email roles
    auth_url: https://keycloak.internal/realms/isaac-lab-production/protocol/openid-connect/auth
    token_url: https://keycloak.internal/realms/isaac-lab-production/protocol/openid-connect/token
    api_url: https://keycloak.internal/realms/isaac-lab-production/protocol/openid-connect/userinfo
    role_attribute_path: contains(roles[*], 'engineer') && 'Editor' || 'Viewer'
```

### 8-4. Grafana 데이터소스

| 데이터소스 | 유형 | 용도 |
|-----------|------|------|
| Prometheus | Prometheus | 인프라 메트릭, GPU util, 노드 상태 |
| ClickHouse | [ClickHouse Plugin](https://github.com/grafana/clickhouse-datasource) | 학습 메트릭, raw 로그, 실험 비교 |

```yaml
datasources:
  - name: ClickHouse
    type: grafana-clickhouse-datasource
    url: http://clickhouse.logging.svc.cluster.local:8123
    jsonData:
      defaultDatabase: default
```

### 8-5. Grafana 대시보드

#### Training Dashboard

| 패널 | 데이터소스 | 쿼리 |
|------|-----------|------|
| Reward 추이 | ClickHouse | SELECT iteration, mean_reward FROM training_metrics WHERE ... |
| Loss Curves | ClickHouse | value_loss, policy_loss, entropy |
| Grad Norm | ClickHouse | grad_norm by iteration |
| GPU Utilization | Prometheus | DCGM_FI_DEV_GPU_UTIL |
| Iteration Time | ClickHouse | iteration_time, collection_time, learning_time |

#### HPO Dashboard

| 패널 | 데이터소스 | 쿼리 |
|------|-----------|------|
| Trial 비교 | ClickHouse | sweep_id 기준 trial별 best_reward |
| HP Correlation | ClickHouse | hp_learning_rate vs best_reward scatter |
| Trial 진행 상황 | ClickHouse | 진행 중인 trial 수, 완료/중단 비율 |

#### Infrastructure Dashboard

| 패널 | 데이터소스 | 쿼리 |
|------|-----------|------|
| 노드 상태 | Prometheus | kube_node_status_condition |
| Pod 리소스 | Prometheus | container_cpu_usage, container_memory_usage |
| GPU 온도 | Prometheus | DCGM_FI_DEV_GPU_TEMP |
| 디스크 사용량 | Prometheus | node_filesystem_avail_bytes |
| 네트워크 | Prometheus | node_network_transmit_bytes_total |

#### Cost Dashboard

| 패널 | 데이터소스 | 쿼리 |
|------|-----------|------|
| GPU 시간 | Prometheus | sum(DCGM_FI_DEV_GPU_UTIL > 0) * 기간 |
| 노드 가동시간 | Prometheus | kube_node_created |
| Karpenter 이벤트 | Prometheus | karpenter_nodes_created_total |

### 8-6. 알림 규칙

```yaml
groups:
  - name: gpu-alerts
    rules:
      - alert: GPUTemperatureHigh
        expr: DCGM_FI_DEV_GPU_TEMP > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "GPU temperature above 85°C"

      - alert: GPUMemoryFull
        expr: DCGM_FI_DEV_FB_USED / DCGM_FI_DEV_FB_TOTAL > 0.95
        for: 2m
        labels:
          severity: critical

      - alert: TrainingStalled
        expr: |
          increase(
            clickhouse_training_metrics_count{workflow_id!=""}[30m]
          ) == 0
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "No new training metrics in 30 minutes"

      - alert: NodeNotReady
        expr: kube_node_status_condition{condition="Ready",status="true"} == 0
        for: 5m
        labels:
          severity: critical

      - alert: PVCAlmostFull
        expr: kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes < 0.1
        for: 10m
        labels:
          severity: warning
```

### 8-7. Ingress 설정

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internal
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: {acm-cert-arn}
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
spec:
  rules:
    - host: grafana.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kube-prometheus-stack-grafana
                port:
                  number: 3000
```

### 8-8. Route53 레코드

```
grafana.internal → Internal ALB (Alias)
```

---

## References

- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/grafana/latest/)
- [kube-prometheus-stack Helm Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter)
- [ClickHouse Grafana Plugin](https://github.com/grafana/clickhouse-datasource)
- [Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/)
- [Keycloak OIDC (for Grafana)](https://www.keycloak.org/docs/latest/securing_apps/)

## Validation Checklist

- [ ] Prometheus 정상 Running, PVC 마운트 확인
- [ ] kube-state-metrics, node-exporter 수집 확인
- [ ] DCGM Exporter GPU 노드에 DaemonSet 배포
- [ ] Prometheus에서 DCGM 메트릭 수집 확인
- [ ] https://grafana.internal 접근 → Keycloak 로그인
- [ ] ClickHouse 데이터소스 연결 성공
- [ ] Prometheus 데이터소스 연결 성공
- [ ] Training Dashboard에서 ClickHouse 쿼리 동작
- [ ] Infrastructure Dashboard에서 GPU util 표시
- [ ] 알림 규칙 등록 → 테스트 알림 발송

## Next

→ [Phase 9: Lobby](9-phase9-lobby.md)
