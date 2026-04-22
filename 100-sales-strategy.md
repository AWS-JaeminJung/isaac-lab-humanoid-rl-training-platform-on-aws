# Isaac Lab Production Platform — 세일즈 전략 및 가치 제안

이 아키텍처가 고객 유형별로 어떤 가치를 전달하는지, AWS 세일즈/SA가 어떤 시나리오에서 어떻게 접근할 수 있는지 정리한다.

---

## 1. 고객 유형별 가치 제안 (Value Proposition)

### 1-1. On-Prem GPU가 없는 고객

핵심 메시지: **"GPU 한 장 없이도, 연구팀이 내일부터 대규모 RL 학습을 시작할 수 있다."**

| 강점 | 의미 |
|------|------|
| **Zero Hardware, Immediate Start** | 장비 조달 리드타임 0. EKS + Karpenter로 필요할 때만 GPU 프로비저닝 |
| **Elastic GPU** | Baseline 2대로 시작 → Burst로 80 GPU까지 확장 → 학습 끝나면 자동 축소. 유휴 GPU 비용 없음 |
| **Spot 60-70% 절감** | HPO처럼 짧은 실험은 Spot으로 돌리면 동일 예산으로 2-3배 실험 가능 |
| **운영 부담 최소화** | Managed EKS + Karpenter + OSMO. GPU 노드 관리를 사람이 아니라 시스템이 함 |
| **Phased Cost Commitment** | 처음 3개월 On-Demand → 사용 패턴 확인 후 Compute SP. 과다 약정 리스크 없음 |
| **연구자 셀프서비스** | JupyterHub에서 학습 제출 → 모니터링 → 결과 분석까지. 인프라 팀 의존 없이 연구 진행 |

**이 고객이 가장 공감하는 Pain Point**: "GPU 서버 구매하면 3-6개월, 감가상각 3년. 근데 연구 방향이 바뀌면?" → 이 아키텍처는 instance type 변경이 tfvars 한 줄이다.

### 1-2. On-Prem GPU가 있는 고객

핵심 메시지: **"보유한 GPU는 그대로 쓰면서, 클라우드로 학습 규모만 확장한다."**

| 강점 | 의미 |
|------|------|
| **기존 투자 보전** | 보유 GPU가 버려지지 않음. EKS Hybrid Nodes로 동일 클러스터에 등록 |
| **역할 분리** | On-Prem = eval, debug, 시각화 (즉시 접근, 낮은 지연) / Cloud = 대규모 학습 (탄력적 GPU) |
| **단일 오케스트레이션** | OSMO가 On-Prem GPU와 Cloud GPU를 하나의 워크플로우로 관리. 연구자는 어디서 돌아가는지 신경 안 씀 |
| **점진적 전환** | Phase 3(Bridge)은 optional. On-Prem 없이 Phase 1-2만으로도 완전한 플랫폼 |
| **데이터 지역성** | Direct Connect로 On-Prem ↔ Cloud 간 checkpoint/metric 양방향 흐름 |
| **통합 모니터링** | ClickHouse + Grafana에서 On-Prem/Cloud 학습 결과를 한 화면에서 비교 |

**이 고객이 가장 공감하는 Pain Point**: "On-Prem GPU 15장으로는 HPO 한 번 돌리면 일주일. 근데 새 서버 구매 품의 올리면 6개월." → Karpenter Burst로 실험량 3배 확장, 끝나면 자동 정리.

### 1-3. 한 줄 요약

| 대상 | 핵심 메시지 |
|------|------------|
| GPU 없는 고객 | **"내일부터 대규모 GPU 학습. 하드웨어 구매 0, 운영 부담 최소"** |
| GPU 있는 고객 | **"보유 GPU는 그대로. 클라우드로 규모만 확장. 하나의 플랫폼에서 통합 관리"** |
| AWS AM | **"GPU 고정 소비 $430K+/yr, 서비스 폭 넓음, 확장 경로 명확, 레퍼런스 가치 높음"** |
| AWS SA | **"Day 2 운영까지 설계된 플랫폼. Managed service가 못 커버하는 NVIDIA 워크로드를 AWS primitives로 최적 조합"** |

---

## 2. AWS 내부 관점 (AM / SA)

### 2-1. Account Manager 관점: "이 딜이 왜 큰가"

| 포인트 | 설명 |
|--------|------|
| **높은 서비스 폭** | EKS, EC2 GPU (g7e/g6e), FSx Lustre, RDS, S3 x4, ECR, Direct Connect, Route53, ACM, CloudWatch, Secrets Manager, VPC Endpoints x18. 단일 워크로드가 이 정도 서비스를 쓰는 건 드문 고객 |
| **GPU 장기 소비** | Baseline 2대 = 월 ~$36K 고정 + Burst 변동. 1년이면 $430K+ GPU만으로. Compute SP 전환 시 3년 lock-in 가능 |
| **확장 경로가 명확** | 연구팀 성과 → GPU 증설 → Baseline 4대, Burst 160 GPU. 성공하면 consumption이 2-3배 |
| **레퍼런스 가치** | "NVIDIA Isaac Lab + AWS EKS로 humanoid RL 학습 플랫폼" → Robotics/AI 고객 대상 레퍼런스 아키텍처 |
| **Direct Connect 매출** | DX 전용선 = 월 고정 매출 + 데이터 전송 비용 |

### 2-2. Solutions Architect 관점: "고객에게 어떤 기술 가치를 전달하나"

**1) "Build vs. Buy" 프레이밍을 깨는 아키텍처**

> "SageMaker 같은 managed service를 안 쓰는 게 아니라, **Isaac Lab이라는 특수 워크로드에 맞게 AWS primitives를 조합한 것**이다."

Isaac Lab + OSMO + KubeRay는 NVIDIA 생태계라서 SageMaker로 대체 불가. 하지만 밑단(EKS, GPU, Storage, Networking)은 전부 AWS managed. 고객 입장에서는 **최적화된 custom platform이면서도 운영 부담은 managed 수준**.

**2) Day 2 운영 성숙도**

| 관점 | 구현 |
|------|------|
| 비용 제어 | OSMO GPU 쿼터 → 사용자별 상한, Karpenter → 자동 정리, ResourceQuota → 네임스페이스 상한 |
| 관찰 가능성 | DCGM → GPU utilization, ClickHouse → 학습 메트릭, Prometheus → 인프라, Grafana → 통합 대시보드 |
| 보안 | Keycloak OIDC + AD Federation, IRSA, Private Endpoint Only, VPC Endpoints, Network Policy |
| 장애 복원 | Spot 인터럽트 → OD fallback, Checkpoint → FSx + S3 backup, RDS 백업 7일 |

"GPU 몇 대 띄우는 건 누구나 한다. **누가 얼마나 쓰고 있는지 보이고, 제어되고, 장애 시 복원되는 플랫폼**을 만드는 게 어렵다."

**3) Hybrid는 Lock-in이 아니라 Bridge**

> "On-Prem GPU를 EKS에 등록하는 건 AWS에 종속시키는 게 아니라, **고객이 가진 자산을 Cloud-native 방식으로 관리하게 해주는 것**이다. 나중에 On-Prem을 줄이든, Cloud를 줄이든 고객이 선택한다."

Phase 3(Bridge)이 **optional**이라는 설계가 중요하다. 빼도 전체 아키텍처가 동작한다.

**4) 비용 대화를 "절감"이 아니라 "효율"로**

```
❌ "Spot 쓰면 60% 절감됩니다"
✅ "같은 $65K로 Baseline 16 GPU 상시 + Burst 80 GPU까지 탄력적으로 쓸 수 있습니다.
    연구자가 금요일에 HPO 100 trial 제출하면, 주말 동안 Spot으로 돌리고
    월요일에 결과를 받습니다. On-Demand로만 하면 4배 시간이 걸립니다."
```

---

## 3. 세일즈 접근 시나리오

### 시나리오 A: 로보틱스 스타트업 — "GPU 없이 시작하는 팀"

**고객 프로필**
- 직원 20-50명, ML 엔지니어 3-5명
- 자체 GPU 서버 없음. 로컬 RTX 4090 몇 장으로 실험 중
- NVIDIA Isaac Sim/Lab 도입 검토 중
- 월 예산 $20K-50K (시드/시리즈A)

**Pain Point**
- "GPU 서버 구매하면 감가상각 3년인데, 우리 회사가 3년 뒤에도 같은 연구를 하고 있을지 모른다"
- "팀원이 로컬에서 각자 실험하니까 재현성이 없다. 누가 어떤 하이퍼파라미터로 돌렸는지 모른다"
- "HPO 한 번 돌리려면 RTX 4090 한 장으로 2주. 그 동안 다른 사람은 실험 못 함"

**접근 전략**

| 단계 | 액션 |
|------|------|
| Discovery | "현재 GPU 학습 환경이 어떻게 되어 있나요?" → 로컬 GPU 한계 공감 |
| Pain Amplification | "HPO 한 번에 2주면, 연간 실험 횟수가 24회로 제한됩니다. 경쟁사가 클라우드에서 주 2회 HPO를 돌리고 있다면?" |
| Solution Framing | "이 아키텍처는 Phase 1-2만 배포하면 바로 쓸 수 있습니다. Phase 3(On-Prem Bridge)은 나중에 GPU 서버를 구매하면 그때 연결하면 됩니다" |
| Sizing | Baseline 1대(8 GPU) + Burst Spot으로 시작 → 월 ~$25K |
| Quick Win | "2주 PoC: 기존에 로컬에서 2주 걸리던 HPO를 클라우드에서 하루에 끝내는 걸 보여드리겠습니다" |

**제안 구성 (경량화)**

```
Phase 1 (Network)  — VPC, Subnet (DX 제외, VPN만)
Phase 2 (Platform) — EKS, Baseline 1대, Burst Spot
Phase 5 (OSMO)     — 워크플로우 오케스트레이션
Phase 6 (MLflow)   — 실험 추적
Phase 9 (Jupyter)  — 연구자 인터페이스
```

Phase 3(Bridge), 4(Keycloak), 7(ClickHouse), 8(Monitoring)은 생략하거나 후속 구현.

**킬링 메시지**: "GPU 서버 한 대 가격($150K)으로 1년간 클라우드에서 탄력적으로 학습할 수 있습니다. 서버는 3년 후에도 그 서버지만, 클라우드는 내년에 더 빠른 GPU로 바꿀 수 있습니다."

---

### 시나리오 B: 대기업 R&D 센터 — "On-Prem GPU는 있지만 부족한 팀"

**고객 프로필**
- 대기업 로보틱스/자율주행 R&D 부서
- On-Prem GPU 서버 10-50대 보유 (DGX, A100, H100 등)
- 내부 Slurm/Kubernetes 클러스터 운영 중
- 월 예산 $50K-200K
- 보안/컴플라이언스 요구사항 높음

**Pain Point**
- "On-Prem GPU가 항상 부족하다. 부서 간 GPU 쟁탈전이 벌어진다"
- "새 GPU 서버 구매 품의 → 승인 → 발주 → 설치까지 6-12개월"
- "학회 데드라인 전에 실험을 몰아서 해야 하는데, 그때만 GPU가 부족하다"
- "On-Prem에 이미 투자한 GPU를 버릴 수는 없다"

**접근 전략**

| 단계 | 액션 |
|------|------|
| Discovery | "현재 On-Prem GPU utilization이 어떻게 되나요? Peak vs. Average?" → 대부분 Average 40-60%, Peak 100% |
| Pain Amplification | "학회 데드라인 3주 전에 GPU 사용률 100%이면, 3주간의 실험 기회비용은 얼마인가요?" |
| Hybrid Framing | "On-Prem은 유지합니다. 평소에는 On-Prem으로 충분하고, Peak 때만 클라우드로 버스트합니다. EKS Hybrid Nodes로 하나의 클러스터에서 관리합니다" |
| Cost Justification | "On-Prem A100 서버 1대 = ~$200K (3년 감가). 월 $65K로 클라우드에서 Baseline 16 GPU + Burst 80 GPU. Peak 3개월만 Burst 쓰면 연 $60K 추가. 서버 1대 가격으로 3년 Burst" |
| Security Assurance | "Private Endpoint Only, VPC Endpoints, Direct Connect, Keycloak + AD Federation. 데이터가 인터넷에 나가지 않습니다" |

**킬링 메시지**: "GPU 구매 품의에 6개월 쓰는 대신, 다음 주부터 클라우드 GPU를 붙여서 실험량을 3배로 늘릴 수 있습니다. On-Prem 투자는 그대로 유지됩니다."

---

### 시나리오 C: 제조업/물류 — "로보틱스 AI를 처음 시작하는 팀"

**고객 프로필**
- 제조/물류 대기업, IT 인프라팀은 있지만 ML 인프라 경험 없음
- Isaac Sim으로 로봇 시뮬레이션 PoC 진행 중
- GPU 학습 플랫폼 자체가 처음
- "SageMaker 쓰면 되는 거 아닌가요?" 단계

**Pain Point**
- "ML 인프라를 어떻게 구축해야 하는지 모른다"
- "SageMaker로 시작했는데 Isaac Lab이 안 돌아간다"
- "실험 관리, 모델 버전, GPU 모니터링을 각각 다른 도구로 하고 있다"

**접근 전략**

| 단계 | 액션 |
|------|------|
| Education | "Isaac Lab은 NVIDIA 전용 RL 프레임워크라서 SageMaker Training Job에 맞지 않습니다. OSMO + KubeRay가 네이티브 오케스트레이터입니다" |
| Complexity Reduction | "10개 Phase로 보이지만, 핵심은 3개입니다: Network(1) + Platform(2) + Orchestrator(5). 나머지는 점진적으로 추가" |
| Managed Experience | "연구자는 JupyterHub에서 코드 작성 → 버튼 하나로 학습 제출. 인프라는 Terraform + Helm으로 코드화되어 있어서 재현 가능합니다" |
| Risk Reduction | "2주 PoC로 기존 Isaac Lab 코드를 그대로 클라우드에서 돌려봅시다. 코드 변경 없이 GPU만 바꾸는 겁니다" |

**킬링 메시지**: "ML 인프라 전문가를 채용하는 데 6개월, 플랫폼 구축에 1년 걸립니다. 이 아키텍처는 검증된 레퍼런스입니다. Terraform apply 한 번이면 동일한 환경이 생깁니다."

---

### 시나리오 D: 학교/연구소 — "예산은 적지만 논문은 급한 팀"

**고객 프로필**
- 대학 로보틱스 연구실 또는 공공 연구기관
- 연간 GPU 예산 $50K-150K (클라우드 크레딧 포함)
- 학생/연구원 5-15명이 GPU를 공유
- 논문 데드라인에 실험 집중

**Pain Point**
- "랩 GPU 4장을 10명이 돌아가며 쓴다. 데드라인 때 야근하면서 순서 기다린다"
- "예산이 제한적이라 GPU를 효율적으로 써야 한다"
- "학생들이 GPU를 할당받고 안 쓰면서 점유하고 있다"

**접근 전략**

| 단계 | 액션 |
|------|------|
| Empathy | "10명이 GPU 4장 공유하면 평균 대기 시간이 어떻게 되나요?" |
| Quota Management | "OSMO GPU 쿼터로 학생별 최대 GPU 수를 제한합니다. 교수는 32 GPU, 학생은 8 GPU. 자동 강제" |
| Cost Control | "Spot 위주로 구성하면 동일 예산으로 3배 실험. Baseline 없이 전부 Karpenter Burst로 구성하면 사용한 만큼만 과금" |
| Academic Program | AWS 학술 크레딧 프로그램 연계. $10K-100K 크레딧 지원 가능 |

**제안 구성 (최소화)**

```
Baseline: 0대 (비용 최소화)
Burst: Karpenter Spot only (g6e family, 비용 효율)
Storage: S3 only (FSx 생략, EBS gp3 최소)
Auth: 간소화 (Keycloak 대신 Cognito)
```

**킬링 메시지**: "DGX 한 대 구매비 $200K로 3년 쓰는 것보다, 같은 금액으로 클라우드에서 4년간 탄력적으로 쓰는 게 논문 생산성이 높습니다."

---

### 시나리오 E: ISV/SaaS — "RaaS (Robotics-as-a-Service) 플랫폼 구축"

**고객 프로필**
- 로보틱스 SaaS 스타트업, 고객사에 학습된 모델을 제공
- 멀티테넌트 필요: 고객사별 격리된 학습 환경
- API 기반 학습 제출 필요
- 월 예산 $100K-500K (고객사 과금 모델)

**Pain Point**
- "고객사마다 다른 로봇, 다른 환경. 학습 환경을 고객별로 격리해야 한다"
- "고객사가 늘어날 때 GPU를 탄력적으로 확장해야 한다"
- "각 고객사의 비용을 정확히 추적해야 한다"

**접근 전략**

| 단계 | 액션 |
|------|------|
| Multi-tenancy | "Kubernetes namespace + RBAC + Network Policy로 고객사별 완전 격리. OSMO GPU 쿼터로 고객사별 GPU 상한" |
| API-first | "OSMO API로 학습 제출 자동화. 고객사 시스템에서 직접 API 호출 가능" |
| Cost Attribution | "ClickHouse + 커스텀 라벨로 고객사별 GPU 사용 시간 추적 → 정확한 과금" |
| Elastic Scaling | "고객사가 10개에서 50개로 늘어도 Karpenter가 자동 확장. Burst 최대를 늘리면 됨" |

**킬링 메시지**: "고객사 한 곳 추가할 때마다 서버를 구매하는 모델에서, namespace 하나 추가하는 모델로 전환하세요. 한계비용이 거의 0입니다."

---

## 4. 세일즈 전략 프레임워크

### 4-1. Discovery 질문 템플릿

고객 미팅 시 상황을 파악하기 위한 질문 구조:

**현재 상태 파악**
```
1. "현재 GPU 학습 환경이 어떻게 구성되어 있나요?"
   → On-Prem/Cloud/없음 분류
2. "연구자/엔지니어가 몇 명이고, GPU 자원을 어떻게 공유하나요?"
   → GPU 경합 정도 파악
3. "평균 학습 시간과 GPU 사용률이 어떻게 되나요?"
   → 워크로드 패턴 파악
4. "실험 관리(MLflow 등), 모니터링, 로깅은 어떻게 하고 있나요?"
   → Day 2 성숙도 파악
```

**Pain Point 발굴**
```
5. "GPU가 부족해서 실험을 못 돌린 적이 있나요? 얼마나 자주?"
   → 기회비용 정량화
6. "새 GPU 서버를 추가하려면 얼마나 걸리나요?"
   → 조달 리드타임
7. "학습 결과의 재현성을 어떻게 보장하고 있나요?"
   → 실험 관리 필요성
8. "GPU 비용을 팀/프로젝트별로 추적하고 있나요?"
   → 비용 가시성 필요
```

**의사결정 구조**
```
9. "GPU 인프라 결정권자가 누구인가요? (CTO? VP Engineering? 랩장?)"
10. "예산 사이클이 어떻게 되나요? (분기? 연간?)"
11. "기존에 검토했거나 PoC한 솔루션이 있나요?"
```

### 4-2. Objection Handling (반론 대응)

| 반론 | 대응 |
|------|------|
| **"SageMaker 쓰면 되지 않나요?"** | "SageMaker Training Job은 PyTorch/TensorFlow 표준 워크로드에 최적화되어 있습니다. Isaac Lab은 NVIDIA Isaac Sim 위에서 GPU 렌더링 + RL 학습을 동시에 하는 특수 워크로드라서, OSMO + KubeRay가 네이티브 오케스트레이터입니다. 밑단은 전부 AWS managed(EKS, GPU, FSx)이니 운영 부담은 비슷합니다." |
| **"너무 복잡하다. 10 Phase?"** | "10 Phase는 프로덕션 전체 구성입니다. 시작은 Phase 1+2+5 세 개면 충분하고, 2주면 배포됩니다. 나머지는 필요할 때 하나씩 추가하면 됩니다." |
| **"On-Prem이 더 싸지 않나요?"** | "3년 TCO로 비교해봅시다. DGX H100 1대 = ~$300K + 전력/공간/운영 인건비. AWS에서 같은 GPU 시간을 Spot + SP로 쓰면 3년에 ~$400K이지만, 탄력적으로 0~80 GPU 사이를 오갈 수 있습니다. Peak 때 10대가 필요하면 On-Prem은 10대를 사야 하지만, 클라우드는 Peak 때만 10대를 씁니다." |
| **"데이터가 클라우드에 나가면 안 됩니다"** | "이 아키텍처는 Private Endpoint Only입니다. EKS API도, S3도, ECR도 전부 VPC Endpoint를 통합니다. 인터넷 게이트웨이가 없습니다. Direct Connect로 On-Prem과 전용선으로 연결되고, 데이터는 VPC 밖으로 나가지 않습니다." |
| **"Spot은 불안정하지 않나요?"** | "맞습니다. 그래서 분산학습에는 Spot을 쓰지 않습니다. Baseline 2대(On-Demand, 항상 켜짐)가 장시간/멀티노드 학습을 담당하고, Spot은 HPO처럼 짧고 독립적인 실험에만 씁니다. 인터럽트 시 On-Demand fallback이 자동입니다." |
| **"Kubernetes 운영할 인력이 없습니다"** | "이 아키텍처는 Terraform + Helm으로 코드화되어 있습니다. `terraform apply` 한 번이면 동일한 환경이 생기고, Day 2 운영(모니터링, 로깅, 알림)도 내장되어 있습니다. 연구자는 JupyterHub만 쓰면 됩니다. Kubernetes를 직접 다룰 일이 없습니다." |
| **"NVIDIA가 직접 지원하는 DGX Cloud가 있는데?"** | "DGX Cloud는 NVIDIA managed라서 편리하지만, 커스터마이징이 제한됩니다. 이 아키텍처는 고객이 인프라를 완전히 소유하고, NVIDIA 소프트웨어(OSMO, Isaac Lab)와 AWS 인프라를 최적 조합한 것입니다. 벤더 종속 없이 고객이 통제권을 갖습니다." |

### 4-3. PoC 제안 프레임워크

**2주 PoC 구성**

```
Week 1: 인프라 배포
  - Day 1-2: Phase 1 (Network) + Phase 2 (EKS + GPU)
  - Day 3:   Phase 5 (OSMO + KubeRay)
  - Day 4:   Phase 9 (JupyterHub) + Phase 6 (MLflow)
  - Day 5:   GPU Preflight + 단일 GPU 학습 검증

Week 2: 고객 워크로드 실행
  - Day 1-2: 고객 Isaac Lab 코드를 컨테이너화
  - Day 3:   단일 노드 8 GPU 학습 실행 + 결과 비교
  - Day 4:   멀티노드 16 GPU 학습 + HPO (Spot)
  - Day 5:   결과 데모 + 프로덕션 마이그레이션 계획
```

**PoC 성공 기준 (고객과 사전 합의)**

| 기준 | 목표 |
|------|------|
| 학습 속도 | On-Prem 대비 동등 이상 (GPU 당 throughput) |
| 확장성 | 1 GPU → 8 GPU → 16 GPU 선형 확장 확인 |
| 셀프서비스 | 연구자가 JupyterHub에서 직접 학습 제출 가능 |
| 실험 추적 | MLflow에서 실험 비교/재현 가능 |
| 비용 가시성 | GPU 사용 시간 + 비용 추적 가능 |

### 4-4. 가격 모델링 가이드

고객 예산별 권장 구성:

| 월 예산 | Baseline | Burst | 스토리지 | 권장 고객 |
|---------|----------|-------|---------|----------|
| **$20K** | 0대 | Spot only (max 16 GPU) | S3 only | 스타트업, 학교 |
| **$40K** | 1대 (8 GPU) | Spot + OD (max 40 GPU) | FSx 1.2TB + S3 | 중소기업 R&D |
| **$65K** | 2대 (16 GPU) | Spot + OD (max 80 GPU) | FSx 1.2TB + S3 | 대기업 R&D (현재 아키텍처) |
| **$130K** | 4대 (32 GPU) | Spot + OD (max 160 GPU) | FSx 2.4TB + S3 | 대규모 연구소 |
| **$200K+** | 8대 (64 GPU) | Spot + OD (max 320 GPU) | FSx 4.8TB + S3 | ISV/멀티테넌트 |

### 4-5. 경쟁 비교

| 항목 | 이 아키텍처 (EKS + OSMO) | SageMaker | DGX Cloud | On-Prem Slurm |
|------|--------------------------|-----------|-----------|---------------|
| Isaac Lab 네이티브 | O (OSMO + KubeRay) | X (커스텀 컨테이너 필요) | O | O |
| GPU 탄력성 | O (Karpenter 0→N) | O (Training Job) | 제한적 | X (고정) |
| Spot 지원 | O (Burst NodePool) | O (Managed Spot) | X | X |
| Hybrid (On-Prem) | O (EKS Hybrid Nodes) | X | X | O (기본) |
| 인프라 소유권 | 고객 100% | AWS managed | NVIDIA managed | 고객 100% |
| Day 2 운영 | 내장 (모니터링, 로깅, 쿼터) | 일부 내장 | NVIDIA 관리 | 직접 구축 |
| 커스터마이징 | 무제한 | 제한적 | 제한적 | 무제한 |
| 초기 구축 난이도 | 중 (Terraform 자동화) | 낮음 | 낮음 | 높음 |
| 월 비용 (16 GPU 상시) | ~$40K | ~$45K | ~$55K | ~$15K (감가 제외) |

---

## 5. Go-to-Market 전략

### 5-1. 단기 (0-3개월): 레퍼런스 확보

```
1. 현재 고객(우리)에서 프로덕션 배포 완료
2. 성과 지표 수집: 학습 속도, GPU utilization, 비용 효율
3. NVIDIA + AWS 공동 블로그/사례 발표 목표
4. AWS re:Invent / GTC 발표 자료 준비
```

### 5-2. 중기 (3-6개월): 파이프라인 구축

```
1. AWS 로보틱스/ML 고객 대상 워크샵 (Isaac Lab on AWS)
2. Terraform 모듈을 AWS Samples로 공개 검토
3. NVIDIA 파트너 채널을 통한 공동 세일즈
4. 산업별 (제조, 물류, 자동차) 맞춤 데모 구성
```

### 5-3. 장기 (6-12개월): 플랫폼화

```
1. 멀티테넌트 SaaS 모드 지원 (시나리오 E)
2. AWS Marketplace 등록 검토
3. 교육 프로그램: "Isaac Lab on AWS Immersion Day"
4. HyperPod 통합 (안정화 후)
```

---

## 6. 핵심 수치 요약 (Quick Reference)

세일즈 대화에서 바로 사용할 수 있는 수치:

| 항목 | 수치 | 출처 |
|------|------|------|
| Baseline GPU 상시 가용 | 16 GPU (g7e.48xlarge x2) | 아키텍처 설계 |
| Burst 최대 GPU | 80 GPU (Spot) + 40 GPU (OD) | Karpenter NodePool limits |
| Spot 절감률 | 60-70% (g7e/g6e 기준) | AWS Spot 가격 히스토리 |
| GPU 프로비저닝 시간 | Baseline: 즉시, Burst: 5-10분 | g7e.48xlarge boot + EFA + device plugin |
| 학습 제출 → 시작 | Baseline: <1분, Burst: 5-10분 | OSMO → KubeRay → Pod → Karpenter |
| PoC 기간 | 2주 | Phase 1+2+5+6+9 배포 |
| 프로덕션 전체 배포 | 4-6주 (10 Phase) | 순차 배포 기준 |
| 월 비용 (Baseline only) | ~$36K | g7e.48xlarge x2 On-Demand |
| 월 비용 (전체 인프라 포함) | ~$65K | GPU + EKS + Storage + Network |
| 연간 GPU 소비 | $430K+ | Baseline 고정 + Burst 변동 |
| Compute SP 절감 (1yr) | 15-25% | 3개월 사용 데이터 기반 적용 |
| AWS 서비스 수 | 15+ | EKS, EC2, FSx, RDS, S3, ECR, DX 등 |
| VPC Endpoint 수 | 18 | S3 GW + 17 Interface |
