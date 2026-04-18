# Isaac Lab Humanoid RL Training Platform on AWS

## Overview

이 가이드는 NVIDIA Isaac Lab 기반 휴머노이드 강화학습(RL) 플랫폼을 AWS 환경에 구축하고 운영하기 위한 레퍼런스입니다.

H1 humanoid locomotion 정책을 대규모 GPU 클러스터에서 학습하고, 실험 추적/모델 관리/모니터링을 통합 운영하는 프로덕션 환경을 다룹니다.

---

## Platform Components

| 컴포넌트 | 도구 | 역할 |
|----------|------|------|
| 학습 프레임워크 | [Isaac Lab](https://isaac-sim.github.io/IsaacLab/) + rsl_rl | H1 humanoid PPO 학습 |
| 분산학습 / HPO | [Ray](https://docs.ray.io/en/latest/) (TorchTrainer, Tune) | 멀티노드 학습, 하이퍼파라미터 최적화 |
| 워크플로우 오케스트레이션 | [NVIDIA OSMO](https://docs.nvidia.com/osmo/) + [KubeRay](https://docs.ray.io/en/latest/cluster/kubernetes/index.html) | 학습 작업 제출/관리 |
| 컨테이너 오케스트레이션 | [Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/) | GPU/CPU 노드 관리 |
| GPU 오토스케일 | [Karpenter](https://karpenter.sh/docs/) | g6e.48xlarge 0-10대 |
| 고속 스토리지 | [FSx for Lustre](https://docs.aws.amazon.com/fsx/latest/LustreGuide/) | 체크포인트, 멀티노드 공유 |
| 실험 추적 / 모델 레지스트리 | [MLflow](https://mlflow.org/docs/latest/index.html) + S3 | 실험 메타데이터, 모델 버전 관리, 아티팩트 |
| 학습 로그 수집/분석 | [ClickHouse](https://clickhouse.com/docs) + [Fluent Bit](https://docs.fluentbit.io/manual/) | iteration 메트릭, raw 로그, SQL 분석 |
| 모니터링 | [Prometheus](https://prometheus.io/docs/) + [Grafana](https://grafana.com/docs/grafana/latest/) + [DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter) | GPU util, 인프라 메트릭, 대시보드, 알림 |
| 연구자 인터페이스 | [JupyterHub](https://jupyterhub.readthedocs.io/) | 학습 제출, 결과 분석, 시각화 |
| 인증 | [Keycloak](https://www.keycloak.org/documentation) (AD 연동) | OIDC, 역할 기반 접근 제어 |
| 네트워크 | [Direct Connect](https://docs.aws.amazon.com/directconnect/latest/UserGuide/) + Internal ALB | Private 전용, On-Prem 연결 |

---

## Infrastructure Summary

```
On-Premises
  ├── AD Server (LDAP)
  ├── RTX Pro 6000 x15 (단일 GPU: eval, debug, 시각화)
  └── Direct Connect ──→ AWS VPC

AWS VPC (10.100.0.0/21, Single AZ)
  ├── GPU Compute Subnet
  │   └── g6e.48xlarge x10 (8x L40S, EFA, FSx mount)
  ├── Management Subnet
  │   └── Keycloak, JupyterHub, MLflow, ClickHouse,
  │       Grafana, Prometheus, Ray Head, OSMO, Karpenter
  ├── Infrastructure Subnet
  │   └── Internal ALB, RDS, FSx for Lustre, VPC Endpoints x18
  └── S3: checkpoints, models, logs-archive, training-data
```

---

## Design Decisions

| 결정 | 이유 |
|------|------|
| **Single AZ** | EFA는 같은 AZ에서만 동작, FSx는 단일 AZ 리소스, 크로스 AZ 레이턴시가 NCCL 성능 저하 |
| **NAT Gateway 없음** | 외부 트래픽은 DX → On-Prem → 인터넷 경유 |
| **ClickHouse (Loki 대신)** | 학습 메트릭은 반정형 시계열 데이터, SQL 분석/학습 간 비교가 핵심 |
| **콜백 직접 INSERT (stdout 파싱 대신)** | regex 파싱은 rsl_rl 버전 변경 시 silent failure, 콜백은 타입 보장 + 내부 메트릭 접근 가능 |
| **JupyterHub (CLI 대신)** | 연구자가 제출/분석/시각화를 한 곳에서, 재현성 (노트북 자체가 기록) |
| **On-Prem GPU는 단일 GPU만** | DX 레이턴시로 분산학습 Worker 참여 부적합, eval/debug에 적합 |
| **모든 서비스 AWS 배치** | DX Outbound 비용 월 $5 미만, On-Prem 이중 운영 복잡도가 더 큰 비용 |

---

## Setup Phases

아래 순서대로 환경을 구축합니다. 각 Phase의 상세 내용은 개별 문서를 참조하세요.

```
Phase 1 ─→ 2 ─→ 3 ─→ 4 ─→ 5 ─→ 6 ─→ 7 ─→ 8 ─→ 9 ─→ 10
```

| Phase | 이름 | 문서 | 내용 |
|:-----:|------|------|------|
| 1 | **Foundation** | [phase1-foundation.md](phase1-foundation.md) | 네트워크 기반 — VPC, 서브넷, DX, VPC Endpoints, SG, Route53, TLS |
| 2 | **Platform** | [phase2-platform.md](phase2-platform.md) | 컴퓨팅/스토리지 기반 — EKS, CSI Drivers, RDS, S3, FSx, ECR, Karpenter, IRSA |
| 3 | **Bridge** | [phase3-bridge.md](phase3-bridge.md) | EKS Hybrid Nodes — On-Prem GPU 환경 설정, DX 연결 확인, S3 접근 검증 |
| 4 | **Gate** | [phase4-gate.md](phase4-gate.md) | 인증/인가 — Keycloak, AD Federation, OIDC Clients, 역할/권한, GPU 쿼터 |
| 5 | **Orchestrator** | [phase5-orchestrator.md](phase5-orchestrator.md) | 워크플로우 엔진 — OSMO Controller, KubeRay Operator, RBAC, CPU 테스트 |
| 6 | **Registry** | [phase6-registry.md](phase6-registry.md) | 실험 추적/모델 관리 — MLflow, S3 Artifact Store, 모델 레지스트리 |
| 7 | **Recorder** | [phase7-recorder.md](phase7-recorder.md) | 학습 로그 — ClickHouse, Fluent Bit, 테이블 DDL, Lifecycle |
| 8 | **Control Room** | [phase8-control-room.md](phase8-control-room.md) | 모니터링/알림 — Prometheus, Grafana, DCGM Exporter, 비용 모니터링 |
| 9 | **Lobby** | [phase9-lobby.md](phase9-lobby.md) | 연구자 인터페이스 — JupyterHub, 노트북 이미지, 샘플 노트북 |
| 10 | **Factory Floor** | [phase10-factory-floor.md](phase10-factory-floor.md) | GPU 학습 — 학습 이미지, 1GPU → 멀티GPU → 멀티노드 → HPO, E2E 검증 |

---

## Reference Documents

| 문서 | 설명 |
|------|------|
| [architecture.md](../architecture.md) | 전체 아키텍처 상세 (네트워크, 서브넷, 인증, 로깅, 모니터링 등) |
| [architecture-diagram.md](../architecture-diagram.md) | 아키텍처 다이어그램 (전체 구조, 인증 흐름, 학습 데이터 흐름, SG 등) |
