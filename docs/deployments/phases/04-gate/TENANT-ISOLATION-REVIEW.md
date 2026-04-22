# Phase 04 — Tenant Isolation Review

Phase 04(Gate)에서 설정하는 Keycloak 인증 체계가 downstream 시스템 전체의 접근 제어 기반이 됩니다. 현재 구현의 격리 수준을 검토하고, Team 기준 격리를 도입하기 위한 변경 사항을 정리합니다.

---

## 1. 현재 상태 — 격리 수준 진단

### 사용자 Identity Chain

```
Keycloak JWT            OSMO Controller         RayJob Pod            ClickHouse / MLflow / FSx
┌──────────────┐       ┌──────────────┐        ┌──────────────┐      ┌──────────────────┐
│ username     │       │ gpu_quota    │        │ WORKFLOW_ID  │      │ workflow_id      │
│ gpu_quota    │──────►│ 검증 후 통과  │───────►│              │─────►│                  │
│ realm_roles  │       │              │        │ (owner 없음) │      │ (user/team 없음) │
└──────────────┘       └──────────────┘        └──────────────┘      └──────────────────┘
                                                    ▲
                                              여기서 identity 끊김
```

Keycloak JWT에는 사용자 정보가 있지만, OSMO가 RayJob을 생성할 때 해당 정보를 label이나 환경변수로 전달하지 않습니다. 이 시점부터 모든 downstream 시스템에서 "누가(어떤 팀이) 만든 작업인지" 알 수 없습니다.

### 레이어별 격리 현황

| 레이어 | 리소스 | 현재 격리 | 문제 |
|--------|--------|----------|------|
| Keycloak (인증) | JWT claims | 사용자 식별 가능 | 문제 없음 |
| OSMO (작업 제출) | GPU quota | 역할별 quota 제한만 | owner/team 정보 미전달 |
| RayJob (학습) | Pod, namespace | training namespace 단일 공유 | 모든 사용자의 Job이 혼재 |
| FSx Lustre (체크포인트) | /mnt/fsx | ReadWriteMany 전체 공유 | 모든 Pod이 전체 FS 접근 |
| ClickHouse (메트릭) | 3개 테이블 | 없음 | user/team 컬럼 부재 |
| MLflow (실험) | experiments, runs | OAuth2 로그인만 | 모든 experiment/run 전체 공개 |
| Grafana (대시보드) | workflow_id 드롭다운 | 없음 | 모든 사용자의 workflow 노출 |
| JupyterHub (노트북) | 노트북 서버 | 사용자별 Pod 분리 | FSx read-only 전체 공유 |
| S3 (artifacts) | 버킷 | IRSA 버킷 전체 접근 | prefix 수준 격리 없음 |

### 격리가 이미 되어 있는 부분

- **GPU 할당량**: Keycloak role → gpu_quota claim → OSMO quota enforcement
- **JupyterHub 노트북 서버**: singleuser spawner로 사용자별 Pod 격리
- **네트워크**: NetworkPolicy가 namespace 단위 통신 제어

---

## 2. 격리 기준 비교 — User vs Team

### 비교 결과

| 관점 | User 기준 | Team 기준 |
|------|----------|----------|
| 구현 복잡도 | 낮음 (JWT에 username 이미 있음) | 중간 (AD 그룹 + Keycloak mapper 추가) |
| 체크포인트 resume/공유 | 불가 (본인만 접근) | 팀 내 자유 공유 |
| 실험 비교 (MLflow) | 본인 run만 비교 | 팀 전체 best run 비교 가능 |
| 하이퍼파라미터 탐색 | 개인 단위 | 팀 단위 분업 가능 |
| Grafana 대시보드 | Org 모델과 불일치 | Org = Team으로 자연스러운 매핑 |
| S3 IAM 격리 | 사용자별 조건 → IRSA와 불일치 | 팀별 IRSA 가능 |
| 인원 변동 | 깔끔 (개인 데이터 불변) | 팀 이동 시 과거 데이터 소속 처리 필요 |
| 감사/추적 | 완벽 (개인 특정) | 팀까지만 (개인 특정 불가) |
| RL 학습 워크플로우 적합성 | 낮음 | 높음 |

### 핵심 판단 근거

RL 학습에서 팀 단위 공유가 필수인 이유:

1. **체크포인트 resume**: 사용자 A가 500 iteration까지 학습 → 사용자 B가 이어서 1000 iteration. User 격리면 불가능
2. **실험 비교**: 팀 내에서 "누구의 하이퍼파라미터가 가장 좋았는지" 비교하는 것이 일상적 워크플로우
3. **모델 레지스트리**: 팀이 등록한 best model을 팀원 모두가 참조해야 함

---

## 3. 권장 방안 — Team 격리 + User 태깅

```
격리 경계 (hard boundary)  = Team
감사 추적 (soft tagging)   = User
```

### 3.1 Keycloak 변경 (Phase 04 직접 영향)

**AD 그룹 추가 (On-Prem AD 관리자 작업)**:

```
OU=Teams,DC=corp,DC=internal          ← 새 OU
  ├── CN=team-locomotion               ← 팀 그룹
  │   ├── member: jjung
  │   ├── member: kkim
  │   └── member: hhan
  ├── CN=team-manipulation
  │   └── member: slee
  └── CN=team-platform
      └── member: ppark
```

**Keycloak LDAP Group Mapper 추가**:

```json
{
  "name": "team-group-mapper",
  "providerId": "group-ldap-mapper",
  "providerType": "org.keycloak.storage.ldap.mappers.LDAPStorageMapper",
  "config": {
    "groups.dn": ["OU=Teams,DC=corp,DC=internal"],
    "group.name.ldap.attribute": ["cn"],
    "group.object.classes": ["group"],
    "membership.ldap.attribute": ["member"],
    "membership.attribute.type": ["DN"],
    "mode": ["LDAP_ONLY"],
    "drop.non.existing.groups.during.sync": ["false"]
  }
}
```

**OIDC Client Protocol Mapper 추가 (5개 클라이언트 전체)**:

```json
{
  "name": "team-mapper",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-group-membership-mapper",
  "config": {
    "claim.name": "team",
    "full.path": "false",
    "id.token.claim": "true",
    "access.token.claim": "true",
    "userinfo.token.claim": "true"
  }
}
```

**변경 후 JWT 구조**:

```json
{
  "preferred_username": "jjung",
  "realm_roles": ["researcher"],
  "gpu_quota": 16,
  "team": ["team-locomotion"]
}
```

### 3.2 role-mappings.json 확장

현재:
```json
{
  "roles": [
    { "name": "researcher", "gpu_quota": "16", "ad_group": "CN=ML-Researchers,..." },
    { "name": "engineer",   "gpu_quota": "32", "ad_group": "CN=MLOps-Engineers,..." },
    { "name": "admin",      "gpu_quota": "80", "ad_group": "CN=ML-Admins,..." },
    { "name": "viewer",     "gpu_quota": "0",  "ad_group": "CN=ML-Managers,..." }
  ]
}
```

역할(role)과 팀(team)은 직교하는 개념:
- **역할**: 무엇을 할 수 있는가 (GPU 몇 장, 읽기/쓰기)
- **팀**: 어떤 데이터에 접근하는가 (체크포인트, 실험, 대시보드)

따라서 role-mappings.json은 변경 없이, 별도의 team 매핑 설정을 추가하는 것이 적절합니다.

### 3.3 configure-realm.sh 변경 범위

```bash
# 추가할 단계 (Step 4.5):
# - LDAP Group Mapper for Teams (OU=Teams)
# - OIDC group-membership-mapper (team claim) for all 5 clients
```

### 3.4 다중 팀 소속 처리

한 사용자가 여러 팀에 속할 경우:

- JWT의 `team` claim은 배열로 전달: `["team-locomotion", "team-platform"]`
- OSMO Controller에서 **primary team** 결정 정책 필요:
  - 옵션 A: 작업 제출 시 사용자가 명시적으로 선택
  - 옵션 B: 첫 번째 그룹을 기본값으로 사용
  - 옵션 C: 별도 user attribute로 primary_team 지정 (Keycloak admin에서 설정)

---

## 4. Downstream 영향 — Phase별 변경 사항

### Phase 05 — Orchestrator (OSMO Controller)

OSMO가 RayJob 생성 시 JWT에서 추출한 team/owner를 주입:

```yaml
# OSMO가 생성하는 RayJob에 추가할 내용
metadata:
  labels:
    isaac-lab/team: "locomotion"     # ← 격리 기준
    isaac-lab/owner: "jjung"         # ← 감사 추적
spec:
  rayClusterSpec:
    headGroupSpec:
      template:
        spec:
          containers:
            - env:
                - name: OWNER_TEAM
                  value: "locomotion"
                - name: OWNER_USERNAME
                  value: "jjung"
```

osmo-configmaps.yaml 변경:

```yaml
# osmo-oidc-config에 추가
claims:
  team_claim: "team"            # ← 새로 추가
  username_claim: "preferred_username"
  gpu_quota_claim: "gpu_quota"
```

### Phase 07 — Recorder (ClickHouse DDL)

3개 테이블에 team/owner 컬럼 추가:

```sql
-- 001-training-metrics.sql
CREATE TABLE training_metrics (
    ...
    team        String,          -- 격리 필터
    owner       String,          -- 감사 추적
    ...
) ORDER BY (team, workflow_id, trial_id, iteration)  -- team을 첫 정렬 키로
```

```sql
-- 002-training-raw-logs.sql
CREATE TABLE training_raw_logs (
    ...
    team        String,
    owner       String,
    ...
)
```

```sql
-- 003-training-summary.sql
CREATE TABLE training_summary (
    ...
    team        String,
    owner       String,
    ...
)
```

### Phase 10 — Factory Floor (train.py, hpo.py, clickhouse_logger.py)

```python
# clickhouse_logger.py — 환경변수에서 team/owner 읽기
self.team = os.environ.get("OWNER_TEAM", "unknown")
self.owner = os.environ.get("OWNER_USERNAME", "unknown")

# INSERT 시 team, owner 컬럼 포함
```

### Phase 06 — Registry (MLflow)

실험을 팀별로 분리:

```python
# train.py
team = os.environ.get("OWNER_TEAM", "default")
owner = os.environ.get("OWNER_USERNAME", "unknown")

mlflow.set_experiment(f"isaac-lab/{team}/{task}")   # 팀별 experiment
mlflow.set_tag("mlflow.user", owner)                # 개인 태깅
```

### Phase 08 — Control Room (Grafana)

팀별 Grafana Org 또는 Folder 분리:

```
Grafana
├── Org: locomotion
│   └── Dashboard: Training → $team='locomotion' (고정)
├── Org: manipulation
│   └── Dashboard: Training → $team='manipulation' (고정)
└── Org: admin (운영자)
    └── Dashboard: Training → $team=* (전체)
```

대시보드 쿼리 변경:

```sql
-- 현재
SELECT * FROM training_metrics WHERE workflow_id = '$workflow_id'

-- 변경 후
SELECT * FROM training_metrics
WHERE team = '$team' AND workflow_id = '$workflow_id'
```

### Phase 04 — Gate (FSx 접근)

FSx 디렉토리 구조:

```
/mnt/fsx/
  └── teams/
      ├── locomotion/
      │   └── checkpoints/
      │       ├── h1-walk-exp-42/       (owner: jjung)
      │       └── h1-walk-exp-43/       (owner: kkim)
      ├── manipulation/
      │   └── checkpoints/
      └── platform/
          └── checkpoints/
```

train.py 변경:

```python
team = os.environ.get("OWNER_TEAM", "default")
checkpoint_dir = f"/mnt/fsx/teams/{team}/checkpoints/{workflow_id}/{trial_id}/"
```

JupyterHub FSx 마운트 변경:

```yaml
# subPath를 팀 디렉토리로 제한
extraVolumeMounts:
  - name: fsx-shared
    mountPath: /mnt/fsx
    subPath: "teams/{{ user.team }}"   # 팀 디렉토리만 마운트
    readOnly: true
```

### Phase 02 — Platform (S3 격리)

S3 경로에 team prefix 적용:

```
s3://isaac-lab-prod-checkpoints/teams/locomotion/...
s3://isaac-lab-prod-models/teams/locomotion/...
```

팀별 IRSA 정책으로 prefix 제한 (또는 OSMO가 presigned URL 발급).

---

## 5. 구현 우선순위

변경의 영향도와 난이도를 기준으로 정렬:

| 순서 | 변경 | 영향 Phase | 난이도 | 효과 |
|------|------|-----------|--------|------|
| 1 | Keycloak: team claim 추가 | **04** | 중 | 전체 격리의 기반 |
| 2 | OSMO: team/owner를 RayJob에 주입 | 05 | 중 | identity chain 복원 |
| 3 | ClickHouse DDL: team/owner 컬럼 | 07 | 낮 | 쿼리 수준 격리 |
| 4 | train.py/hpo.py: team/owner 로깅 | 10 | 낮 | 메트릭 격리 |
| 5 | MLflow: 팀별 experiment | 06 | 낮 | 실험 격리 |
| 6 | Grafana: Org/Folder 분리 + 쿼리 필터 | 08 | 중 | 대시보드 격리 |
| 7 | FSx: 팀별 디렉토리 + subPath | 02, 09 | 중 | 체크포인트 격리 |
| 8 | S3: 팀별 prefix + IAM 정책 | 02 | 높 | artifact 격리 |

**핵심 경로: 1 → 2 → 3/4/5 (병렬) → 6/7 (병렬) → 8**

Phase 04의 Keycloak team claim 추가가 가장 먼저 되어야 나머지가 진행 가능합니다.

---

## 6. 운영자 접근

| 역할 | 접근 범위 | 구현 |
|------|----------|------|
| admin (운영자) | 모든 팀의 데이터 | Keycloak admin role → Grafana admin Org, ClickHouse 무필터, FSx 전체 |
| engineer (팀 소속) | 소속 팀 데이터 + GPU 10장 | team claim 기반 필터링 |
| researcher (팀 소속) | 소속 팀 데이터 + GPU 4장 | team claim 기반 필터링 |
| viewer | 소속 팀 데이터 읽기 전용 + GPU 0장 | team claim + read-only FSx mount |

---

## 7. AD 팀 그룹이 없는 경우의 대안

On-Prem AD에 팀 그룹(OU=Teams)을 추가할 수 없는 경우:

**대안 A**: Keycloak User Attribute로 team 지정
- Keycloak admin console에서 사용자별로 `team` attribute를 수동 설정
- User Attribute Mapper로 JWT에 포함
- 단점: AD와 동기화되지 않아 수동 관리 필요

**대안 B**: 기존 AD 그룹을 팀으로 재활용
- 이미 존재하는 부서/프로젝트 그룹을 team claim으로 매핑
- Group Mapper의 `groups.dn`을 기존 OU로 지정

**대안 C**: Keycloak Static Group
- Keycloak 내에서 그룹을 직접 생성하고 사용자를 할당
- AD 연동과 독립적으로 운영
- 단점: AD의 single source of truth 원칙과 충돌
