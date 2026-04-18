################################################################################
# Isaac Lab Production Deployment - Makefile
#
# Usage:
#   make deploy-phase01       Deploy Phase 1 (Foundation)
#   make validate-phase01     Validate Phase 1
#   make deploy-all           Deploy all phases sequentially
#   make validate-all         Validate all phases
#   make destroy              Destroy all infrastructure (reverse order)
#   make prereqs              Check prerequisites
#   make help                 Show this help
################################################################################

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

# Directories
ROOT_DIR := $(shell pwd)
PHASES_DIR := $(ROOT_DIR)/phases
LIB_DIR := $(ROOT_DIR)/lib
CONFIG_DIR := $(ROOT_DIR)/config

# Environment (override with: make deploy-phase01 TF_ENV=staging)
TF_ENV ?= production
export TF_ENV

# Terraform parallelism
TF_PARALLELISM ?= 10
export TF_PARALLELISM

# Color codes for Make output
_CYAN := \033[0;36m
_GREEN := \033[0;32m
_YELLOW := \033[0;33m
_RED := \033[0;31m
_BOLD := \033[1m
_RESET := \033[0m

# ---------------------------------------------------------------------------
# Phase mapping: phase number -> directory name -> description
# ---------------------------------------------------------------------------
PHASE_01_DIR := 01-foundation
PHASE_02_DIR := 02-platform
PHASE_03_DIR := 03-bridge
PHASE_04_DIR := 04-gate
PHASE_05_DIR := 05-orchestrator
PHASE_06_DIR := 06-registry
PHASE_07_DIR := 07-recorder
PHASE_08_DIR := 08-control-room
PHASE_09_DIR := 09-lobby
PHASE_10_DIR := 10-factory-floor

PHASE_01_DESC := "Network Foundation (VPC, Subnets, DX, SG, Route53)"
PHASE_02_DESC := "EKS Platform (Cluster, Karpenter, RDS, S3, FSx, ECR)"
PHASE_03_DESC := "Hybrid Nodes Bridge (On-Prem GPU Registration)"
PHASE_04_DESC := "Authentication Gate (Keycloak, AD Federation, OIDC)"
PHASE_05_DESC := "Orchestrator (OSMO Controller, KubeRay)"
PHASE_06_DESC := "Registry (MLflow Tracking + Model Registry)"
PHASE_07_DESC := "Recorder (ClickHouse, Fluent Bit)"
PHASE_08_DESC := "Control Room (Prometheus, Grafana, DCGM Exporter)"
PHASE_09_DESC := "Lobby (JupyterHub)"
PHASE_10_DESC := "Factory Floor (E2E GPU Training Pipeline)"

ALL_PHASES := 01 02 03 04 05 06 07 08 09 10

# ===========================================================================
# Prerequisites
# ===========================================================================
.PHONY: prereqs
prereqs: ## Check all prerequisites
	@echo -e "$(_BOLD)Checking prerequisites...$(_RESET)"
	@source $(LIB_DIR)/prereqs.sh && check_prereqs

.PHONY: prereqs-install
prereqs-install: ## Auto-install missing prerequisites
	@source $(LIB_DIR)/prereqs.sh && auto_install_prereqs

.PHONY: check-auth
check-auth: ## Verify AWS and Kubernetes authentication
	@source $(LIB_DIR)/prereqs.sh && check_aws_auth && check_kubeconfig

# ===========================================================================
# Deploy targets
# ===========================================================================

.PHONY: deploy-phase01
deploy-phase01: ## Deploy Phase 1: Network Foundation
	@echo -e "$(_BOLD)$(_CYAN)Deploying Phase 01: $(PHASE_01_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_01_DIR)/deploy.sh

.PHONY: deploy-phase02
deploy-phase02: ## Deploy Phase 2: EKS Platform
	@echo -e "$(_BOLD)$(_CYAN)Deploying Phase 02: $(PHASE_02_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_02_DIR)/deploy.sh

.PHONY: deploy-phase03
deploy-phase03: ## Deploy Phase 3: Hybrid Nodes Bridge
	@echo -e "$(_BOLD)$(_CYAN)Deploying Phase 03: $(PHASE_03_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_03_DIR)/deploy.sh

.PHONY: deploy-phase04
deploy-phase04: ## Deploy Phase 4: Authentication Gate
	@echo -e "$(_BOLD)$(_CYAN)Deploying Phase 04: $(PHASE_04_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_04_DIR)/deploy.sh

.PHONY: deploy-phase05
deploy-phase05: ## Deploy Phase 5: Orchestrator
	@echo -e "$(_BOLD)$(_CYAN)Deploying Phase 05: $(PHASE_05_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_05_DIR)/deploy.sh

.PHONY: deploy-phase06
deploy-phase06: ## Deploy Phase 6: Registry
	@echo -e "$(_BOLD)$(_CYAN)Deploying Phase 06: $(PHASE_06_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_06_DIR)/deploy.sh

.PHONY: deploy-phase07
deploy-phase07: ## Deploy Phase 7: Recorder
	@echo -e "$(_BOLD)$(_CYAN)Deploying Phase 07: $(PHASE_07_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_07_DIR)/deploy.sh

.PHONY: deploy-phase08
deploy-phase08: ## Deploy Phase 8: Control Room
	@echo -e "$(_BOLD)$(_CYAN)Deploying Phase 08: $(PHASE_08_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_08_DIR)/deploy.sh

.PHONY: deploy-phase09
deploy-phase09: ## Deploy Phase 9: Lobby
	@echo -e "$(_BOLD)$(_CYAN)Deploying Phase 09: $(PHASE_09_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_09_DIR)/deploy.sh

.PHONY: deploy-phase10
deploy-phase10: ## Deploy Phase 10: Factory Floor
	@echo -e "$(_BOLD)$(_CYAN)Deploying Phase 10: $(PHASE_10_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_10_DIR)/deploy.sh

# ===========================================================================
# Validate targets
# ===========================================================================

.PHONY: validate-phase01
validate-phase01: ## Validate Phase 1: Network Foundation
	@echo -e "$(_BOLD)$(_GREEN)Validating Phase 01: $(PHASE_01_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_01_DIR)/validate.sh

.PHONY: validate-phase02
validate-phase02: ## Validate Phase 2: EKS Platform
	@echo -e "$(_BOLD)$(_GREEN)Validating Phase 02: $(PHASE_02_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_02_DIR)/validate.sh

.PHONY: validate-phase03
validate-phase03: ## Validate Phase 3: Hybrid Nodes Bridge
	@echo -e "$(_BOLD)$(_GREEN)Validating Phase 03: $(PHASE_03_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_03_DIR)/validate.sh

.PHONY: validate-phase04
validate-phase04: ## Validate Phase 4: Authentication Gate
	@echo -e "$(_BOLD)$(_GREEN)Validating Phase 04: $(PHASE_04_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_04_DIR)/validate.sh

.PHONY: validate-phase05
validate-phase05: ## Validate Phase 5: Orchestrator
	@echo -e "$(_BOLD)$(_GREEN)Validating Phase 05: $(PHASE_05_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_05_DIR)/validate.sh

.PHONY: validate-phase06
validate-phase06: ## Validate Phase 6: Registry
	@echo -e "$(_BOLD)$(_GREEN)Validating Phase 06: $(PHASE_06_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_06_DIR)/validate.sh

.PHONY: validate-phase07
validate-phase07: ## Validate Phase 7: Recorder
	@echo -e "$(_BOLD)$(_GREEN)Validating Phase 07: $(PHASE_07_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_07_DIR)/validate.sh

.PHONY: validate-phase08
validate-phase08: ## Validate Phase 8: Control Room
	@echo -e "$(_BOLD)$(_GREEN)Validating Phase 08: $(PHASE_08_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_08_DIR)/validate.sh

.PHONY: validate-phase09
validate-phase09: ## Validate Phase 9: Lobby
	@echo -e "$(_BOLD)$(_GREEN)Validating Phase 09: $(PHASE_09_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_09_DIR)/validate.sh

.PHONY: validate-phase10
validate-phase10: ## Validate Phase 10: Factory Floor
	@echo -e "$(_BOLD)$(_GREEN)Validating Phase 10: $(PHASE_10_DESC)$(_RESET)"
	@$(PHASES_DIR)/$(PHASE_10_DIR)/validate.sh

# ===========================================================================
# Aggregate targets
# ===========================================================================

.PHONY: deploy-all
deploy-all: ## Deploy all phases sequentially (01 through 10)
	@echo -e "$(_BOLD)$(_CYAN)========================================$(_RESET)"
	@echo -e "$(_BOLD)$(_CYAN)  Isaac Lab Production - Full Deployment$(_RESET)"
	@echo -e "$(_BOLD)$(_CYAN)  Environment: $(TF_ENV)$(_RESET)"
	@echo -e "$(_BOLD)$(_CYAN)========================================$(_RESET)"
	@echo ""
	@for phase in $(ALL_PHASES); do \
		echo -e "$(_BOLD)--- Phase $${phase} ---$(_RESET)"; \
		$(MAKE) --no-print-directory deploy-phase$${phase} || { \
			echo -e "$(_RED)Phase $${phase} failed. Stopping deployment.$(_RESET)"; \
			exit 1; \
		}; \
		echo -e "$(_GREEN)Phase $${phase} complete.$(_RESET)"; \
		echo ""; \
	done
	@echo -e "$(_BOLD)$(_GREEN)All phases deployed successfully.$(_RESET)"

.PHONY: validate-all
validate-all: ## Validate all phases sequentially
	@echo -e "$(_BOLD)$(_GREEN)========================================$(_RESET)"
	@echo -e "$(_BOLD)$(_GREEN)  Isaac Lab Production - Full Validation$(_RESET)"
	@echo -e "$(_BOLD)$(_GREEN)========================================$(_RESET)"
	@echo ""
	@_fail=0; \
	for phase in $(ALL_PHASES); do \
		echo -e "$(_BOLD)--- Validating Phase $${phase} ---$(_RESET)"; \
		$(MAKE) --no-print-directory validate-phase$${phase} || _fail=1; \
		echo ""; \
	done; \
	if [ "$$_fail" = "1" ]; then \
		echo -e "$(_RED)$(_BOLD)Some validations failed. Review output above.$(_RESET)"; \
		exit 1; \
	fi
	@echo -e "$(_BOLD)$(_GREEN)All validations passed.$(_RESET)"

# ===========================================================================
# Destroy (reverse order with confirmation)
# ===========================================================================

.PHONY: destroy
destroy: ## Destroy ALL infrastructure (reverse order, with confirmation)
	@echo ""
	@echo -e "$(_RED)$(_BOLD)================================================================================$(_RESET)"
	@echo -e "$(_RED)$(_BOLD)  WARNING: This will DESTROY all Isaac Lab production infrastructure.$(_RESET)"
	@echo -e "$(_RED)$(_BOLD)  Environment: $(TF_ENV)$(_RESET)"
	@echo -e "$(_RED)$(_BOLD)================================================================================$(_RESET)"
	@echo ""
	@echo -e "$(_RED)Destruction order (reverse):$(_RESET)"
	@echo "  10. Factory Floor (E2E Pipeline)"
	@echo "   9. Lobby (JupyterHub)"
	@echo "   8. Control Room (Prometheus, Grafana)"
	@echo "   7. Recorder (ClickHouse, Fluent Bit)"
	@echo "   6. Registry (MLflow)"
	@echo "   5. Orchestrator (OSMO, KubeRay)"
	@echo "   4. Gate (Keycloak)"
	@echo "   3. Bridge (Hybrid Nodes)"
	@echo "   2. Platform (EKS, RDS, S3, FSx)"
	@echo "   1. Foundation (VPC, Subnets, DX)"
	@echo ""
	@echo -en "$(_YELLOW)Type 'DESTROY PRODUCTION' to confirm: $(_RESET)"
	@read confirmation; \
	if [ "$$confirmation" != "DESTROY PRODUCTION" ]; then \
		echo -e "$(_GREEN)Destruction cancelled.$(_RESET)"; \
		exit 0; \
	fi
	@echo ""
	@echo -e "$(_RED)Starting destruction in reverse order...$(_RESET)"
	@for phase in 10 09 08 07 06 05 04 03 02 01; do \
		phase_dir="$(PHASES_DIR)/$$(case $$phase in \
			01) echo '$(PHASE_01_DIR)';; 02) echo '$(PHASE_02_DIR)';; \
			03) echo '$(PHASE_03_DIR)';; 04) echo '$(PHASE_04_DIR)';; \
			05) echo '$(PHASE_05_DIR)';; 06) echo '$(PHASE_06_DIR)';; \
			07) echo '$(PHASE_07_DIR)';; 08) echo '$(PHASE_08_DIR)';; \
			09) echo '$(PHASE_09_DIR)';; 10) echo '$(PHASE_10_DIR)';; \
		esac)"; \
		if [ -f "$${phase_dir}/destroy.sh" ]; then \
			echo -e "$(_RED)Destroying Phase $${phase}...$(_RESET)"; \
			"$${phase_dir}/destroy.sh" || { \
				echo -e "$(_RED)Phase $${phase} destroy failed. Continuing...$(_RESET)"; \
			}; \
		elif [ -d "$${phase_dir}" ]; then \
			echo -e "$(_YELLOW)Phase $${phase}: No destroy.sh found, attempting terraform destroy...$(_RESET)"; \
			source $(LIB_DIR)/terraform.sh && \
			tf_init "$${phase_dir}" && \
			terraform -chdir="$${phase_dir}" destroy \
				-input=false -auto-approve \
				-var-file="$(CONFIG_DIR)/base.tfvars" \
				-var-file="$(CONFIG_DIR)/env/$(TF_ENV).tfvars" \
			|| echo -e "$(_RED)Phase $${phase} terraform destroy failed.$(_RESET)"; \
		else \
			echo -e "$(_YELLOW)Phase $${phase}: directory not found, skipping.$(_RESET)"; \
		fi; \
		echo ""; \
	done
	@echo -e "$(_RED)$(_BOLD)Destruction complete.$(_RESET)"

# ===========================================================================
# Utility targets
# ===========================================================================

.PHONY: plan-all
plan-all: ## Run terraform plan for all phases (dry-run)
	@for phase in $(ALL_PHASES); do \
		phase_dir="$(PHASES_DIR)/$$(case $$phase in \
			01) echo '$(PHASE_01_DIR)';; 02) echo '$(PHASE_02_DIR)';; \
			03) echo '$(PHASE_03_DIR)';; 04) echo '$(PHASE_04_DIR)';; \
			05) echo '$(PHASE_05_DIR)';; 06) echo '$(PHASE_06_DIR)';; \
			07) echo '$(PHASE_07_DIR)';; 08) echo '$(PHASE_08_DIR)';; \
			09) echo '$(PHASE_09_DIR)';; 10) echo '$(PHASE_10_DIR)';; \
		esac)"; \
		if [ -d "$${phase_dir}" ] && ls "$${phase_dir}"/*.tf &>/dev/null; then \
			echo -e "$(_CYAN)Planning Phase $${phase}...$(_RESET)"; \
			source $(LIB_DIR)/terraform.sh && \
			tf_init "$${phase_dir}" && \
			tf_plan "$${phase_dir}" || true; \
			echo ""; \
		fi; \
	done

.PHONY: fmt
fmt: ## Format all Terraform files
	@terraform fmt -recursive $(PHASES_DIR)
	@terraform fmt -recursive $(ROOT_DIR)/modules
	@echo -e "$(_GREEN)Terraform files formatted.$(_RESET)"

.PHONY: lint
lint: ## Lint shell scripts with shellcheck
	@if command -v shellcheck &>/dev/null; then \
		echo "Linting shell scripts..."; \
		find $(LIB_DIR) $(PHASES_DIR) -name '*.sh' -exec shellcheck -x {} +; \
		echo -e "$(_GREEN)All scripts passed shellcheck.$(_RESET)"; \
	else \
		echo -e "$(_YELLOW)shellcheck not installed. Run: brew install shellcheck$(_RESET)"; \
	fi

.PHONY: clean
clean: ## Clean up generated files (tfplan, .terraform)
	@echo "Cleaning up..."
	@find $(ROOT_DIR) -name "*.tfplan" -delete 2>/dev/null || true
	@find $(ROOT_DIR) -name "tfplan" -delete 2>/dev/null || true
	@echo -e "$(_GREEN)Cleaned up plan files.$(_RESET)"

# ===========================================================================
# Help
# ===========================================================================

.PHONY: help
help: ## Show this help message
	@echo ""
	@echo -e "$(_BOLD)Isaac Lab Production Deployment$(_RESET)"
	@echo -e "$(_BOLD)===============================$(_RESET)"
	@echo ""
	@echo "Usage: make <target> [TF_ENV=production]"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(_CYAN)%-22s$(_RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo -e "$(_BOLD)Phases:$(_RESET)"
	@echo "  01  $(PHASE_01_DESC)"
	@echo "  02  $(PHASE_02_DESC)"
	@echo "  03  $(PHASE_03_DESC)"
	@echo "  04  $(PHASE_04_DESC)"
	@echo "  05  $(PHASE_05_DESC)"
	@echo "  06  $(PHASE_06_DESC)"
	@echo "  07  $(PHASE_07_DESC)"
	@echo "  08  $(PHASE_08_DESC)"
	@echo "  09  $(PHASE_09_DESC)"
	@echo "  10  $(PHASE_10_DESC)"
	@echo ""
