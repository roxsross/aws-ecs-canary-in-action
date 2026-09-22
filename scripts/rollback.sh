#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Emergency exit: send the service back to the last known good revision.
#
#   ./scripts/rollback.sh                 # revert to the previous task definition
#   ./scripts/rollback.sh --to canary-lab-app:7
#
# With ECS's native canary strategy there is no "traffic weight" to reset by
# hand: if a rollout is IN_PROGRESS, ECS is already watching the alarms below
# and will roll itself back the moment one fires. This script is for the two
# cases that need a human:
#   - you want to cut a healthy-looking rollout short, on your own judgement
#   - a bad revision already reached COMPLETED and is serving 100% of traffic
# Either way, it redeploys the previous task definition through the same
# canary strategy, so even the rollback itself ramps up gradually and can be
# watched.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

REVERT_TASKDEF=""
POLL=15
TIMEOUT=1800

usage() {
  print_header_help "${BASH_SOURCE[0]}"
  cat <<'EOF'
Options
  --to TASKDEF      Roll back to this family:revision or ARN (default: previous revision)
  --poll SECONDS     Rollout status poll interval (default: 15)
  --timeout SECONDS  Give up waiting after this long (default: 1800)
  --yes             Do not ask for confirmation
  --region REGION   AWS region
  -h, --help        This help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --to) REVERT_TASKDEF="$2"; shift 2 ;;
    --poll) POLL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --yes | -y) export CANARY_ASSUME_YES=true; shift ;;
    --region) export AWS_REGION="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

require_tools aws jq
require_canary_env CANARY_CLUSTER CANARY_SERVICE CANARY_TASKDEF_FAMILY

step "current state"
CURRENT_TASKDEF="$(ecs_task_definition)"
CURRENT_STATE="$(ecs_rollout_state)"
info "image         $(ecs_current_image 2>/dev/null || printf 'unknown')"
info "task def      ${CURRENT_TASKDEF##*/}"
info "rollout state ${CURRENT_STATE}"

if [ "$CURRENT_STATE" = "IN_PROGRESS" ]; then
  warn "a rollout is in progress. ECS is already watching the alarms and will roll"
  warn "itself back automatically if one fires. Continuing will instead redeploy the"
  warn "revision below over whatever is running now."
fi

if [ -z "$REVERT_TASKDEF" ]; then
  step "looking for the previous revision of ${CANARY_TASKDEF_FAMILY}"
  REVISIONS="$(awsx ecs list-task-definitions \
    --family-prefix "$CANARY_TASKDEF_FAMILY" \
    --status ACTIVE \
    --sort DESC \
    --query 'taskDefinitionArns' \
    --output json)"

  REVERT_TASKDEF="$(printf '%s' "$REVISIONS" | jq -r --arg current "$CURRENT_TASKDEF" '
    map(select(. != $current)) | first // ""
  ')"

  [ -n "$REVERT_TASKDEF" ] || die "no earlier revision of ${CANARY_TASKDEF_FAMILY} exists"
fi

REVERT_IMAGE="$(awsx ecs describe-task-definition --task-definition "$REVERT_TASKDEF" \
  --query "taskDefinition.containerDefinitions[?name=='${CANARY_CONTAINER_NAME:-app}'].image | [0]" \
  --output text 2>/dev/null || printf 'unknown')"

info "reverting to  ${REVERT_TASKDEF##*/}"
info "image         ${REVERT_IMAGE}"
confirm "roll ${CANARY_SERVICE} back to ${REVERT_TASKDEF##*/}?" || die "aborted"

step "redeploying ${REVERT_TASKDEF##*/}"
awsx ecs update-service \
  --cluster "$CANARY_CLUSTER" \
  --service "$CANARY_SERVICE" \
  --task-definition "$REVERT_TASKDEF" \
  --force-new-deployment >/dev/null
ok "update-service called; ECS is rolling it out through the same canary strategy"

hr
if ! ecs_wait_rollout "$REVERT_TASKDEF" "$TIMEOUT" "$POLL"; then
  err "the rollback rollout did not complete; check ./scripts/status.sh"
  exit 1
fi

hr
ok "rollback done: ${REVERT_IMAGE} is live"
info "verify:     ./scripts/status.sh"
info "dashboard:  $(app_url)"
