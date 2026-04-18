# Phase 10: Factory Floor

GPU 학습 — 학습 이미지, 1GPU → 멀티GPU → 멀티노드 → HPO, E2E 검증

## Goal

실제 GPU를 투입하여 단계적으로 학습 파이프라인을 검증한다. 전체 시스템의 End-to-End 동작을 확인한다.

## Prerequisites

- Phase 1~9 모두 완료
- ECR에 프로덕션 학습 이미지 push 완료
- [Karpenter](https://karpenter.sh/docs/) GPU NodePool 설정 완료

## Design Decisions

| 결정 | 선택 | 이유 |
|------|------|------|
| 검증 전략 | 4단계 (1→8→16 GPU→HPO) | 단계별로 문제를 격리한다. 1 GPU에서 콜백/메트릭 문제를 먼저 해결하고, 멀티노드에서 네트워크 문제를 확인한다 |
| HPO 스케줄러 | ASHA (PBT, Hyperband 대신) | 조기 중단으로 유망하지 않은 trial의 GPU 시간을 절약한다. 구현이 단순하고 비동기 실행을 지원한다 |
| 성능 기준선 | 최초 풀 스케일 결과 기록 | 이후 코드/인프라 변경 시 성능 회귀를 감지하는 기준이 된다 |
| On-Prem eval | S3에서 체크포인트 다운로드 후 실행 | AWS GPU 비용 없이 On-Prem RTX Pro 6000으로 평가한다. DX 경유 S3 접근으로 간단하다 |

---

## Service Flow

### 단계별 검증 흐름

```
Stage 1: 단일 GPU (1x L40S)
  │  학습 스크립트 + 콜백 동작 확인
  │  ClickHouse, MLflow 연동 검증
  │
  ▼
Stage 2: 멀티 GPU (8x L40S, 1 노드)
  │  단일 노드 내 8 GPU 병렬 학습
  │  NVLink intra-node 통신 확인
  │
  ▼
Stage 3: 멀티 노드 (2 노드, 16 GPU)
  │  EFA inter-node 통신 확인
  │  FSx 공유 스토리지 확인
  │  스케일링 효율 측정
  │
  ▼
Stage 4: HPO (Ray Tune, 12 trial)
  │  ASHA 스케줄러 조기 중단
  │  다수 trial 동시 실행 (최대 32 GPU)
  │  trial별 메트릭/파라미터 기록
  │
  ▼
E2E 검증
  전체 시스템 통합 테스트
```

### E2E 전체 파이프라인

```
연구자 (On-Prem)
  │
  │ 1. jupyter.internal 접속
  ▼
JupyterHub ─── Keycloak OIDC ──── AD 인증
  │
  │ 2. osmo-client로 학습 제출
  ▼
OSMO Controller
  │  JWT 검증, gpu_quota 확인
  │
  │ 3. RayJob CRD 생성
  ▼
KubeRay Operator
  │
  │ 4. Ray Cluster 생성
  ▼
Karpenter ──── EC2 API ──── g6e.48xlarge 프로비저닝
  │                          EFA, FSx mount
  │
  │ 5. 학습 시작
  ▼
┌─ GPU Nodes ──────────────────────────────────────────────┐
│                                                          │
│  Isaac Lab + rsl_rl 학습 루프                            │
│    │                                                     │
│    ├── 체크포인트 ──▶ FSx ──▶ S3 (백업)                  │
│    ├── 메트릭 ──────▶ ClickHouse (training_metrics)      │
│    ├── stdout ──────▶ Fluent Bit ──▶ ClickHouse (raw)    │
│    └── 완료 시 ─────▶ MLflow (결과 + 모델)               │
│                                                          │
│  DCGM Exporter ──▶ Prometheus ──▶ Grafana                │
└──────────────────────────────────────────────────────────┘
  │
  │ 6. 연구자 모니터링
  ▼
┌─ 모니터링 ───────────────────────────────────────────────┐
│  Grafana (grafana.internal)                              │
│    ├── Training Dashboard: reward, loss, timing          │
│    └── Infrastructure Dashboard: GPU util, temp          │
│                                                          │
│  JupyterHub 노트북 (jupyter.internal)                    │
│    ├── ClickHouse SQL → reward curve                     │
│    └── MLflow API → 실험 비교                            │
└──────────────────────────────────────────────────────────┘
  │
  │ 7. 학습 완료
  ▼
MLflow Model Registry
  │  None → Staging → Production
  │
  │ 8. 모델 평가 (On-Prem GPU)
  ▼
On-Prem RTX Pro 6000 (단일 GPU)
  │  S3에서 체크포인트 다운로드
  │  시뮬 실행, 결과 ClickHouse 전송
  │
  │ 9. GPU 노드 축소
  ▼
Karpenter consolidation → GPU Node 종료 (비용 절감)
```

---

## Steps

### 10-1. 프로덕션 학습 이미지 최종 확인

```dockerfile
FROM nvcr.io/nvidia/isaac-lab:2.2.0

RUN pip install ray[default]==2.42.1

RUN pip install \
    clickhouse-connect \
    mlflow \
    boto3

COPY scripts/ /workspace/scripts/
COPY callbacks/ /workspace/callbacks/

ENV CLICKHOUSE_HOST=clickhouse.logging.svc.cluster.local
ENV MLFLOW_TRACKING_URI=https://mlflow.internal
```

이미지 태그는 immutable 정책에 따라 버전별로 관리한다 (v1.0.0, v1.0.1 등).

### 10-2. Stage 1 — 단일 GPU (1x L40S)

목적: 학습 스크립트, ClickHouse 콜백, MLflow 연동이 정상 동작하는지 확인.

```yaml
apiVersion: ray.io/v1
kind: RayJob
metadata:
  name: h1-single-gpu
  namespace: training
spec:
  entrypoint: >
    python /workspace/scripts/train.py
    --task H1-v0
    --num_envs 4096
    --max_iterations 100
    --headless
  rayClusterSpec:
    headGroupSpec:
      template:
        spec:
          nodeSelector:
            node-type: gpu
          tolerations:
            - key: nvidia.com/gpu
              operator: Exists
              effect: NoSchedule
          containers:
            - name: ray-head
              image: {ecr}/isaac-lab-training:v1.0.0
              resources:
                requests:
                  nvidia.com/gpu: "1"
                limits:
                  nvidia.com/gpu: "1"
              volumeMounts:
                - name: fsx
                  mountPath: /mnt/fsx
          volumes:
            - name: fsx
              persistentVolumeClaim:
                claimName: fsx-pvc
```

검증 항목:
- [ ] [Karpenter](https://karpenter.sh/docs/)가 g6e.48xlarge 프로비저닝
- [ ] Pod 정상 스케줄링 → 학습 시작
- [ ] ClickHouse training_metrics에 데이터 기록
- [ ] ClickHouse training_raw_logs에 로그 기록
- [ ] MLflow에 실험/파라미터/메트릭 기록
- [ ] FSx에 체크포인트 저장
- [ ] 학습 완료 후 Ray 클러스터 자동 삭제

### 10-3. Stage 2 — 멀티 GPU (8x L40S, 단일 노드)

목적: 단일 노드 내 8 GPU 병렬 학습 확인. [torch.distributed](https://pytorch.org/docs/stable/distributed.html)를 사용한다.

```yaml
entrypoint: >
  python -m torch.distributed.run
  --nproc_per_node=8
  /workspace/scripts/train.py
  --task H1-v0
  --num_envs 4096
  --max_iterations 500
  --headless

resources:
  requests:
    nvidia.com/gpu: "8"
  limits:
    nvidia.com/gpu: "8"
```

검증 항목:
- [ ] 8 GPU 모두 활용 확인 ([DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter) → Grafana)
- [ ] GPU utilization 70%+ 유지
- [ ] [NCCL](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/) 통신 정상 (intra-node NVLink)
- [ ] 체크포인트 저장/로드 정상
- [ ] 메트릭 정상 기록

### 10-4. Stage 3 — 멀티 노드 (2 노드, 16 GPU)

목적: 노드 간 분산학습 ([EFA](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)/[NCCL](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/)) 동작 확인.

```yaml
workerGroupSpecs:
  - groupName: gpu-workers
    replicas: 2
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
            image: {ecr}/isaac-lab-training:v1.0.0
            env:
              - name: NCCL_DEBUG
                value: "INFO"
              - name: FI_PROVIDER
                value: "efa"
            resources:
              requests:
                nvidia.com/gpu: "8"
              limits:
                nvidia.com/gpu: "8"
            volumeMounts:
              - name: fsx
                mountPath: /mnt/fsx
```

검증 항목:
- [ ] Karpenter가 2대 프로비저닝 (같은 AZ)
- [ ] [EFA](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html) 통신 활성화 확인 (NCCL_DEBUG=INFO 로그)
- [ ] 2노드 16 GPU 분산학습 정상
- [ ] FSx 공유 스토리지 접근 (양 노드)
- [ ] 스케일링: iteration throughput이 1노드 대비 ~1.8x

### 10-5. Stage 4 — HPO (Ray Tune, 다수 trial)

목적: [Ray Tune](https://docs.ray.io/en/latest/tune/index.html)을 활용한 HPO 파이프라인 검증. [ASHA Scheduler](https://docs.ray.io/en/latest/tune/api/schedulers.html)로 조기 중단을 적용한다.

```python
from ray import tune
from ray.tune.schedulers import ASHAScheduler

search_space = {
    "learning_rate": tune.loguniform(1e-4, 1e-2),
    "gamma": tune.uniform(0.95, 0.999),
    "clip_param": tune.uniform(0.1, 0.3),
    "num_envs": tune.choice([2048, 4096]),
}

scheduler = ASHAScheduler(
    max_t=5000,
    grace_period=500,
    reduction_factor=3
)

analysis = tune.run(
    train_fn,
    config=search_space,
    scheduler=scheduler,
    num_samples=12,
    resources_per_trial={"gpu": 8},
    max_concurrent_trials=4,
)
```

검증 항목:
- [ ] 다수 trial 동시 실행 (최대 4 trial x 8 GPU = 32 GPU)
- [ ] ASHA 스케줄러 조기 중단 동작
- [ ] 각 trial 메트릭이 ClickHouse에 개별 기록 (trial_id, sweep_id)
- [ ] MLflow에 trial별 run 기록
- [ ] Grafana HPO Dashboard에서 trial 비교 가능
- [ ] 학습 완료 후 GPU 노드 자동 축소 (Karpenter)

### 10-6. 성능 기준선 (Baseline)

최초 풀 스케일 학습 결과를 기준선으로 기록한다.

| 항목 | 기대값 |
|------|--------|
| 1 GPU throughput | ~X iter/sec |
| 8 GPU (1 노드) throughput | ~X iter/sec |
| 16 GPU (2 노드) throughput | ~X iter/sec |
| GPU utilization | 70%+ |
| EFA bandwidth | ~X Gbps |
| 체크포인트 저장 시간 | < X sec |
| ClickHouse INSERT 지연 | < 100ms |

실측 후 기록하여 이후 성능 회귀를 감지하는 기준으로 활용.

### 10-7. 운영 전환

모든 검증 통과 후:

```
1. Karpenter GPU NodePool: maxCapacity를 운영 수준으로 설정
2. OSMO GPU 쿼터: 역할별 할당량 최종 설정
3. ClickHouse 백업 스케줄 활성화
4. Alertmanager 알림 채널 연결
5. 연구자 온보딩 문서 배포
6. Grafana 대시보드 공유 링크 배포
```

---

## References

- [Ray Tune -- Hyperparameter Tuning](https://docs.ray.io/en/latest/tune/index.html)
- [ASHA Scheduler](https://docs.ray.io/en/latest/tune/api/schedulers.html)
- [NCCL User Guide](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/)
- [Elastic Fabric Adapter (EFA)](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
- [Karpenter Documentation](https://karpenter.sh/docs/)
- [torch.distributed](https://pytorch.org/docs/stable/distributed.html)
- [DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter)

## Validation Checklist

- [ ] Stage 1: 단일 GPU 학습 완료
- [ ] Stage 2: 8 GPU 단일 노드 학습 완료
- [ ] Stage 3: 2 노드 16 GPU 분산학습 완료
- [ ] Stage 4: HPO (12 trial) 완료
- [ ] E2E: JupyterHub → OSMO → 학습 → 모니터링 → 결과 분석 전체 흐름
- [ ] ClickHouse: 모든 stage 메트릭 기록 확인
- [ ] MLflow: 모든 stage 실험 기록 확인
- [ ] Grafana: Training + HPO + Infrastructure 대시보드 동작
- [ ] FSx → S3 체크포인트 백업 확인
- [ ] Karpenter: 학습 완료 후 GPU 노드 축소 확인
- [ ] On-Prem GPU: eval 작업 정상 실행
- [ ] 성능 기준선 기록 완료

## Done

모든 Phase가 완료되면 프로덕션 운영이 시작됩니다.

→ [Overview](overview.md)로 돌아가기
