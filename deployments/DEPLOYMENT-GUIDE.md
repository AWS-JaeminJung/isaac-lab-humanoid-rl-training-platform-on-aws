# Isaac Lab Production Deployment Guide

Deployment guide for the **Isaac Lab Humanoid RL Training Platform on AWS** — a private, GPU-accelerated reinforcement learning infrastructure connected to on-premises compute via AWS Direct Connect.

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Phase-by-Phase Guide](#phase-by-phase-guide)
- [Operations](#operations)
- [Configuration Reference](#configuration-reference)
- [Architecture Notes](#architecture-notes)
- [Troubleshooting](#troubleshooting)

---

## Overview

The platform is deployed in 10 sequential phases, each building on the outputs of previous phases.

| Phase | Name | What It Does | ~Time |
|-------|------|-------------|-------|
| 01 | Foundation | VPC, Subnets, Direct Connect, Security Groups, Route53, ACM | 15 min |
| 02 | Platform | EKS Cluster, Karpenter, RDS, S3 (4), FSx, ECR, IRSA (8) | 25 min |
| 03 | Bridge | On-Prem GPU registration as EKS Hybrid Nodes via SSM | 20 min |
| 04 | Gate | Keycloak, AD LDAP Federation, 5 OIDC Clients, GPU Quota Roles | 20 min |
| 05 | Orchestrator | NVIDIA OSMO Controller, KubeRay Operator, RBAC, NetworkPolicies | 15 min |
| 06 | Registry | MLflow Tracking + Model Registry with OAuth2 Proxy | 10 min |
| 07 | Recorder | ClickHouse (metrics/logs), Fluent Bit DaemonSet, AWS Backup | 10 min |
| 08 | Control Room | Prometheus, Grafana (4 dashboards), DCGM Exporter, Alertmanager | 15 min |
| 09 | Lobby | JupyterHub with Keycloak OIDC, custom notebook image | 15 min |
| 10 | Factory Floor | 4-stage GPU training validation (1 → 8 → 16 GPU → HPO) | 2 hrs |

**Total estimated time: 3.5–4 hours** (Phase 10 GPU training dominates).

### Architecture Diagram

```
On-Prem Network (10.200.0.0/21)             AWS VPC (10.100.0.0/21)
┌─────────────────────────┐                  ┌──────────────────────────────────────────────┐
│                         │                  │                                              │
│  Active Directory       │   Direct         │  EKS Cluster (private-only API)              │
│  (LDAPS:636)       ─────┼── Connect ──────►│  ├── Management Nodes (x86, AL2023)          │
│                         │                  │  │   ├── Keycloak (2 replicas)                │
│  GPU Machines           │                  │  │   ├── OSMO Controller                     │
│  ├── RTX PRO 6000  ────┼── SSM Hybrid ───►│  │   ├── KubeRay Operator                    │
│  ├── RTX PRO 6000       │   Activation     │  │   ├── MLflow + OAuth2 Proxy               │
│  └── ...                │                  │  │   ├── ClickHouse + Fluent Bit              │
│                         │                  │  │   ├── Prometheus + Grafana                 │
│  Researchers            │                  │  │   └── JupyterHub                           │
│  (Browser) ─────────────┼── DX + ALB ────►│  │                                            │
│                         │                  │  └── GPU Nodes (Karpenter, 0→N Spot)          │
│                         │                  │      ├── p4d.24xlarge (8x A100)               │
│                         │                  │      └── p5.48xlarge (8x H100)                │
│                         │                  │                                              │
│                         │                  │  Storage                                     │
│                         │                  │  ├── RDS PostgreSQL (Keycloak + MLflow)       │
│                         │                  │  ├── FSx Lustre (shared training data)        │
│                         │                  │  ├── S3: checkpoints, models, logs, data      │
│                         │                  │  └── ECR: isaac-lab-training                  │
│                         │                  │                                              │
│                         │                  │  Network: No IGW/NAT, 18 VPC Endpoints       │
└─────────────────────────┘                  └──────────────────────────────────────────────┘
```

---

## Prerequisites

### Required Tools

| Tool | Min Version | Check | Auto-Install |
|------|------------|-------|-------------|
| Terraform | 1.9.0 | `terraform --version` | `make prereqs-install` |
| kubectl | 1.31.0 | `kubectl version --client` | `make prereqs-install` |
| Helm | 3.16.0 | `helm version` | `make prereqs-install` |
| AWS CLI | 2.0.0 | `aws --version` | `make prereqs-install` |
| jq | 1.6 | `jq --version` | `make prereqs-install` |
| curl | 7.0 | `curl --version` | (system) |
| Docker | — | `docker info` | (manual) |

```bash
# Check all prerequisites
make prereqs

# Auto-install missing tools (macOS: brew, Debian/Ubuntu: apt)
make prereqs-install
```

### AWS Preparation

**1. Terraform State Backend** (one-time, manual or separate bootstrap):

```bash
# S3 bucket for Terraform state
aws s3 mb s3://isaac-lab-prod-terraform-state --region us-east-1
aws s3api put-bucket-versioning \
  --bucket isaac-lab-prod-terraform-state \
  --versioning-configuration Status=Enabled

# DynamoDB table for state locking
aws dynamodb create-table \
  --table-name isaac-lab-prod-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

**2. Direct Connect**: Physical DX connection must be established and a DX Gateway created before deployment. Note the `DX_GATEWAY_ID`.

**3. AWS Authentication**: Ensure your CLI session has sufficient permissions (AdministratorAccess or equivalent scoped policy).

```bash
# Verify authentication
make check-auth
```

### On-Premises Preparation

- GPU machines running **Ubuntu 22.04+**
- **NVIDIA Driver** installed and verified (`nvidia-smi`)
- Network route to AWS VPC via Direct Connect
- SSH access from deployment workstation (for automated node registration)

### Secrets Configuration

```bash
cp config/secrets.env.example config/secrets.env
```

Edit `config/secrets.env` and fill in all required values. The following are **mandatory**:

| Variable | Phase | Description |
|----------|-------|-------------|
| `AWS_ACCOUNT_ID` | All | AWS account ID |
| `AWS_REGION` | All | Target region (default: us-east-1) |
| `DX_GATEWAY_ID` | 01 | Direct Connect Gateway ID |
| `RDS_MASTER_PASSWORD` | 02 | PostgreSQL master password |
| `KEYCLOAK_DB_PASSWORD` | 04 | Keycloak database password |
| `KEYCLOAK_ADMIN_PASSWORD` | 04 | Keycloak admin console password |
| `LDAP_CONNECTION_URL` | 04 | AD LDAP URL (e.g., `ldaps://ad.corp.internal:636`) |
| `LDAP_BIND_DN` | 04 | LDAP service account DN |
| `LDAP_BIND_PASSWORD` | 04 | LDAP bind password |
| `MLFLOW_DB_PASSWORD` | 06 | MLflow database password |
| `GRAFANA_ADMIN_PASSWORD` | 08 | Grafana admin password |

> **Never commit `secrets.env` to version control.** The `.gitignore` excludes it by default.

---

## Quick Start

For a full deployment from scratch:

```bash
cd deployments/

# 1. Configure secrets
cp config/secrets.env.example config/secrets.env
vi config/secrets.env

# 2. Check prerequisites
make prereqs

# 3. Deploy all 10 phases sequentially
make deploy-all

# 4. Validate everything
make validate-all
```

If any phase fails, `deploy-all` stops immediately. Fix the issue and re-run — all phases are idempotent.

---

## Phase-by-Phase Guide

### Phase 01 — Foundation

**Purpose**: Build the network foundation — VPC, subnets, Direct Connect integration, security groups, DNS, and TLS certificate.

**Resources created**:

| Category | Resources |
|----------|----------|
| Network | VPC (10.100.0.0/21), 4 subnets (GPU, Management, Infrastructure, Reserved) |
| Connectivity | Virtual Private Gateway, DX Gateway association, BGP route propagation |
| VPC Endpoints | S3 Gateway + 17 Interface endpoints (EKS, ECR, STS, SSM, FSx, KMS, etc.) |
| Security | 5 Security Groups (GPU, Management, ALB, VPC Endpoint, Storage) |
| DNS | Route53 Private Hosted Zone, Resolver inbound endpoint |
| TLS | ACM wildcard certificate (*.internal) with DNS validation |

**Required secrets**: `DX_GATEWAY_ID`

```bash
# Plan only (dry-run)
make deploy-phase01          # with --plan-only flag
./phases/01-foundation/deploy.sh --plan-only

# Full deploy
make deploy-phase01

# Validate
make validate-phase01
```

**Key design decision**: Single AZ deployment. All 4 subnets are in the same AZ (us-east-1a) to maximize GPU NCCL bandwidth and avoid cross-AZ latency. FSx Lustre is also single-AZ.

---

### Phase 02 — Platform

**Purpose**: Deploy the EKS cluster with all storage, IAM roles, and auto-scaling infrastructure.

**Resources created**:

| Category | Resources |
|----------|----------|
| Compute | EKS cluster (private API), Management node group (3 nodes) |
| Storage | FSx Lustre, 4 S3 buckets, RDS PostgreSQL 16 |
| Container | ECR repository (isaac-lab-training) |
| IAM | OIDC provider, 8 IRSA roles |
| Auto-scaling | Karpenter (IAM, instance profile, SQS interruption queue, EventBridge rules) |
| Add-ons | VPC CNI, CoreDNS, kube-proxy, EBS CSI |
| Helm Charts | FSx CSI, Karpenter, ALB Controller, External Secrets Operator |
| K8s Resources | gp3 StorageClass, FSx PV/PVC, ClusterSecretStore, Karpenter NodePool |

**Required secrets**: `RDS_MASTER_PASSWORD`

```bash
make deploy-phase02
make validate-phase02
```

**After this phase**: You have a fully functional EKS cluster with storage, but no workloads yet. The kubeconfig is automatically configured.

---

### Phase 03 — Bridge

**Purpose**: Register on-premises GPU machines as EKS Hybrid Nodes so they can run Kubernetes workloads alongside cloud nodes.

**Resources created**:

| Category | Resources |
|----------|----------|
| IAM | HybridNodeRole (SSM, EKS, ECR, S3 access) |
| SSM | Hybrid Activation (20 machine limit, 30-day expiry) |
| EKS | Access Entry (HYBRID_LINUX type) |
| K8s | Node labels, taints, NVIDIA Device Plugin DaemonSet |

```bash
make deploy-phase03
make validate-phase03
```

**Node registration — two modes**:

*Automated (recommended)*: Set the `ON_PREM_HOSTS` environment variable before running:

```bash
export ON_PREM_HOSTS="10.200.0.11,10.200.0.12,10.200.0.13"
make deploy-phase03
```

The script will SSH into each machine, install `nodeadm`, and register it with the cluster.

*Manual*: If `ON_PREM_HOSTS` is not set, the script prints instructions for on-prem admins to run on each machine:

```
1. Download nodeadm
2. Write /etc/nodeadm/nodeadm-config.yaml
3. Run: sudo nodeadm install && sudo nodeadm init
```

**Labels and taints applied**:
- Labels: `node-type=onprem-gpu`, `gpu-model=rtx-pro-6000`
- Taint: `workload-type=onprem-single-gpu:NoSchedule`

---

### Phase 04 — Gate

**Purpose**: Deploy Keycloak for centralized authentication. Federate with on-prem Active Directory. Create OIDC clients for all platform services.

**Resources created**:

| Category | Resources |
|----------|----------|
| Secrets Manager | 7 secrets (DB, LDAP, 5 OIDC clients) |
| ExternalSecrets | 7 K8s secrets synced from Secrets Manager |
| Keycloak | 2-replica deployment via Bitnami Helm |
| Realm | isaac-lab-production |
| LDAP | AD federation (LDAPS:636, full sync 24h, changed sync 15min) |
| Roles | researcher (gpu_quota=4), engineer (gpu_quota=10), viewer (gpu_quota=0) |
| OIDC Clients | jupyterhub, grafana, mlflow, ray-dashboard, osmo-api |
| Networking | ALB Ingress + Route53: keycloak.internal |

**Required secrets**: `KEYCLOAK_ADMIN_PASSWORD`, `KEYCLOAK_DB_PASSWORD`, `LDAP_*` variables

```bash
make deploy-phase04
make validate-phase04
```

**Authentication flow after this phase**:

```
User (browser) → keycloak.internal → AD LDAP lookup → JWT issued
  JWT contains: realm_roles, gpu_quota (int)
```

**OIDC client redirect URIs**:

| Client | Redirect URI |
|--------|-------------|
| jupyterhub | `https://jupyter.internal/hub/oauth_callback` |
| grafana | `https://grafana.internal/login/generic_oauth` |
| mlflow | `https://mlflow.internal/callback` |
| ray-dashboard | `https://ray.internal/oauth/callback` |
| osmo-api | Bearer-only (no redirect) |

---

### Phase 05 — Orchestrator

**Purpose**: Deploy NVIDIA OSMO Controller for workflow orchestration and KubeRay Operator for managing Ray clusters. This is the core execution engine.

**Resources created**:

| Category | Resources |
|----------|----------|
| Namespaces | orchestration, ray-system, training |
| Secrets | OSMO DB + OIDC credentials |
| IRSA | OSMO Controller (S3 read/write) |
| Helm | KubeRay Operator v1.2.0, OSMO Controller v1.2.0 |
| CRDs | RayJob, RayCluster, RayService |
| RBAC | OSMO + KubeRay ServiceAccounts, ClusterRoles |
| Network | 3 NetworkPolicies (API ingress, Ray internal, OSMO→training) |
| Reliability | 3 PDBs, ResourceQuota (80 GPU limit) |
| Networking | ALB + Route53: osmo.internal, ray.internal |

```bash
make deploy-phase05
make validate-phase05
```

**CPU pipeline verification**: After deployment, the script automatically submits a CPU-only RayJob to verify the OSMO → KubeRay → RayJob → RayCluster lifecycle works end-to-end (without consuming GPU resources).

---

### Phase 06 — Registry

**Purpose**: Deploy MLflow for experiment tracking and model versioning, protected by OAuth2 Proxy with Keycloak OIDC.

**Resources created**:

| Category | Resources |
|----------|----------|
| Namespace | mlflow |
| Secrets | MLflow DB + OAuth2 Proxy credentials |
| Deployment | MLflow server (S3 artifact store, RDS backend) |
| Auth | OAuth2 Proxy (Keycloak OIDC) |
| Networking | ALB + Route53: mlflow.internal |
| Defaults | 2 experiments: isaac-lab-default, isaac-lab-training |

**Required secrets**: `MLFLOW_DB_PASSWORD`

```bash
make deploy-phase06
make validate-phase06
```

**Access**: Users authenticate via `mlflow.internal` → Keycloak OIDC login → MLflow UI. The OAuth2 Proxy sits in front as the ALB target.

---

### Phase 07 — Recorder

**Purpose**: Deploy ClickHouse for training metrics and log storage, with Fluent Bit for automated pod log collection.

**Resources created**:

| Category | Resources |
|----------|----------|
| Namespace | logging |
| StatefulSet | ClickHouse (50Gi gp3 PVC) |
| DDL | 3 tables with TTL-based lifecycle |
| DaemonSet | Fluent Bit (all nodes) |
| Backup | AWS Backup vault + daily plan (EBS snapshots) |

```bash
make deploy-phase07
make validate-phase07
```

**Data retention**:

| Table | Engine | TTL | Purpose |
|-------|--------|-----|---------|
| training_metrics | MergeTree | 180 days | Reward, loss, GPU utilization per iteration |
| training_raw_logs | MergeTree | 90 days | Raw pod stdout/stderr |
| training_summary | MergeTree | Permanent | Per-run aggregated results |

---

### Phase 08 — Control Room

**Purpose**: Deploy the full monitoring stack — Prometheus for metrics collection, Grafana for visualization, DCGM Exporter for GPU metrics, and Alertmanager for notifications.

**Resources created**:

| Category | Resources |
|----------|----------|
| Namespace | monitoring |
| Helm | kube-prometheus-stack v65.1.0 |
| DaemonSet | DCGM Exporter (GPU nodes only) |
| Data Sources | Prometheus + ClickHouse in Grafana |
| Dashboards | Training, HPO, Infrastructure, Cost (4 total) |
| Alerts | GPU temp >85C, utilization <10%, OOM, Job failure, Node NotReady |
| Networking | ALB + Route53: grafana.internal |

**Required secrets**: `GRAFANA_ADMIN_PASSWORD`

```bash
make deploy-phase08
make validate-phase08
```

**Grafana dashboards**:

| Dashboard | Key Panels |
|-----------|-----------|
| Training | GPU utilization, mean reward, iterations/sec, loss curves |
| HPO | Trial comparison, parameter distributions, ASHA bracket progress |
| Infrastructure | Node status, CPU/memory, network I/O, disk usage |
| Cost | GPU-hours by job, estimated cost, idle GPU time |

---

### Phase 09 — Lobby

**Purpose**: Deploy JupyterHub as the researcher-facing interface for submitting training jobs, monitoring experiments, and exploring results.

**Resources created**:

| Category | Resources |
|----------|----------|
| Namespace | jupyterhub |
| Docker Image | jupyterhub-notebook (scipy + osmo-client + mlflow + plotly) |
| Helm | Zero to JupyterHub v3.3.8 |
| Auth | Keycloak OIDC (GenericOAuthenticator) |
| ConfigMap | 4 sample notebooks |
| Networking | ALB + Route53: jupyter.internal |

```bash
make deploy-phase09
make validate-phase09
```

**Sample notebooks**:

| Notebook | Purpose |
|----------|---------|
| 01-submit-training.ipynb | Submit RL training jobs via OSMO API |
| 02-monitor-training.ipynb | Real-time training metrics from ClickHouse |
| 03-compare-experiments.ipynb | Compare experiments across MLflow runs |
| 04-model-registry.ipynb | Manage models in MLflow Model Registry |

---

### Phase 10 — Factory Floor

**Purpose**: Build the production training image and run a 4-stage GPU validation pipeline, progressively scaling from 1 GPU to HPO across multiple nodes.

**No Terraform** — this phase uses only shell scripts and Kubernetes manifests.

```bash
make deploy-phase10
make validate-phase10
```

**Stage progression**:

| Stage | GPUs | Nodes | Duration | What It Validates |
|-------|------|-------|----------|-------------------|
| 1. Single GPU | 1 | On-Prem | ~5 min | Basic training loop, ClickHouse logging, MLflow tracking |
| 2. Multi-GPU | 8 | 1 (Karpenter) | ~15 min | Data-parallel scaling, DCGM metrics, GPU utilization >50% |
| 3. Multi-Node | 16 | 2 (Karpenter) | ~30 min | NCCL cross-node communication, EFA transport, Karpenter provisioning |
| 4. HPO | Variable | Variable | ~60 min | Ray Tune ASHA scheduler, 3+ trials, sweep tracking |

**Training image** (`docker/Dockerfile`):
- Base: `nvcr.io/nvidia/isaac-lab:2.2.0`
- Includes: `ray`, `mlflow`, `clickhouse-connect`, `boto3`
- Scripts: `train.py`, `hpo.py`, `clickhouse_logger.py`

**Baseline recording**: After all 4 stages complete, `record-baseline.sh` queries ClickHouse for key metrics and writes `baseline-{timestamp}.json` for future regression comparison.

---

## Operations

### Deploying Individual Phases

Each phase can be deployed independently. All operations are idempotent — re-running a phase produces the same result.

```bash
# Deploy a specific phase
make deploy-phase04

# Plan only (shows what Terraform would change)
./phases/04-gate/deploy.sh --plan-only

# Deploy without validation
./phases/04-gate/deploy.sh --skip-validate
```

### Validating

```bash
# Validate a single phase
make validate-phase04

# Validate all phases
make validate-all
```

Validation checks are non-destructive — they only read state and make no changes.

### Destroying Infrastructure

```bash
# Destroy a single phase
./phases/04-gate/deploy.sh --destroy

# Destroy ALL infrastructure (reverse order, requires typing "DESTROY PRODUCTION")
make destroy
```

`make destroy` tears down phases in reverse order (10 → 01). Each phase runs `terraform destroy` with the appropriate var files. Helm releases and Kubernetes resources are removed before Terraform state.

### Terraform State

Each phase has an **independent Terraform state** file in S3:

```
s3://isaac-lab-prod-terraform-state/
  phases/foundation/terraform.tfstate      ← Phase 01
  phases/platform/terraform.tfstate        ← Phase 02
  phases/bridge/terraform.tfstate          ← Phase 03
  phases/gate/terraform.tfstate            ← Phase 04
  phases/orchestrator/terraform.tfstate    ← Phase 05
  phases/registry/terraform.tfstate        ← Phase 06
  phases/recorder/terraform.tfstate        ← Phase 07
  phases/control-room/terraform.tfstate    ← Phase 08
  phases/lobby/terraform.tfstate           ← Phase 09
```

Cross-phase data is passed via `terraform_remote_state` data sources. For example, Phase 04 reads VPC and RDS outputs from Phase 01 and 02.

### Useful Make Targets

| Command | Description |
|---------|------------|
| `make deploy-phaseXX` | Deploy a specific phase |
| `make validate-phaseXX` | Validate a specific phase |
| `make deploy-all` | Deploy all phases (stops on failure) |
| `make validate-all` | Validate all phases |
| `make destroy` | Destroy everything (reverse order) |
| `make plan-all` | Terraform plan for all phases |
| `make prereqs` | Check tool prerequisites |
| `make prereqs-install` | Auto-install missing tools |
| `make check-auth` | Verify AWS + K8s authentication |
| `make fmt` | Format all Terraform files |
| `make lint` | Lint shell scripts with shellcheck |
| `make clean` | Remove generated plan files |

---

## Configuration Reference

### base.tfvars

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `us-east-1` | AWS region |
| `aws_az` | `us-east-1a` | Single AZ for GPU co-location |
| `vpc_cidr` | `10.100.0.0/21` | VPC CIDR (2,048 IPs) |
| `onprem_cidr` | `10.200.0.0/21` | On-prem network CIDR |
| `cluster_name` | `isaac-lab-production` | EKS cluster name |
| `domain` | `internal` | Private hosted zone domain |
| `s3_prefix` | `isaac-lab-prod` | S3 bucket naming prefix |
| `environment` | `production` | Environment tag |

### Helm Values Files

| File | Phase | Component |
|------|-------|-----------|
| `config/helm/karpenter-values.yaml` | 02 | Karpenter auto-scaler |
| `config/helm/kuberay-operator-values.yaml` | 05 | KubeRay Operator |
| `config/helm/osmo-controller-values.yaml` | 05 | NVIDIA OSMO Controller |
| `config/helm/kube-prometheus-stack-values.yaml` | 08 | Prometheus + Grafana + Alertmanager |
| `config/helm/jupyterhub-values.yaml` | 09 | JupyterHub |

### secrets.env — Full Reference

| Variable | Required | Phase | Description |
|----------|----------|-------|-------------|
| `AWS_ACCOUNT_ID` | Yes | All | AWS account ID |
| `AWS_REGION` | Yes | All | Target region |
| `DX_GATEWAY_ID` | Yes | 01 | Direct Connect Gateway ID |
| `DX_VIF_ID` | No | 01 | Virtual Interface ID |
| `RDS_MASTER_USERNAME` | No | 02 | RDS master user (default: dbadmin) |
| `RDS_MASTER_PASSWORD` | Yes | 02 | RDS master password |
| `KEYCLOAK_DB_NAME` | No | 04 | Keycloak DB name (default: keycloak) |
| `KEYCLOAK_DB_USERNAME` | No | 04 | Keycloak DB user (default: keycloak) |
| `KEYCLOAK_DB_PASSWORD` | Yes | 04 | Keycloak DB password |
| `KEYCLOAK_ADMIN_USERNAME` | No | 04 | Keycloak admin user (default: admin) |
| `KEYCLOAK_ADMIN_PASSWORD` | Yes | 04 | Keycloak admin password |
| `LDAP_CONNECTION_URL` | Yes | 04 | AD LDAP URL |
| `LDAP_BIND_DN` | Yes | 04 | LDAP service account DN |
| `LDAP_BIND_PASSWORD` | Yes | 04 | LDAP bind password |
| `LDAP_USERS_DN` | Yes | 04 | LDAP users search base DN |
| `MLFLOW_DB_NAME` | No | 06 | MLflow DB name (default: mlflow) |
| `MLFLOW_DB_USERNAME` | No | 06 | MLflow DB user (default: mlflow) |
| `MLFLOW_DB_PASSWORD` | Yes | 06 | MLflow DB password |
| `GRAFANA_ADMIN_PASSWORD` | Yes | 08 | Grafana admin password |
| `CLICKHOUSE_ADMIN_USERNAME` | No | 07 | ClickHouse admin user (default: admin) |
| `CLICKHOUSE_ADMIN_PASSWORD` | No | 07 | ClickHouse admin password |
| `SLACK_WEBHOOK_CRITICAL` | No | 08 | Slack webhook for critical alerts |
| `SLACK_WEBHOOK_WARNING` | No | 08 | Slack webhook for warnings |
| `TLS_CERTIFICATE_ARN` | No | — | Pre-existing ACM cert ARN (auto-created if omitted) |

---

## Architecture Notes

### Network: Private-Only

There is **no Internet Gateway or NAT Gateway**. All traffic flows through:

- **Direct Connect**: On-prem ↔ VPC communication
- **VPC Endpoints**: AWS service access (18 endpoints) without internet traversal
- **Virtual Private Gateway**: Default route points to VGW for DX-based egress

This means container images must come from ECR (via VPC endpoint), not public registries.

### Single-AZ Strategy

All subnets are deployed in a **single Availability Zone** (us-east-1a). This is intentional:

- **NCCL bandwidth**: Cross-AZ GPU traffic adds 1-2ms latency, degrading multi-node training
- **FSx Lustre**: Single-AZ filesystem — cross-AZ access would add latency
- **EFA**: Elastic Fabric Adapter requires same-AZ placement

The trade-off is no AZ-level redundancy for the control plane. For RL training workloads, throughput matters more than HA.

### GPU Scaling: Karpenter 0→N

No GPU instances run when idle. Karpenter provisions GPU nodes on demand:

```
Training job submitted → RayJob created → Pods pending (GPU request)
  → Karpenter detects → Launches p4d/p5 Spot instance → Node joins cluster
  → Training runs → Job completes → TTL cleanup → Node terminated
```

On-prem hybrid nodes handle single-GPU workloads (Stage 1, quick experiments) with the taint `workload-type=onprem-single-gpu:NoSchedule`.

### Authentication Flow

```
User → Browser → keycloak.internal
  → Keycloak authenticates against AD via LDAPS:636
  → Keycloak issues JWT:
      {
        "realm_roles": ["researcher"],
        "gpu_quota": 4
      }
  → JWT sent to service (JupyterHub, Grafana, etc.)
  → OSMO Controller reads gpu_quota from JWT to enforce quota
```

GPU quota enforcement by role:

| Role | gpu_quota | AD Group |
|------|-----------|----------|
| researcher | 4 | IsaacLab-Researchers |
| engineer | 10 | IsaacLab-Engineers |
| viewer | 0 | IsaacLab-Viewers |

### Data Flow

```
Training Pod
  ├──[metrics]──→ ClickHouse (training_metrics, TTL 180d)
  ├──[stdout]───→ Fluent Bit → ClickHouse (training_raw_logs, TTL 90d)
  ├──[artifacts]─→ MLflow → S3 models bucket (permanent)
  ├──[ckpts]────→ FSx Lustre → S3 checkpoints (90d→IA, 365d delete)
  └──[GPU stats]─→ DCGM Exporter → Prometheus → Grafana dashboards
```

### Terraform State Isolation

Each phase owns its state independently. This enables:

- **Parallel development**: Teams can work on different phases
- **Blast radius control**: A failed Phase 08 apply won't affect Phase 02
- **Selective destroy**: Tear down monitoring without touching the cluster

Cross-phase references use `terraform_remote_state` data sources with read-only access to previous phase outputs.

---

## Troubleshooting

### Phase 01 — Foundation

**DX Gateway association fails**
```
Error: error associating Direct Connect Gateway: InvalidParameterException
```
Verify that `DX_GATEWAY_ID` is correct and the DX connection is in `available` state. The physical connection must be established before Terraform can associate the gateway.

**ACM certificate stuck in PENDING_VALIDATION**

The certificate uses DNS validation via Route53. If the private hosted zone was just created, allow 2-3 minutes for DNS propagation. Check:
```bash
aws acm describe-certificate --certificate-arn <arn> --query 'Certificate.DomainValidationOptions'
```

### Phase 02 — Platform

**EKS node group creation timeout**

Management node group creation can take 10-15 minutes. If it times out, re-run `make deploy-phase02` — Terraform will resume from where it stopped.

**Karpenter NodePool not scaling**

Check Karpenter controller logs:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller --tail=50
```

Common causes: Instance type not available in AZ, insufficient capacity, missing IAM permissions.

### Phase 03 — Bridge

**Hybrid nodes not appearing in cluster**

1. Verify SSM activation hasn't expired:
   ```bash
   aws ssm describe-activations --filters "FilterKey=DefaultInstanceName,FilterValues=hybrid"
   ```
2. Check nodeadm logs on the on-prem machine:
   ```bash
   sudo journalctl -u nodeadm -f
   ```
3. Verify network connectivity from on-prem to EKS API endpoint (via DX).

**nvidia.com/gpu not reported**

The NVIDIA Device Plugin DaemonSet must be running. Check:
```bash
kubectl get ds -n kube-system nvidia-device-plugin -o wide
kubectl describe node <hybrid-node> | grep nvidia
```

### Phase 04 — Gate

**Keycloak pods in CrashLoopBackOff**

Usually a database connection issue. Check:
```bash
kubectl logs -n keycloak keycloak-0 | grep -i "database\|connection\|refused"
```

Verify the ExternalSecret has synced:
```bash
kubectl get externalsecret -n keycloak
kubectl get secret keycloak-db-credentials -n keycloak -o jsonpath='{.data}' | base64 -d
```

**LDAP federation sync fails**

1. Verify LDAP URL is reachable from the VPC (DX connectivity to AD):
   ```bash
   kubectl exec -n keycloak keycloak-0 -- curl -v ldaps://ad.corp.internal:636
   ```
2. Check Keycloak admin console → User Federation → corp-active-directory → Sync status.

### Phase 05 — Orchestrator

**Ray CRDs not registered after KubeRay install**

CRD registration can take 30-60 seconds. If it persists:
```bash
kubectl get crd | grep ray
kubectl logs -n ray-system -l app.kubernetes.io/name=kuberay-operator
```

**CPU test pipeline fails**

Check the RayJob status and pod events:
```bash
kubectl get rayjob -n training
kubectl describe rayjob cpu-pipeline-test -n training
kubectl get pods -n training -l ray.io/cluster
```

### Phase 06 — Registry

**MLflow returns 502 via ALB**

The OAuth2 Proxy might not be ready. Check both pods:
```bash
kubectl get pods -n mlflow
kubectl logs -n mlflow -l app=oauth2-proxy
```

### Phase 07 — Recorder

**ClickHouse DDL apply fails**

Verify ClickHouse is accepting connections:
```bash
kubectl exec -n logging clickhouse-0 -- clickhouse-client --query "SELECT 1"
```

### Phase 08 — Control Room

**Grafana data source test fails for ClickHouse**

ClickHouse must be deployed (Phase 07) before configuring Grafana. Verify cross-namespace DNS:
```bash
kubectl exec -n monitoring <grafana-pod> -- curl http://clickhouse.logging.svc.cluster.local:8123/ping
```

**DCGM Exporter shows 0 desired pods**

This is expected if no GPU nodes are currently provisioned. DCGM Exporter uses a `nodeSelector` targeting GPU nodes — pods will appear when Karpenter scales up GPU nodes for training.

### Phase 10 — Factory Floor

**Stage 2/3 timeout waiting for GPU nodes**

Karpenter needs to provision GPU instances. This depends on:
- Available capacity in the AZ (Spot or On-Demand)
- Correct instance profile and security group configuration

Check Karpenter logs and pending NodeClaims:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller --tail=100
kubectl get nodeclaims
```

**NCCL errors in multi-node training**

Check that Security Group `SG-GPU-Node` allows self-referencing traffic on all ports. NCCL requires high-bandwidth inter-node communication.

```bash
# Check worker pod logs for NCCL info
kubectl logs -n training <worker-pod> | grep -i nccl
```

### General

**Terraform state lock**

If a previous run was interrupted, the DynamoDB lock may be stale:
```bash
terraform -chdir=phases/XX-name/terraform force-unlock <LOCK_ID>
```

**ExternalSecret not syncing**

Check the ClusterSecretStore health:
```bash
kubectl get clustersecretstore
kubectl get externalsecret -A
```

Verify the External Secrets Operator IRSA role has `secretsmanager:GetSecretValue` permission.

**ALB provisioning takes >5 minutes**

Check the AWS Load Balancer Controller logs:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

Common causes: Missing subnet tags, security group misconfiguration, ACM certificate not yet validated.
