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
On-Premises (10.200.0.0/21)
  ├── AD Server (LDAP)
  ├── RTX Pro 6000 x15 (단일 GPU: eval, debug, 시각화)
  └── Direct Connect ──→ AWS VPC

AWS VPC (10.100.0.0/21, Single AZ)
  ├── GPU Compute Subnet (10.100.0.0/24)
  │   └── g6e.48xlarge x10 (8x L40S, EFA, FSx mount)
  ├── Management Subnet (10.100.1.0/24)
  │   └── Keycloak, JupyterHub, MLflow, ClickHouse,
  │       Grafana, Prometheus, Ray Head, OSMO, Karpenter
  ├── Infrastructure Subnet (10.100.2.0/24)
  │   └── Internal ALB, RDS, FSx for Lustre, VPC Endpoints x18
  ├── Reserved (10.100.3.0/24)
  │   └── 확장용
  ├── 미할당 (10.100.4.0/22, 1,022 IPs)
  │   └── 스케일업 시 서브넷 추가
  └── S3: checkpoints, models, logs-archive, training-data

총 할당: 1,016 / 2,048 IPs (50%), 확장 여유 충분
```

---

## Design Decisions

| 결정 | 이유 |
|------|------|
| **Single AZ** | EFA는 같은 AZ에서만 동작, FSx는 단일 AZ 리소스, 크로스 AZ 레이턴시(~0.5-1ms)가 NCCL 성능 저하. 크로스 AZ 데이터 전송 $0.01/GB 양방향 |
| **NAT Gateway 없음** | 외부 트래픽은 DX → On-Prem → 인터넷 경유. NAT GW 비용($100+/월) 절감 |
| **ClickHouse (Loki 대신)** | 학습 메트릭은 반정형 시계열 데이터, SQL 분석/학습 간 비교가 핵심 |
| **콜백 직접 INSERT (stdout 파싱 대신)** | regex 파싱은 rsl_rl 버전 변경 시 silent failure, 콜백은 타입 보장 + 내부 메트릭 접근 가능 |
| **JupyterHub (CLI 대신)** | 연구자가 제출/분석/시각화를 한 곳에서, 재현성 (노트북 자체가 기록) |
| **On-Prem GPU는 단일 GPU만** | DX 레이턴시로 분산학습 Worker 참여 부적합, eval/debug에 적합 |
| **모든 서비스 AWS 배치** | DX Outbound ~$0.02/GB, 월간 예상 ~$0.40 (체크포인트 다운로드 ~20GB). On-Prem 이중 운영 복잡도가 더 큰 비용 |

---

## Internal Services

| Hostname | Service | Port |
|----------|---------|------|
| jupyter.internal | JupyterHub | 8000 |
| grafana.internal | Grafana | 3000 |
| mlflow.internal | MLflow | 5000 |
| keycloak.internal | Keycloak | 8080 |
| ray.internal | Ray Dashboard | 8265 |
| osmo.internal | OSMO API | 8080 |

DNS: Route53 Private Hosted Zone → Internal ALB. On-Prem에서 Direct Connect를 통해서만 접근.

---

## Management Subnet Workloads

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

## Resilience & Backup

| 항목 | 전략 |
|------|------|
| 체크포인트 이중화 | 학습 중 FSx (고속 I/O), 매 N iteration S3에 비동기 백업. AZ 장애 시 S3에서 복구 |
| ClickHouse 백업 | EBS 스냅샷 일 1회 + S3 아카이브 (180일 이상 데이터 자동 이관) |
| Direct Connect 이중화 | DX 1회선 + Site-to-Site VPN 백업. VPN은 인터넷 경유, 비상 시 최소 접근 보장 |
| 학습 연속성 | 진행 중 학습은 AWS 내부 완결이므로 DX 장애와 무관하게 계속 실행 |

---

## Open Decisions

| 항목 | 선택지 | 상태 |
|------|--------|------|
| 관리 서비스 Multi-AZ | A. 전부 Single AZ / B. 관리만 Multi-AZ | 미결정 |
| GPU 오토스케일 범위 | A. 상시 N대 / B. 0→10 Karpenter | 미결정 |
| On-Prem 작업 관리 방식 | A. 직접 실행 / B. Ray 클러스터 / C. k3s | 미결정 |
| IaC 도구 | A. Terraform / B. CDK / C. Pulumi | 미결정 |
| Spot 인스턴스 허용 여부 | A. On-Demand only / B. Spot 허용 | 미결정 |

---

## Setup Phases

아래 순서대로 환경을 구축합니다. 각 Phase의 상세 내용은 개별 문서를 참조하세요.

```
Phase 1 ─→ 2 ─→ 3 ─→ 4 ─→ 5 ─→ 6 ─→ 7 ─→ 8 ─→ 9 ─→ 10
```

| Phase | 이름 | 문서 | 내용 |
|:-----:|------|------|------|
| 1 | **Foundation** | [1-phase1-foundation.md](1-phase1-foundation.md) | 네트워크 기반 — VPC, 서브넷, DX, VPC Endpoints, SG, Route53, TLS |
| 2 | **Platform** | [2-phase2-platform.md](2-phase2-platform.md) | 컴퓨팅/스토리지 기반 — EKS, CSI Drivers, RDS, S3, FSx, ECR, Karpenter, IRSA |
| 3 | **Bridge** | [3-phase3-bridge.md](3-phase3-bridge.md) | EKS Hybrid Nodes — On-Prem GPU 환경 설정, DX 연결 확인, S3 접근 검증 |
| 4 | **Gate** | [4-phase4-gate.md](4-phase4-gate.md) | 인증/인가 — Keycloak, AD Federation, OIDC Clients, 역할/권한, GPU 쿼터 |
| 5 | **Orchestrator** | [5-phase5-orchestrator.md](5-phase5-orchestrator.md) | 워크플로우 엔진 — OSMO Controller, KubeRay Operator, RBAC, CPU 테스트 |
| 6 | **Registry** | [6-phase6-registry.md](6-phase6-registry.md) | 실험 추적/모델 관리 — MLflow, S3 Artifact Store, 모델 레지스트리 |
| 7 | **Recorder** | [7-phase7-recorder.md](7-phase7-recorder.md) | 학습 로그 — ClickHouse, Fluent Bit, 테이블 DDL, Lifecycle |
| 8 | **Control Room** | [8-phase8-control-room.md](8-phase8-control-room.md) | 모니터링/알림 — Prometheus, Grafana, DCGM Exporter, 비용 모니터링 |
| 9 | **Lobby** | [9-phase9-lobby.md](9-phase9-lobby.md) | 연구자 인터페이스 — JupyterHub, 노트북 이미지, 샘플 노트북 |
| 10 | **Factory Floor** | [10-phase10-factory-floor.md](10-phase10-factory-floor.md) | GPU 학습 — 학습 이미지, 1GPU → 멀티GPU → 멀티노드 → HPO, E2E 검증 |

---

## Architecture Diagrams

| 문서 | 설명 |
|------|------|
| [99-architecture.md](99-architecture.md) | Phase별 아키텍처 다이어그램 (전체 구조, 인증 흐름, 학습 데이터 흐름 등) |
