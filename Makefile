# ---------------------------------------------------------------------------
# ECS Canary in Action
#
#   make help          see everything
#   make local         rehearse the whole flow with no AWS account
#   make demo-rollout  the happy path on AWS
#   make demo-rollback the failure path, with automatic rollback
# ---------------------------------------------------------------------------

SHELL := /bin/bash
.DEFAULT_GOAL := help

PROJECT      ?= canary-lab
TAG          ?= v1
REGION       ?= $(or $(AWS_REGION),us-east-1)
RPS          ?= 10
DURATION     ?= 60

SCRIPTS   := ./scripts
TF_DIR    := infra/terraform
LOCAL_DIR := local

CYAN  := \033[36m
DIM   := \033[2m
BOLD  := \033[1m
RESET := \033[0m

.PHONY: help
help: ## Show this help
	@printf '\n$(BOLD)ECS Canary in Action$(RESET)\n'
	@printf '$(DIM)canary deployments on ECS Fargate$(RESET)\n\n'
	@awk 'BEGIN { FS = ":.*##" } \
		/^[a-zA-Z0-9_.-]+:.*##/ { printf "  $(CYAN)%-22s$(RESET) %s\n", $$1, $$2 } \
		/^##@/ { printf "\n$(BOLD)%s$(RESET)\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@printf '\n$(DIM)variables: PROJECT=$(PROJECT) TAG=$(TAG) REGION=$(REGION)$(RESET)\n\n'

##@ Local, no AWS account needed

.PHONY: local
local: ## Start the local stack (mini-alb + stable + canary + dynamodb)
	cd $(LOCAL_DIR) && docker compose up --build -d
	@printf '\n  dashboard  http://localhost:8080\n'
	@printf '  stable     http://localhost:8081\n'
	@printf '  canary     http://localhost:8082\n\n'
	@printf '  shift traffic:  $(SCRIPTS)/weights.sh --target local --canary 25\n\n'

.PHONY: local-down
local-down: ## Stop the local stack and remove its volumes
	cd $(LOCAL_DIR) && docker compose down -v

.PHONY: local-logs
local-logs: ## Follow the local stack logs
	cd $(LOCAL_DIR) && docker compose logs -f --tail 50

.PHONY: local-canary
local-canary: ## Shift local traffic (use CANARY=25)
	$(SCRIPTS)/weights.sh --target local --canary $(or $(CANARY),5)

.PHONY: dev
dev: ## Run the app on your machine (port 8080, in memory store)
	cd app && npm install && npm run dev

.PHONY: smoke
smoke: ## Probe a running app (BASE_URL=http://localhost:8080)
	cd app && BASE_URL=$(or $(BASE_URL),http://localhost:8080) npm run smoke

##@ Image

.PHONY: ecr push
ecr: push ## Alias for push
push: ## Build and push the image (make push TAG=v2)
	$(SCRIPTS)/build-push.sh --tag $(TAG) --project $(PROJECT) --region $(REGION)

##@ Infrastructure (Terraform)

.PHONY: tf-init tf-plan tf-apply tf-destroy
tf-init: ## terraform init
	terraform -chdir=$(TF_DIR) init

tf-plan: ## terraform plan
	terraform -chdir=$(TF_DIR) plan

tf-apply: ## terraform apply, then load the script environment
	terraform -chdir=$(TF_DIR) apply
	$(MAKE) env

tf-destroy: ## terraform destroy
	terraform -chdir=$(TF_DIR) destroy

.PHONY: env
env: ## Regenerate .canary.env from terraform output
	$(SCRIPTS)/load-env.sh --region $(REGION)

##@ Canary flow

.PHONY: status watch
status: ## Show the rollout state, target health and alarms
	$(SCRIPTS)/status.sh

watch: ## Same as status, refreshing
	$(SCRIPTS)/status.sh --watch

.PHONY: canary
canary: ## Canary rollout using ECS's native strategy (make canary TAG=v2)
	$(SCRIPTS)/canary-deploy.sh --tag $(TAG)

.PHONY: rollback
rollback: ## Redeploy the previous task definition, right now
	$(SCRIPTS)/rollback.sh

.PHONY: weights
weights: ## Show the current rollout / traffic status (AWS: read only)
	$(SCRIPTS)/weights.sh

.PHONY: traffic
traffic: ## Generate traffic and report the observed split
	$(SCRIPTS)/traffic-gen.sh --rps $(RPS) --duration $(DURATION)

.PHONY: break fix chaos-show
break: ## Inject a fault into the canary on purpose (50% 5xx + 1200ms)
	$(SCRIPTS)/chaos.sh --break

fix: ## Remove every injected fault
	$(SCRIPTS)/chaos.sh --clear

chaos-show: ## Show what is currently injected
	$(SCRIPTS)/chaos.sh --show

##@ Guided demos

.PHONY: demo-rollout
demo-rollout: ## Happy path: push TAG, let ECS roll it out
	@printf '\n$(BOLD)Happy path$(RESET) $(DIM)push $(TAG), ECS shifts traffic and bakes on its own$(RESET)\n\n'
	$(MAKE) push TAG=$(TAG)
	$(SCRIPTS)/canary-deploy.sh --tag $(TAG) --yes
	$(MAKE) status

.PHONY: demo-rollback
demo-rollback: ## Failure path: start a rollout, break it mid-flight, watch ECS revert it
	@printf '\n$(BOLD)Failure path$(RESET) $(DIM)a rollout starts, the new revision misbehaves, ECS reverts it on its own$(RESET)\n\n'
	@printf '  1. run this in another terminal:  make watch\n\n'
	$(SCRIPTS)/canary-deploy.sh --tag $(TAG) --yes &
	@sleep 20
	$(SCRIPTS)/chaos.sh --break
	@printf '\n  waiting for ECS to notice and roll back...\n\n'
	wait
	$(SCRIPTS)/status.sh
	$(SCRIPTS)/chaos.sh --clear

##@ Checks

.PHONY: lint
lint: lint-js lint-sh lint-tf lint-trivy ## Run every static check

.PHONY: lint-sh
lint-sh: ## shellcheck + bash syntax on every script
	@fail=0; \
	files=$$(find scripts -name '*.sh' -type f | sort); \
	for f in $$files; do \
		bash -n "$$f" || fail=1; \
		if command -v shellcheck >/dev/null 2>&1; then \
			shellcheck -x "$$f" || fail=1; \
		fi; \
	done; \
	if ! command -v shellcheck >/dev/null 2>&1; then \
		printf '  shellcheck not installed, ran bash -n only\n'; \
	fi; \
	if [ $$fail -eq 0 ]; then printf '  shell scripts ok\n'; else exit 1; fi

.PHONY: lint-tf
lint-tf: ## terraform fmt + validate
	terraform -chdir=$(TF_DIR) fmt -check -recursive
	terraform -chdir=$(TF_DIR) init -backend=false -input=false >/dev/null
	terraform -chdir=$(TF_DIR) validate

.PHONY: lint-js
lint-js: ## Syntax check the Node sources
	@for f in $$(find app local -name '*.js' -not -path '*/node_modules/*' | sort); do \
		node --check "$$f" || exit 1; \
	done; \
	printf '  javascript ok\n'

.PHONY: lint-trivy
lint-trivy: ## Security scan the Terraform stack with Trivy (tfsec's successor)
	@command -v trivy >/dev/null 2>&1 || { \
		printf '  trivy not installed. brew install trivy\n'; \
		exit 1; \
	}
	trivy config --severity HIGH,CRITICAL --exit-code 1 $(TF_DIR)
	@printf '  trivy: no HIGH/CRITICAL findings\n'

##@ Cleanup

.PHONY: clean
clean: ## Remove local build artefacts and the generated environment file
	rm -f .canary.env
	find . -name '*.tfplan' -delete
	@printf '  cleaned\n'
