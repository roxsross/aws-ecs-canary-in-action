#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Reads the outputs of whichever infrastructure flavour you deployed and writes
# the CANARY_* contract every other script consumes.
#
#   ./scripts/load-env.sh terraform
#   ./scripts/load-env.sh cloudformation --stack canary-lab
#   ./scripts/load-env.sh cdk --stack canary-lab
#
#   eval "$(./scripts/load-env.sh terraform --export)"   # just this shell
#
# The result is written to .canary.env at the repo root, which the other scripts
# source automatically. Nothing secret ends up in there: only names and ARNs.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

FLAVOUR=""
STACK_NAME="${STACK_NAME:-canary-lab}"
TF_DIR="${SCRIPT_DIR}/../infra/terraform"
EXPORT_ONLY=false
QUIET=false

usage() {
  print_header_help "${BASH_SOURCE[0]}"
  cat <<'EOF'
Arguments
  terraform | cloudformation | cdk    Where to read the outputs from

Options
  --stack NAME      CloudFormation / CDK stack name (default: canary-lab)
  --tf-dir PATH     Terraform directory (default: infra/terraform)
  --region REGION   AWS region for the stack lookup
  --export          Print `export VAR=...` lines instead of writing the file
  --quiet           Suppress the summary
  --print           Print the resolved values and exit without writing
  -h, --help        This help
EOF
}

PRINT_ONLY=false

while [ $# -gt 0 ]; do
  case "$1" in
    terraform | tf)
      FLAVOUR=terraform
      shift
      ;;
    cloudformation | cfn)
      FLAVOUR=cloudformation
      shift
      ;;
    cdk)
      FLAVOUR=cdk
      shift
      ;;
    --stack)
      STACK_NAME="$2"
      shift 2
      ;;
    --tf-dir)
      TF_DIR="$2"
      shift 2
      ;;
    --region)
      export AWS_REGION="$2"
      shift 2
      ;;
    --export)
      EXPORT_ONLY=true
      shift
      ;;
    --print)
      PRINT_ONLY=true
      shift
      ;;
    --quiet)
      QUIET=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 2
      ;;
  esac
done

[ -n "$FLAVOUR" ] || {
  err "say where to read the outputs from: terraform, cloudformation or cdk"
  usage >&2
  exit 2
}

require_tools jq

# Keys of the contract, in the order they are written.
CONTRACT_KEYS="CANARY_REGION CANARY_PROJECT CANARY_CLUSTER CANARY_ALB_DNS CANARY_ALB_ARN \
CANARY_LISTENER_ARN CANARY_TG_STABLE CANARY_TG_CANARY CANARY_SVC_STABLE CANARY_SVC_CANARY \
CANARY_TASKDEF_STABLE CANARY_TASKDEF_CANARY CANARY_ECR_REPO CANARY_ECR_URI CANARY_TABLE \
CANARY_LOG_GROUP CANARY_ALARM_5XX CANARY_ALARM_LATENCY CANARY_ALARM_UNHEALTHY \
CANARY_ALARM_ERRORRATE CANARY_CONTAINER_NAME CANARY_CONTAINER_PORT"

# CloudFormation and CDK use CamelCase output keys (CloudFormation forbids
# underscores in logical ids), so the mapping is explicit rather than derived.
stack_output_key_for() {
  case "$1" in
    CANARY_REGION) printf 'CanaryRegion\n' ;;
    CANARY_PROJECT) printf 'CanaryProject\n' ;;
    CANARY_CLUSTER) printf 'CanaryCluster\n' ;;
    CANARY_ALB_DNS) printf 'CanaryAlbDns\n' ;;
    CANARY_ALB_ARN) printf 'CanaryAlbArn\n' ;;
    CANARY_LISTENER_ARN) printf 'CanaryListenerArn\n' ;;
    CANARY_TG_STABLE) printf 'CanaryTgStable\n' ;;
    CANARY_TG_CANARY) printf 'CanaryTgCanary\n' ;;
    CANARY_SVC_STABLE) printf 'CanarySvcStable\n' ;;
    CANARY_SVC_CANARY) printf 'CanarySvcCanary\n' ;;
    CANARY_TASKDEF_STABLE) printf 'CanaryTaskdefStable\n' ;;
    CANARY_TASKDEF_CANARY) printf 'CanaryTaskdefCanary\n' ;;
    CANARY_ECR_REPO) printf 'CanaryEcrRepo\n' ;;
    CANARY_ECR_URI) printf 'CanaryEcrUri\n' ;;
    CANARY_TABLE) printf 'CanaryTable\n' ;;
    CANARY_LOG_GROUP) printf 'CanaryLogGroup\n' ;;
    CANARY_ALARM_5XX) printf 'CanaryAlarm5xx\n' ;;
    CANARY_ALARM_LATENCY) printf 'CanaryAlarmLatency\n' ;;
    CANARY_ALARM_UNHEALTHY) printf 'CanaryAlarmUnhealthy\n' ;;
    CANARY_ALARM_ERRORRATE) printf 'CanaryAlarmErrorrate\n' ;;
    CANARY_CONTAINER_NAME) printf 'CanaryContainerName\n' ;;
    CANARY_CONTAINER_PORT) printf 'CanaryContainerPort\n' ;;
    *) printf '\n' ;;
  esac
}

RESOLVED_JSON=""

read_terraform() {
  require_tools terraform
  [ -d "$TF_DIR" ] || die "terraform directory not found: $TF_DIR"
  [ -f "${TF_DIR}/terraform.tfstate" ] || [ -d "${TF_DIR}/.terraform" ] ||
    warn "no local state in ${TF_DIR}; if you use a remote backend make sure it is initialised"

  step "reading terraform outputs from ${TF_DIR}"
  local raw
  if ! raw="$(terraform -chdir="$TF_DIR" output -json canary_env 2>/dev/null)"; then
    die "could not read the canary_env output. Has 'terraform apply' run in ${TF_DIR}?"
  fi
  [ -n "$raw" ] && [ "$raw" != "null" ] || die "the canary_env output is empty"
  RESOLVED_JSON="$raw"
}

read_stack() {
  require_tools aws
  step "reading ${FLAVOUR} stack outputs from ${STACK_NAME}"

  local outputs
  if ! outputs="$(awsx cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query 'Stacks[0].Outputs' \
    --output json 2>/dev/null)"; then
    die "stack ${STACK_NAME} not found in $(canary_region). Deploy it first, or pass --stack NAME."
  fi

  # Turn [{OutputKey,OutputValue}] into {Key: Value}, then rename to the contract.
  local flat
  flat="$(printf '%s' "$outputs" | jq 'map({(.OutputKey): .OutputValue}) | add // {}')"

  local result="{}" key stack_key value
  for key in $CONTRACT_KEYS; do
    stack_key="$(stack_output_key_for "$key")"
    [ -n "$stack_key" ] || continue
    value="$(printf '%s' "$flat" | jq -r --arg k "$stack_key" '.[$k] // ""')"
    result="$(printf '%s' "$result" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')"
  done
  RESOLVED_JSON="$result"
}

case "$FLAVOUR" in
  terraform) read_terraform ;;
  cloudformation | cdk) read_stack ;;
esac

# The region output can be a CloudFormation pseudo value; prefer the caller's.
RESOLVED_JSON="$(printf '%s' "$RESOLVED_JSON" |
  jq --arg region "$(canary_region)" '
    .CANARY_REGION = (if (.CANARY_REGION // "") == "" then $region else .CANARY_REGION end)
    | .CANARY_CONTAINER_NAME = (if (.CANARY_CONTAINER_NAME // "") == "" then "app" else .CANARY_CONTAINER_NAME end)
    | .CANARY_CONTAINER_PORT = (if (.CANARY_CONTAINER_PORT // "") == "" then "8080" else .CANARY_CONTAINER_PORT end)
  ')"

# Anything essential still blank means the stack is incomplete.
REQUIRED_KEYS="CANARY_CLUSTER CANARY_ALB_DNS CANARY_LISTENER_ARN CANARY_TG_STABLE CANARY_TG_CANARY CANARY_SVC_STABLE CANARY_SVC_CANARY"
MISSING=""
for key in $REQUIRED_KEYS; do
  value="$(printf '%s' "$RESOLVED_JSON" | jq -r --arg k "$key" '.[$k] // ""')"
  if [ -z "$value" ] || [ "$value" = "None" ]; then
    MISSING="${MISSING} ${key}"
  fi
done
[ -z "$MISSING" ] || die "these outputs came back empty:${MISSING}"

render_exports() {
  local key value
  for key in $CONTRACT_KEYS; do
    value="$(printf '%s' "$RESOLVED_JSON" | jq -r --arg k "$key" '.[$k] // ""')"
    printf 'export %s=%s\n' "$key" "$(printf '%q' "$value")"
  done
}

render_env_file() {
  local key value
  printf '# Generated by scripts/load-env.sh from the %s outputs on %s\n' \
    "$FLAVOUR" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '# Regenerate after every infrastructure change. Safe to delete.\n'
  for key in $CONTRACT_KEYS; do
    value="$(printf '%s' "$RESOLVED_JSON" | jq -r --arg k "$key" '.[$k] // ""')"
    printf '%s=%s\n' "$key" "$value"
  done
}

if [ "$PRINT_ONLY" = true ]; then
  printf '%s\n' "$RESOLVED_JSON" | jq .
  exit 0
fi

if [ "$EXPORT_ONLY" = true ]; then
  render_exports
  exit 0
fi

render_env_file >"$ENV_FILE"

if [ "$QUIET" != true ]; then
  ok "wrote ${ENV_FILE}"
  hr
  printf '%s' "$RESOLVED_JSON" | jq -r '
    "  cluster    \(.CANARY_CLUSTER)",
    "  dashboard  http://\(.CANARY_ALB_DNS)",
    "  services   \(.CANARY_SVC_STABLE) | \(.CANARY_SVC_CANARY)",
    "  registry   \(.CANARY_ECR_URI)",
    "  table      \(.CANARY_TABLE)"
  ' >&2
  hr
  info "the other scripts pick this up automatically:"
  info "  ./scripts/status.sh"
  info "  ./scripts/canary-deploy.sh --tag v2"
fi
