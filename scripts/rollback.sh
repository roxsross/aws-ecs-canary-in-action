#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Emergency exit. Sends every request back to the stable track.
#
#   ./scripts/rollback.sh                 # traffic only: fastest, no deployment
#   ./scripts/rollback.sh --previous      # also roll stable back one revision
#   ./scripts/rollback.sh --to canary-lab-stable:7
#
# Traffic rollback is instant because it only rewrites the listener weights: no
# image pull, no task start, no waiting. Rolling the task definition back is the
# second step, for when the bad version already reached the stable service.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

REVERT_TASKDEF=""
USE_PREVIOUS=false
KEEP_CANARY=false

usage() {
  print_header_help "${BASH_SOURCE[0]}"
  cat <<'EOF'
Options
  --previous        Roll the stable service back to the previous revision
  --to TASKDEF      Roll the stable service back to this family:revision or ARN
  --keep-canary     Leave the canary tasks running (for a post mortem)
  --yes             Do not ask for confirmation
  --region REGION   AWS region
  -h, --help        This help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --previous) USE_PREVIOUS=true; shift ;;
    --to) REVERT_TASKDEF="$2"; shift 2 ;;
    --keep-canary) KEEP_CANARY=true; shift ;;
    --yes | -y) export CANARY_ASSUME_YES=true; shift ;;
    --region) export AWS_REGION="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

require_tools aws jq
require_canary_env \
  CANARY_CLUSTER CANARY_LISTENER_ARN CANARY_TG_STABLE CANARY_TG_CANARY \
  CANARY_SVC_STABLE CANARY_SVC_CANARY CANARY_TASKDEF_STABLE

BEFORE="$(alb_weights)"
step "current state"
info "split      stable=${BEFORE%% *} canary=${BEFORE##* }"
info "stable     $(ecs_current_image "$CANARY_SVC_STABLE" 2>/dev/null || printf 'unknown')"
info "canary     $(ecs_desired_count "$CANARY_SVC_CANARY") task(s) desired"

if [ "${BEFORE##* }" = "0" ] && [ "$USE_PREVIOUS" != true ] && [ -z "$REVERT_TASKDEF" ]; then
  ok "the canary already receives no traffic, nothing to roll back"
  if [ "$(ecs_desired_count "$CANARY_SVC_CANARY")" != "0" ] && [ "$KEEP_CANARY" != true ]; then
    step "scaling the idle canary to zero"
    ecs_scale "$CANARY_SVC_CANARY" 0
    ok "done"
  fi
  exit 0
fi

# ---------------------------------------------------------- traffic rollback --

step "sending all traffic to stable"
alb_set_weights 100 0
ok "listener is 100% stable"
print_split_bar 100 0

if [ "$KEEP_CANARY" != true ]; then
  step "scaling the canary to zero"
  ecs_scale "$CANARY_SVC_CANARY" 0
  ok "canary service scaled to 0"
else
  warn "canary tasks left running on purpose (--keep-canary)"
  info "they take no traffic, but you can still reach them:"
  info "  curl -s '$(app_url)/api/whoami?track=canary' | jq"
fi

# -------------------------------------------------- task definition rollback --

if [ "$USE_PREVIOUS" = true ] && [ -z "$REVERT_TASKDEF" ]; then
  step "looking for the previous revision of ${CANARY_TASKDEF_STABLE}"
  CURRENT_TASKDEF="$(ecs_task_definition "$CANARY_SVC_STABLE")"
  CURRENT_REVISION="${CURRENT_TASKDEF##*:}"

  REVISIONS="$(awsx ecs list-task-definitions \
    --family-prefix "$CANARY_TASKDEF_STABLE" \
    --status ACTIVE \
    --sort DESC \
    --query 'taskDefinitionArns' \
    --output json)"

  REVERT_TASKDEF="$(printf '%s' "$REVISIONS" | jq -r --arg current "$CURRENT_TASKDEF" '
    map(select(. != $current)) | first // ""
  ')"

  if [ -z "$REVERT_TASKDEF" ]; then
    warn "no earlier revision of ${CANARY_TASKDEF_STABLE} exists, leaving revision ${CURRENT_REVISION} in place"
  else
    info "current  revision ${CURRENT_REVISION}"
    info "reverting to ${REVERT_TASKDEF##*/}"
  fi
fi

if [ -n "$REVERT_TASKDEF" ]; then
  REVERT_IMAGE="$(awsx ecs describe-task-definition --task-definition "$REVERT_TASKDEF" \
    --query "taskDefinition.containerDefinitions[?name=='${CANARY_CONTAINER_NAME:-app}'].image | [0]" \
    --output text 2>/dev/null || printf 'unknown')"
  warn "this redeploys the stable service with image ${REVERT_IMAGE}"
  if confirm "roll the stable service back to ${REVERT_TASKDEF##*/}?"; then
    ecs_set_task_definition "$CANARY_SVC_STABLE" "$REVERT_TASKDEF"
    ecs_wait_stable "$CANARY_SVC_STABLE" || warn "the stable service is still settling; check ./scripts/status.sh"
    ok "stable service is back on ${REVERT_TASKDEF##*/}"
  else
    info "skipped the task definition rollback; traffic is still 100% stable"
  fi
fi

hr
ok "rollback done"
info "verify:     ./scripts/status.sh"
info "dashboard:  $(app_url)"
