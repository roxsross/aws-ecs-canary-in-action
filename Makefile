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
STACK        ?= $(PROJECT)
FLAVOUR      ?= terraform
STEPS        ?= 5,25,50,100
BAKE         ?= 90
CANARY_TASKS ?= 1
RPS          ?= 10
DURATION     ?= 60

SCRIPTS   := ./scripts
TF_DIR    := infra/terraform
CFN_DIR   := infra/cloudformation
CDK_DIR   := infra/cdk
LOCAL_DIR := local

CYAN  := \033[36m
DIM   := \033[2m
BOLD  := \033[1m
RESET := \033[0m

.PHONY: help
help: ## Show this help
	@printf '\n$(BOLD)ECS Canary in Action$(RESET)\n'
	@printf '$(DIM)canary deployments on ECS Fargate, in an existing VPC$(RESET)\n\n'
	@awk 'BEGIN { FS = ":.*##" } \
		/^[a-zA-Z0-9_.-]+:.*##/ { printf "  $(CYAN)%-22s$(RESET) %s\n", $$1, $$2 } \
		/^##@/ { printf "\n$(BOLD)%s$(RESET)\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@printf '\n$(DIM)variables: PROJECT=$(PROJECT) TAG=$(TAG) REGION=$(REGION) FLAVOUR=$(FLAVOUR)$(RESET)\n\n'

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

##@ Infrastructure (pick one flavour)

.PHONY: vpc
vpc: ## List existing VPCs and subnets you could use
	$(SCRIPTS)/discover-vpc.sh --region $(REGION)

.PHONY: tf-init tf-plan tf-apply tf-destroy
tf-init: ## terraform init
	terraform -chdir=$(TF_DIR) init

tf-plan: ## terraform plan
	terraform -chdir=$(TF_DIR) plan

tf-apply: ## terraform apply, then load the script environment
	terraform -chdir=$(TF_DIR) apply
	$(MAKE) env FLAVOUR=terraform

tf-destroy: ## terraform destroy
	terraform -chdir=$(TF_DIR) destroy

.PHONY: cfn-deploy cfn-destroy
cfn-deploy: ## Deploy the CloudFormation stack, then load the environment
	$(CFN_DIR)/deploy.sh --stack-name $(STACK) --region $(REGION) --keep-weights
	$(MAKE) env FLAVOUR=cloudformation

cfn-destroy: ## Delete the CloudFormation stack
	$(CFN_DIR)/deploy.sh --stack-name $(STACK) --region $(REGION) --delete

.PHONY: cdk-deploy cdk-destroy cdk-synth
cdk-synth: ## cdk synth (no credentials needed)
	cd $(CDK_DIR) && npm install --silent && npx cdk synth

cdk-deploy: ## Deploy with CDK, then load the environment
	cd $(CDK_DIR) && npm install --silent && npx cdk deploy --require-approval never
	$(MAKE) env FLAVOUR=cdk

cdk-destroy: ## Destroy the CDK stack
	cd $(CDK_DIR) && npx cdk destroy

.PHONY: env
env: ## Regenerate .canary.env from the deployed stack
	$(SCRIPTS)/load-env.sh $(FLAVOUR) --stack $(STACK) --region $(REGION)

##@ Canary flow

.PHONY: status watch
status: ## Show the traffic split, services, target health and alarms
	$(SCRIPTS)/status.sh

watch: ## Same as status, refreshing
	$(SCRIPTS)/status.sh --watch

.PHONY: canary
canary: ## Progressive rollout with automatic rollback (make canary TAG=v2)
	$(SCRIPTS)/canary-deploy.sh --tag $(TAG) --steps $(STEPS) --bake $(BAKE) --canary-tasks $(CANARY_TASKS)

.PHONY: promote rollback
promote: ## Promote a version to stable (make promote TAG=v2)
	$(SCRIPTS)/promote.sh --tag $(TAG)

rollback: ## Send all traffic back to stable, now
	$(SCRIPTS)/rollback.sh

.PHONY: weights
weights: ## Show or set the split (make weights CANARY=25)
	@if [ -n "$(CANARY)" ]; then \
		$(SCRIPTS)/weights.sh --canary $(CANARY); \
	else \
		$(SCRIPTS)/weights.sh; \
	fi

.PHONY: traffic
traffic: ## Generate traffic and report the observed split
	$(SCRIPTS)/traffic-gen.sh --rps $(RPS) --duration $(DURATION)

.PHONY: break fix chaos-show
break: ## Break the canary on purpose (50% 5xx + 1200ms)
	$(SCRIPTS)/chaos.sh --break

fix: ## Remove every injected fault
	$(SCRIPTS)/chaos.sh --clear

chaos-show: ## Show what is currently injected
	$(SCRIPTS)/chaos.sh --show

##@ Guided demos

.PHONY: demo-rollout
demo-rollout: ## Happy path: push TAG, roll it out, promote
	@printf '\n$(BOLD)Happy path$(RESET) $(DIM)push $(TAG), shift traffic in steps, promote$(RESET)\n\n'
	$(MAKE) push TAG=$(TAG)
	$(SCRIPTS)/canary-deploy.sh --tag $(TAG) --steps $(STEPS) --bake $(BAKE)
	$(MAKE) status

.PHONY: demo-rollback
demo-rollback: ## Failure path: break the canary and watch it roll itself back
	@printf '\n$(BOLD)Failure path$(RESET) $(DIM)the canary misbehaves, alarms fire, traffic goes back$(RESET)\n\n'
	@printf '  1. run this in another terminal:  make watch\n'
	@printf '  2. this will start a rollout and break it on purpose\n\n'
	$(SCRIPTS)/weights.sh --canary 25
	$(SCRIPTS)/chaos.sh --break
	@printf '\n  waiting 90s for the alarms to notice...\n\n'
	@sleep 90
	$(SCRIPTS)/status.sh
	$(SCRIPTS)/rollback.sh --yes
	$(SCRIPTS)/chaos.sh --clear

##@ Checks

.PHONY: lint
lint: lint-js lint-sh lint-tf lint-cfn lint-cdk ## Run every static check

.PHONY: lint-sh
lint-sh: ## shellcheck + bash syntax on every script
	@fail=0; \
	files=$$(find scripts infra -name '*.sh' -type f -not -path '*/node_modules/*' | sort); \
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

.PHONY: lint-cfn
lint-cfn: ## Validate the CloudFormation template
	aws cloudformation validate-template \
		--template-body file://$(CFN_DIR)/canary-stack.yaml \
		--region $(REGION) --query Description --output text

.PHONY: lint-cdk
lint-cdk: ## Type check and synth the CDK app
	# Placeholder network values: this is a syntax and synth check, not a deployment.
	cd $(CDK_DIR) && npm install --silent && npx tsc --noEmit && \
		npx cdk synth \
			-c vpcId=vpc-0123456789abcdef0 \
			-c publicSubnetIds=subnet-0aaaaaaaaaaaaaaaa,subnet-0bbbbbbbbbbbbbbbb \
			>/dev/null
	@printf '  cdk synth ok\n'

.PHONY: lint-js
lint-js: ## Syntax check the Node sources
	@for f in $$(find app local -name '*.js' -not -path '*/node_modules/*' | sort); do \
		node --check "$$f" || exit 1; \
	done; \
	printf '  javascript ok\n'

##@ Cleanup

.PHONY: clean
clean: ## Remove local build artefacts and the generated environment file
	rm -rf $(CDK_DIR)/cdk.out .canary.env
	find . -name '*.tfplan' -delete
	@printf '  cleaned\n'
