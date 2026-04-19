# Phase 1: Foundation

네트워크 기반 — [VPC](https://docs.aws.amazon.com/vpc/latest/userguide/), 서브넷, [Direct Connect](https://docs.aws.amazon.com/directconnect/latest/UserGuide/), [VPC Endpoints](https://docs.aws.amazon.com/vpc/latest/privatelink/), [Security Groups](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html), Route53, TLS

## Goal

모든 리소스가 올라갈 네트워크 기반을 구축한다. Private Subnet만 사용하며, On-Prem과 [Direct Connect](https://docs.aws.amazon.com/directconnect/latest/UserGuide/)로 연결한다.

## Prerequisites

- AWS 계정 및 IAM 권한
- On-Prem 네트워크 팀과 CIDR 대역 협의 완료
- Direct Connect 물리 회선 프로비저닝 (신규 시 수주 소요)

## Design Decisions

| 결정 | 선택 | 이유 |
|------|------|------|
| AZ 전략 | Single AZ | EFA는 동일 AZ에서만 동작하고, FSx for Lustre는 단일 AZ 리소스이며, 크로스 AZ 레이턴시가 NCCL 성능을 저하시킨다 |
| 외부 통신 | NAT Gateway 없이 DX 경유 | NAT GW 비용($100+/월) 절감. 외부 트래픽(pip install 등)은 DX → On-Prem Proxy로 충분하다 |
| 서브넷 구성 | Private Subnet Only | GPU 학습은 내부 워크로드이며 퍼블릭 노출이 불필요하다. 모든 AWS 서비스 접근은 VPC Endpoints로 처리한다 |
| VPC Endpoints | Interface 18개 + Gateway 1개 | NAT Gateway 없이 Private Subnet에서 AWS 서비스에 접근하려면 서비스별 VPC Endpoint가 필수이다 |
| CIDR | /21 (2,048 IPs) | 현재 사용량 ~335 IPs 대비 6배 여유. 서브넷 4개 할당 후에도 확장 공간이 남는다 |
| DNS | Route53 PHZ + Resolver Inbound | On-Prem에서 *.internal 도메인을 해석하려면 Resolver Inbound Endpoint가 필요하다. Conditional Forwarder로 연동한다 |

---

## Service Flow

### 네트워크 토폴로지

```
On-Premises (10.200.0.0/21)
  ├── AD Server (LDAP)
  ├── RTX Pro 6000 x15
  ├── DNS Server (Conditional Forwarder → Route53)
  └── 개발자 브라우저
        │
        │  Direct Connect
        ▼
┌─ AWS VPC (10.100.0.0/21, Single AZ) ───────────────────────────────┐
│                                                                    │
│   VGW (Virtual Private Gateway)                                    │
│     │                                                              │
│     ▼                                                              │
│   Private Route Table                                              │
│     ├── 10.100.0.0/21  → local                                     │
│     ├── 10.200.0.0/21  → VGW (On-Prem via DX)                      │
│     ├── 0.0.0.0/0      → VGW (DX → On-Prem → Internet)             │
│     └── S3 prefix list  → S3 Gateway Endpoint                      │
│                                                                    │
│   ┌──────────────────┐  ┌──────────────────┐  ┌────────────────┐   │
│   │ GPU Compute      │  │ Management       │  │ Infrastructure │   │
│   │ 10.100.0.0/24    │  │ 10.100.1.0/24    │  │ 10.100.2.0/24  │   │
│   │                  │  │                  │  │                │   │
│   │ g7e.48xlarge x10 │  │ Keycloak, MLflow │  │ Internal ALB   │   │
│   │ EFA, NCCL        │  │ JupyterHub, Ray  │  │ RDS PostgreSQL │   │
│   │ FSx mount        │  │ OSMO, Grafana    │  │ FSx for Lustre │   │
│   │                  │  │ ClickHouse       │  │ VPC Endpoints  │   │
│   └──────────────────┘  └──────────────────┘  └────────────────┘   │
│                                                                    │
│   ┌──────────────────┐                                             │
│   │ Reserved         │  Route53 Private Hosted Zone                │
│   │ 10.100.3.0/24    │    *.internal → Internal ALB                │
│   └──────────────────┘                                             │
└────────────────────────────────────────────────────────────────────┘
```

### 트래픽 흐름

```
1. 개발자 → 서비스 접근
   On-Prem Browser
     → DX → VGW → Internal ALB (SG-ALB: 443)
       → Service Pod (SG-Mgmt-Node: 80/443)

2. EKS → AWS 서비스
   Pod (GPU/Management)
     → VPC Endpoint (SG-VPC-Endpoint: 443)
       → ECR, STS, CloudWatch, SSM ...

3. EKS → S3
   Pod
     → S3 Gateway Endpoint (Route Table 경유, 비용 없음)
       → 체크포인트, 모델, 로그 아카이브

4. Pod → 외부 인터넷 (pip install 등)
   Pod
     → VPC → DX → On-Prem Proxy → Internet

5. On-Prem DNS → Route53
   On-Prem DNS Server
     → Conditional Forwarder (*.internal)
       → Route53 Resolver Inbound Endpoint
         → Private Hosted Zone → ALB IP 반환
```

### Security Group 관계

```
                   On-Prem (10.200.0.0/21)
                        │ :443
                        ▼
                   ┌──────────┐
                   │  SG-ALB  │
                   └────┬─────┘
                        │ :80, :443
                        ▼
                 ┌──────────────┐
          ┌───── │ SG-Mgmt-Node │ ─────┐
          │      └──────┬───────┘      │
          │             │              │
   :8265, :6379   all traffic    :5432, :6379
          │             │              │
          ▼             ▼              ▼
   ┌──────────────┐             ┌───────────┐
   │ SG-GPU-Node  │             │ SG-Storage│
   │ (self: all)  │── :988 ──▶  │ FSx, RDS  │
   └──────┬───────┘             └───────────┘
          │
          │ :443
          ▼
   ┌────────────────┐
   │ SG-VPC-Endpoint│
   │ (10.100.0.0/21)│
   └────────────────┘
```

---

## Steps

### 1-1. VPC 생성

```
VPC CIDR: 10.100.0.0/21 (2,048 IPs)
DNS hostnames: enabled
DNS resolution: enabled
```

/21로 설정한 이유:
- 실제 사용 IP ~335개 (GPU 10대 + 관리 노드 5대 + 인프라)
- 2,048 IPs로 현재 규모 대비 6배 여유
- 서브넷 4개 할당 후 /22(1,022 IPs) 확장 공간 잔여

### 1-2. 서브넷 생성

모든 서브넷은 **동일 AZ**에 생성한다 (예: us-east-1a). g7e.48xlarge 인스턴스 가용 AZ를 사전 확인할 것.

| 서브넷 | CIDR | IPs | 용도 |
|--------|------|-----|------|
| GPU Compute | 10.100.0.0/24 | 254 | g7e.48xlarge 노드 + Pod |
| Management | 10.100.1.0/24 | 254 | CPU 관리 노드 + Pod |
| Infrastructure | 10.100.2.0/24 | 254 | ALB, RDS, FSx, VPC Endpoints |
| Reserved | 10.100.3.0/24 | 254 | 확장용 |

### 1-3. Route Table 생성

```
Private Route Table:
  10.100.0.0/21  → local
  10.200.0.0/21  → vgw-xxx          (On-Prem via Direct Connect)
  0.0.0.0/0      → vgw-xxx          (기본 경로: DX → On-Prem → Internet)
  S3 prefix list → vpce-s3          (S3 Gateway Endpoint)
```

NAT Gateway는 사용하지 않는다. 외부 인터넷 트래픽(pip install 등)은 DX → On-Prem Proxy를 경유한다. 4개 서브넷 모두 이 Route Table에 연결한다.

### 1-4. [S3 Gateway Endpoint](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-s3.html)

```
Service: com.amazonaws.{region}.s3
Type: Gateway
Route Table: Private Route Table에 자동 추가
```

### 1-5. Interface VPC Endpoints (18개)

Infrastructure Subnet에 생성한다. 모든 Interface Endpoint의 Private DNS를 활성화한다.

#### EKS 운영

| Endpoint | 용도 |
|----------|------|
| com.amazonaws.{region}.eks | EKS API server |
| com.amazonaws.{region}.eks-auth | EKS Pod Identity |
| com.amazonaws.{region}.ecr.api | ECR API |
| com.amazonaws.{region}.ecr.dkr | ECR Docker registry |
| com.amazonaws.{region}.sts | IAM 역할 assume (IRSA) |
| com.amazonaws.{region}.ec2 | ENI 관리 |
| com.amazonaws.{region}.elasticloadbalancing | ALB 컨트롤러 |

#### 로깅/모니터링

| Endpoint | 용도 |
|----------|------|
| com.amazonaws.{region}.logs | CloudWatch Logs |
| com.amazonaws.{region}.monitoring | CloudWatch Metrics |

#### 학습 파이프라인

| Endpoint | 용도 |
|----------|------|
| com.amazonaws.{region}.autoscaling | 노드 오토스케일링 |
| com.amazonaws.{region}.sqs | Karpenter 인터럽션 큐 |
| com.amazonaws.{region}.ssm | SSM Parameter Store |
| com.amazonaws.{region}.ssmmessages | SSM Session Manager |
| com.amazonaws.{region}.ec2messages | SSM 에이전트 |
| com.amazonaws.{region}.fsx | FSx for Lustre |

#### 보안

| Endpoint | 용도 |
|----------|------|
| com.amazonaws.{region}.kms | 암호화 키 관리 |
| com.amazonaws.{region}.secretsmanager | 시크릿 관리 |

### 1-6. [Security Groups](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html) (5개)

```
SG-GPU-Node
  Inbound:  SG-GPU-Node (all traffic)    노드간 NCCL/EFA
            SG-Mgmt-Node:8265,6379       Ray Head → Worker
            SG-Storage:988               FSx Lustre
  Outbound: SG-VPC-Endpoint:443
            SG-Storage:988

SG-Mgmt-Node
  Inbound:  SG-ALB:80,443               ALB → 서비스
            SG-GPU-Node (all traffic)    Ray Worker → Head
  Outbound: SG-VPC-Endpoint:443
            SG-Storage:5432,6379

SG-ALB
  Inbound:  10.200.0.0/21:443           On-Prem CIDR
  Outbound: SG-Mgmt-Node:80,443

SG-VPC-Endpoint
  Inbound:  10.100.0.0/21:443           VPC 내부 전체

SG-Storage
  Inbound:  SG-GPU-Node:988             FSx Lustre
            SG-Mgmt-Node:5432           RDS PostgreSQL
            SG-Mgmt-Node:6379           Redis (선택)
```

### 1-7. Direct Connect + [Virtual Private Gateway](https://docs.aws.amazon.com/vpn/latest/s2svpn/how_it_works.html#VPNGateway)

```
1. Virtual Private Gateway(VGW) 생성 → VPC에 attach
2. Direct Connect Gateway 생성
3. DX Connection과 DX Gateway 연결
4. VGW와 DX Gateway 연결 (allowed prefixes: 10.100.0.0/21)
5. On-Prem 라우터에서 10.100.0.0/21 → DX 경로 설정
```

On-Prem CIDR(예: 10.200.0.0/21)이 VPC CIDR과 겹치지 않는지 확인한다.

### 1-8. [Route53 Private Hosted Zone](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zones-private.html)

```
Hosted Zone: internal (예: platform.internal)
VPC 연결: 현재 VPC

Records (이후 Phase에서 추가):
  keycloak.internal → Internal ALB
  jupyter.internal  → Internal ALB
  grafana.internal  → Internal ALB
  mlflow.internal   → Internal ALB
  ray.internal      → Internal ALB
  osmo.internal     → Internal ALB
```

### 1-9. [Route53 Resolver](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resolver.html) Inbound Endpoint

On-Prem DNS 서버가 *.internal 쿼리를 Route53으로 전달하기 위해 필요하다.

```
1. Resolver Inbound Endpoint 생성 (Infrastructure Subnet, IP 2개 HA)
2. On-Prem DNS에 conditional forwarder 설정
   *.internal → Resolver Inbound Endpoint IP
```

이 설정이 없으면 On-Prem에서 jupyter.internal 등을 해석할 수 없다.

### 1-10. TLS 인증서

```
Option A: ACM Private CA
  - *.internal 와일드카드 인증서 발급
  - On-Prem 클라이언트에 CA 인증서 배포 필요

Option B: 기존 엔터프라이즈 CA
  - On-Prem CA에서 *.internal 인증서 발급 → ACM에 import
```

[ACM (AWS Certificate Manager)](https://docs.aws.amazon.com/acm/latest/userguide/)을 활용하여 인증서를 관리하며, Private CA 또는 기존 엔터프라이즈 CA 중 선택한다.

---

## References

### Networking

- [Amazon VPC User Guide](https://docs.aws.amazon.com/vpc/latest/userguide/)
- [AWS Direct Connect User Guide](https://docs.aws.amazon.com/directconnect/latest/UserGuide/)
- [Virtual Private Gateway](https://docs.aws.amazon.com/vpn/latest/s2svpn/how_it_works.html#VPNGateway)

### VPC Endpoints

- [AWS PrivateLink (VPC Endpoints)](https://docs.aws.amazon.com/vpc/latest/privatelink/)
- [S3 Gateway Endpoint](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-s3.html)

### DNS

- [Route53 Private Hosted Zones](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zones-private.html)
- [Route53 Resolver](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resolver.html)

### Security

- [Security Groups](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html)
- [AWS Certificate Manager (ACM)](https://docs.aws.amazon.com/acm/latest/userguide/)

## Validation Checklist

- [ ] VPC, 4개 서브넷 생성 확인
- [ ] Route Table 경로 확인 (local, DX, S3)
- [ ] S3 Gateway Endpoint 동작
- [ ] Interface VPC Endpoints (18개) 생성 및 DNS 확인
- [ ] Security Groups (5개) 생성
- [ ] DX로 On-Prem ↔ VPC 통신 확인
- [ ] On-Prem에서 *.internal DNS 해석 확인
- [ ] TLS 인증서 준비 완료

## Next

→ [Phase 2: Platform](002-phase2-platform.md)
