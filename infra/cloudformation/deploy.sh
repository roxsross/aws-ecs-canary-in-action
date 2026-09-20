#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Create or update the CloudFormation flavour of the canary lab.
#
#   cp params.example.json params.json   # then edit vpc + subnets
#   ./deploy.sh
#   ./deploy.sh --keep-weights           # safe to run mid rollout
#   ./deploy.sh --delete
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/canary-stack.yaml"

STACK_NAME="${STACK_NAME:-canary-lab}"
PARAMS_FILE="${PARAMS_FILE:-${SCRIPT_DIR}/params.json}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
KEEP_WEIGHTS=false
ACTION=deploy

usage() {
  # Reprint the header comment block, stopping at the first line of real code.
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"
  cat <<'EOF'

Options
  --stack-name NAME     Stack name (default: canary-lab, or $STACK_NAME)
  --params-file PATH    Parameter file (default: ./params.json)
  --region REGION       AWS region (default: $AWS_REGION or us-east-1)
  --keep-weights        Read the live listener weights and pass them through, so
                        a stack update does not reset an in-flight rollout
  --delete              Delete the stack and wait for completion
  --validate            Validate the template only
  -h, --help            This help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-name) STACK_NAME="$2"; shift 2 ;;
    --params-file) PARAMS_FILE="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --keep-weights) KEEP_WEIGHTS=true; shift ;;
    --delete) ACTION=delete; shift ;;
    --validate) ACTION=validate; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for tool in aws jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 1; }
done

log() { printf '\033[1;35m▶\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }

stack_exists() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" >/dev/null 2>&1
}

get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null
}

case "$ACTION" in
  validate)
    log "validating $TEMPLATE"
    aws cloudformation validate-template \
      --template-body "file://${TEMPLATE}" --region "$REGION" \
      --query 'Description' --output text
    exit 0
    ;;

  delete)
    warn "deleting stack $STACK_NAME in $REGION. The ALB, ECS services, DynamoDB table and log group go with it."
    read -r -p "type the stack name to confirm: " confirm
    [[ "$confirm" == "$STACK_NAME" ]] || { echo "aborted"; exit 1; }
    aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
    log "waiting for the delete to finish"
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
    log "stack deleted"
    exit 0
    ;;
esac

[[ -f "$PARAMS_FILE" ]] || {
  echo "parameter file not found: $PARAMS_FILE" >&2
  echo "start from the example:  cp ${SCRIPT_DIR}/params.example.json ${PARAMS_FILE}" >&2
  exit 1
}

jq -e 'type == "array"' "$PARAMS_FILE" >/dev/null || {
  echo "$PARAMS_FILE must be a JSON array of {ParameterKey, ParameterValue}" >&2
  exit 1
}

# aws cloudformation deploy takes Key=Value pairs, so translate the standard
# parameter file format into overrides. Written for bash 3.2 (the macOS default),
# hence no mapfile.
OVERRIDES=()
while IFS= read -r pair; do
  [[ -n "$pair" ]] && OVERRIDES+=("$pair")
done < <(jq -r '.[] | "\(.ParameterKey)=\(.ParameterValue)"' "$PARAMS_FILE")

[[ ${#OVERRIDES[@]} -gt 0 ]] || { echo "$PARAMS_FILE has no parameters" >&2; exit 1; }

if [[ "$KEEP_WEIGHTS" == true ]]; then
  if stack_exists; then
    listener_arn="$(get_output CanaryListenerArn)"
    stable_tg="$(get_output CanaryTgStable)"
    canary_tg="$(get_output CanaryTgCanary)"
    if [[ -n "$listener_arn" && "$listener_arn" != "None" ]]; then
      # shellcheck disable=SC2016  # backticks are JMESPath literals, not shell
      weights_json="$(aws elbv2 describe-rules --listener-arn "$listener_arn" --region "$REGION" \
        --query 'Rules[?IsDefault==`true`]|[0].Actions[0].ForwardConfig.TargetGroups' --output json)"
      stable_w="$(echo "$weights_json" | jq -r --arg tg "$stable_tg" '.[] | select(.TargetGroupArn==$tg) | .Weight // 0')"
      canary_w="$(echo "$weights_json" | jq -r --arg tg "$canary_tg" '.[] | select(.TargetGroupArn==$tg) | .Weight // 0')"
      if [[ -n "$stable_w" && -n "$canary_w" ]]; then
        log "preserving the live split: stable=${stable_w} canary=${canary_w}"
        OVERRIDES=("${OVERRIDES[@]}" "StableWeight=${stable_w}" "CanaryWeight=${canary_w}")
      fi
    fi
  else
    warn "--keep-weights ignored: the stack does not exist yet"
  fi
fi

log "deploying stack $STACK_NAME to $REGION"
aws cloudformation deploy \
  --template-file "$TEMPLATE" \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides "${OVERRIDES[@]}" \
  --tags Project="$STACK_NAME" ManagedBy=cloudformation Component=ecs-canary-lab

log "stack outputs"
# shellcheck disable=SC2016  # backticks are JMESPath literals, not shell
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].Outputs[?contains([`AppUrl`,`StableOnlyUrl`,`CanaryOnlyUrl`,`CloudWatchDashboardUrl`,`CanaryCluster`,`CanaryEcrUri`], OutputKey)].[OutputKey,OutputValue]' \
  --output table

cat <<EOF

Next steps
  1. Publish the first image if you have not yet:   ../../scripts/build-push.sh --tag v1
  2. Load the script environment:                   eval "\$(../../scripts/load-env.sh cloudformation --stack $STACK_NAME --export)"
  3. Open the dashboard:                            $(get_output AppUrl)
EOF
