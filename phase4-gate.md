# Phase 4: Gate

인증/인가 — [Keycloak](https://www.keycloak.org/documentation), AD Federation, OIDC Clients, 역할/권한, GPU 쿼터

## Goal

모든 서비스의 인증/인가를 Keycloak으로 통합한다. AD 연동, [OIDC](https://www.keycloak.org/docs/latest/securing_apps/) 클라이언트, 역할 기반 접근 제어를 설정한다.

## Prerequisites

- Phase 2 완료 (EKS, RDS, ALB Controller)
- RDS PostgreSQL 접근 가능 (keycloak_db)
- On-Prem AD 서버 정보 (LDAP URL, Bind DN, Base DN)
- TLS 인증서 준비 (Phase 1-10)

## Design Decisions

| 결정 | 선택 | 이유 |
|------|------|------|
| 인증 서버 | Keycloak (Cognito 대신) | AD LDAP Federation이 필요하고, 멀티 프로토콜(OIDC/SAML) 지원과 세밀한 커스터마이징이 가능하다 |
| ID 소스 | AD LDAP Federation | 기존 사내 계정을 그대로 사용한다. 별도 가입 절차 없이 AD 그룹으로 역할을 자동 매핑한다 |
| GPU 쿼터 | JWT claim에 gpu_quota 포함 | OSMO가 인증 서버에 콜백 없이 토큰만으로 쿼터를 검증할 수 있다. 분산 환경에서 효율적이다 |
| 서비스 인증 | 서비스별 OIDC 클라이언트 | 서비스마다 독립적인 클라이언트 시크릿과 리다이렉트 URI를 관리하여 보안을 격리한다 |

---

## Service Flow

### 인증 아키텍처

```
On-Prem AD Server (LDAP)
  │
  │ LDAPS (:636)
  │ DX 경유
  │
  ▼
┌──────────────────────────────────────────────────────────┐
│ Keycloak (Management Subnet, 2 replicas)                 │
│                                                          │
│  Realm: isaac-lab-production                             │
│                                                          │
│  ┌──────────────────┐    ┌────────────────────────────┐  │
│  │ LDAP Federation  │    │ OIDC Client Registry       │  │
│  │                  │    │                            │  │
│  │ Full Sync: 24h   │    │ ├── jupyterhub  (AuthCode) │  │
│  │ Changed: 15min   │    │ ├── grafana     (AuthCode) │  │
│  │                  │    │ ├── mlflow      (AuthCode) │  │
│  │ Group Mapper:    │    │ ├── ray-dashboard(AuthCode)│  │
│  │ AD Group → Role  │    │ └── osmo-api   (Bearer)    │  │
│  └──────────────────┘    └────────────────────────────┘  │
│                                                          │
│  Backend: RDS PostgreSQL (keycloak_db)                   │
└──────────┬───────────────────────────────────────────────┘
           │
           │ OIDC Tokens (JWT)
           ▼
   ┌──────────────────────────────────────────────────┐
   │         서비스별 인증 흐름                       │
   │                                                  │
   │  Browser 접근 (Authorization Code Flow):         │
   │    User → Service → Keycloak Login → Token       │
   │    → Service (JWT 검증) → 접근 허용              │
   │                                                  │
   │  API 접근 (Bearer Token):                        │
   │    Client → Token 요청 → Keycloak → JWT          │
   │    → OSMO API (JWT 검증 + gpu_quota) → 실행      │
   └──────────────────────────────────────────────────┘
```

### 사용자 → 서비스 접근 흐름 (상세)

```
1. 연구자가 jupyter.internal 접근
   │
   ▼
2. JupyterHub → Keycloak 로그인 리다이렉트
   │
   ▼
3. Keycloak 로그인 페이지 (AD 계정)
   │
   ▼
4. AD LDAP 인증
   │
   ▼
5. JWT 발급 (claims: username, roles, gpu_quota)
   │
   ▼
6. JupyterHub → JWT 검증 → 노트북 시작
   │
   ▼
7. 노트북에서 OSMO API 호출
   │  Authorization: Bearer <jwt>
   ▼
8. OSMO → JWT 검증 → gpu_quota 확인 → 학습 제출
```

### 역할 기반 접근 매트릭스

```
                  ┌───────────┬───────────┬───────────┐
                  │researcher │ engineer  │  viewer   │
                  │(ML연구자) │(MLOps)    │(매니저)   │
┌─────────────────┼───────────┼───────────┼───────────┤
│ JupyterHub      │  Login    │  Login    │     -     │
│ OSMO 학습 제출  │  4 GPU    │ 10 GPU    │     -     │
│ Grafana 보기    │    ✓      │    ✓      │    ✓      │
│ Grafana 편집    │    -      │    ✓      │     -     │
│ MLflow 조회     │    ✓      │    ✓      │    ✓      │
│ MLflow 모델관리 │    ✓      │    ✓      │     -     │
│ Ray Dashboard   │    ✓      │    ✓      │     -     │
│ ClickHouse 쿼리 │    ✓      │    ✓      │    ✓      │
└─────────────────┴───────────┴───────────┴───────────┘
```

---

## Steps

### 4-1. Keycloak 배포

```yaml
Namespace: keycloak
Replicas: 2 (HA)
Resources:
  CPU: 1 per replica
  Memory: 1.5Gi per replica
Node Selector: node-type=management

Database:
  Type: PostgreSQL (RDS)
  Database: keycloak_db
  Credentials: External Secrets → Secrets Manager

Ingress:
  Host: keycloak.internal
  Class: alb
  Scheme: internal
  TLS: *.internal 인증서
```

Helm Chart: Bitnami Keycloak 또는 Quarkus 공식 이미지 사용. DB 자격증명은 [External Secrets Operator](https://external-secrets.io/)를 통해 Secrets Manager에서 가져온다.

### 4-2. Realm 생성

```
Realm Name: isaac-lab-production
Login Theme: keycloak (기본)
Token Lifespan:
  Access Token: 5분
  Refresh Token: 30분
  SSO Session: 8시간
```

### 4-3. AD [LDAP Federation](https://www.keycloak.org/docs/latest/server_admin/#_ldap)

```
Provider: ldap
Connection URL: ldaps://ad.corp.internal:636
Bind DN: CN=svc-keycloak,OU=Service Accounts,DC=corp,DC=internal
Bind Credential: Secrets Manager에서 가져옴
User DN: OU=Users,DC=corp,DC=internal
Username LDAP Attribute: sAMAccountName
Sync:
  Full Sync Period: 86400 (24시간)
  Changed Users Sync Period: 900 (15분)
```

LDAPS(636)를 사용한다. On-Prem AD 서버로의 트래픽은 DX를 경유한다.

### 4-4. 역할 (Role) 및 그룹 매핑

| Keycloak Role | AD 그룹 | 설명 |
|---------------|---------|------|
| researcher | CN=ML-Researchers,OU=Groups | 학습 제출, 결과 조회, 노트북 사용 |
| engineer | CN=MLOps-Engineers,OU=Groups | + 인프라 설정, 클러스터 관리 |
| viewer | CN=ML-Managers,OU=Groups | 읽기 전용 (Grafana, MLflow) |

Group Mapper를 설정하여 AD 그룹 → Keycloak Role 자동 매핑.

### 4-5. OIDC 클라이언트 등록

이후 Phase에서 각 서비스를 배포할 때 실제 연동한다. 여기서는 클라이언트를 미리 생성한다.

| Client ID | Flow | Redirect URI | 용도 |
|-----------|------|-------------|------|
| jupyterhub | Authorization Code | https://jupyter.internal/hub/oauth_callback | Phase 9 |
| grafana | Authorization Code | https://grafana.internal/login/generic_oauth | Phase 8 |
| mlflow | Authorization Code | https://mlflow.internal/callback | Phase 6 |
| ray-dashboard | Authorization Code | https://ray.internal/oauth/callback | Phase 5 |
| osmo-api | Bearer-only | - | Phase 5 |

모든 클라이언트:
- Access Type: confidential
- Client Secret: Secrets Manager에 저장
- Mappers: roles → token claim

### 4-6. GPU 쿼터 설정

```
Keycloak Role Attribute:
  researcher: gpu_quota=4
  engineer: gpu_quota=10

OSMO에서 JWT 토큰의 gpu_quota claim을 검증하여 GPU 할당 제한.
```

### 4-7. Ingress 설정

[AWS ALB Ingress Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)를 통해 Keycloak을 내부 ALB로 노출한다.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keycloak
  namespace: keycloak
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internal
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: {acm-cert-arn}
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
spec:
  rules:
    - host: keycloak.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: keycloak
                port:
                  number: 8080
```

TLS 인증서는 [ACM](https://docs.aws.amazon.com/acm/latest/userguide/)에서 관리한다.

### 4-8. [Route53](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/) 레코드

```
keycloak.internal → Internal ALB (Alias)
```

---

## References

- [Keycloak Documentation](https://www.keycloak.org/documentation)
- [Keycloak LDAP Federation](https://www.keycloak.org/docs/latest/server_admin/#_ldap)
- [Keycloak OIDC / Securing Applications](https://www.keycloak.org/docs/latest/securing_apps/)
- [External Secrets Operator](https://external-secrets.io/)
- [AWS ALB Ingress Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
- [Route53 Developer Guide](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/)
- [AWS Certificate Manager (ACM)](https://docs.aws.amazon.com/acm/latest/userguide/)

## Validation Checklist

- [ ] Keycloak 2 replica 정상 Running
- [ ] https://keycloak.internal 접근 확인 (On-Prem 브라우저)
- [ ] AD LDAP 동기화 성공 (유저 목록 확인)
- [ ] 역할 매핑 확인 (AD 그룹 → Keycloak Role)
- [ ] OIDC 클라이언트 5개 생성 확인
- [ ] 테스트 유저로 로그인 → 토큰에 roles, gpu_quota claim 포함 확인
- [ ] Token 발급/갱신 동작 확인

## Next

→ [Phase 5: Orchestrator](phase5-orchestrator.md)
