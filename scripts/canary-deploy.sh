#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Progressive canary rollout with automatic rollback.
#
#   ./scripts/canary-deploy.sh --tag v2
#   ./scripts/canary-deploy.sh --tag v2 --steps 10,50,100 --bake 120
#   ./scripts/canary-deploy.sh --tag v2 --no-promote     # stop at 100%, promote later
#
# What happens, in order:
#   1. register a canary task definition pointing at the new image
#   2. scale the canary service up and wait for healthy targets
#   3. shift the listener weights one step at a time (5, 25, 50, 100 by default)
#   4. between steps, bake: watch the canary CloudWatch alarms
#   5. any alarm in ALARM aborts everything and shifts traffic back to stable
#   6. on success, promote: the stable service takes the new image and the canary
#      scales back to zero, ready for the next release
#
# Interrupting with Ctrl-C rolls traffic back to stable, on the principle that a
# half finished rollout should not be left in place.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

TAG=""
IMAGE=""
STEPS="5,25,50,100"
BAKE=90
POLL=15
CANARY_TASKS=1
PROMOTE=true
RESET_ALARMS=true
DRY_RUN=false
ROLLOUT_ACTIVE=false

usage() {
  print_header_help "${BASH_SOURCE[0]}"
  cat <<'EOF'
Options
  --tag TAG          Image tag to roll out (resolved against the ECR repository)
  --image URI        Full image reference instead of --tag
  --steps LIST       Canary percentages, comma separated (default: 5,25,50,100)
  --bake SECONDS     Seconds to watch the alarms at each step (default: 90)
  --poll SECONDS     Alarm poll interval while baking (default: 15)
  --canary-tasks N   Tasks to run for the canary (default: 1)
  --no-promote       Stop at the last step without promoting to stable
  --no-reset-alarms  Do not clear stale alarm state before starting
  --yes              Do not ask for confirmation
  --dry-run          Print the plan and exit
  --region REGION    AWS region
  -h, --help         This help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --steps) STEPS="$2"; shift 2 ;;
    --bake) BAKE="$2"; shift 2 ;;
    --poll) POLL="$2"; shift 2 ;;
    --canary-tasks) CANARY_TASKS="$2"; shift 2 ;;
    --no-promote) PROMOTE=false; shift ;;
    --no-reset-alarms) RESET_ALARMS=false; shift ;;
    --yes | -y) export CANARY_ASSUME_YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --region) export AWS_REGION="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

require_tools aws jq
require_canary_env \
  CANARY_CLUSTER CANARY_LISTENER_ARN CANARY_TG_STABLE CANARY_TG_CANARY \
  CANARY_SVC_STABLE CANARY_SVC_CANARY CANARY_TASKDEF_STABLE CANARY_TASKDEF_CANARY

[ -n "$TAG" ] || [ -n "$IMAGE" ] || {
  err "pass --tag v2 (or --image with a full reference)"
  usage >&2
  exit 2
}

if [ -z "$IMAGE" ]; then
  [ -n "${CANARY_ECR_URI:-}" ] || die "CANARY_ECR_URI is missing; re-run scripts/load-env.sh"
  IMAGE="${CANARY_ECR_URI}:${TAG}"
fi

# Validate the steps up front: a typo here would otherwise surface halfway through.
STEP_LIST="$(printf '%s' "$STEPS" | tr ',' ' ')"
for candidate in $STEP_LIST; do
  case "$candidate" in
    '' | *[!0-9]*) die "--steps must be whole numbers, got '${candidate}'" ;;
  esac
  [ "$candidate" -ge 1 ] && [ "$candidate" -le 100 ] ||
    die "each step must be between 1 and 100, got '${candidate}'"
done

# ------------------------------------------------------------------ rollback --

rollback() {
  local reason="$1"
  hr
  err "ROLLBACK: ${reason}"
  step "shifting all traffic back to stable"
  alb_set_weights 100 0
  ok "listener is 100% stable"
  step "scaling the canary back to zero"
  ecs_scale "$CANARY_SVC_CANARY" 0
  ok "canary service scaled to 0"
  hr
  info "the stable version never changed, so users are on the last known good release"
  info "look at what happened:"
  info "  ./scripts/status.sh"
  info "  aws logs tail ${CANARY_LOG_GROUP:-/ecs/canary-lab} --since 15m --filter-pattern canary"
}

on_interrupt() {
  trap - INT TERM
  if [ "$ROLLOUT_ACTIVE" = true ]; then
    warn "interrupted mid rollout"
    rollback "interrupted by the operator"
  fi
  exit 130
}
trap on_interrupt INT TERM

# ------------------------------------------------------------------ preflight --

step "preflight"
CURRENT_WEIGHTS="$(alb_weights)"
CURRENT_STABLE_IMAGE="$(ecs_current_image "$CANARY_SVC_STABLE" 2>/dev/null || printf 'unknown')"
STABLE_DESIRED="$(ecs_desired_count "$CANARY_SVC_STABLE")"

info "cluster          ${CANARY_CLUSTER}"
info "new image        ${IMAGE}"
info "stable now       ${CURRENT_STABLE_IMAGE} (${STABLE_DESIRED} task(s))"
info "current split    stable=${CURRENT_WEIGHTS%% *} canary=${CURRENT_WEIGHTS##* }"
info "steps            ${STEPS}  (bake ${BAKE}s, poll ${POLL}s)"
info "promote at end   ${PROMOTE}"
info "dashboard        $(app_url)"

# An image that is not in the registry would fail after the weights had moved.
if [ -n "${CANARY_ECR_REPO:-}" ] && [ -n "$TAG" ]; then
  if awsx ecr describe-images \
    --repository-name "$CANARY_ECR_REPO" \
    --image-ids "imageTag=${TAG}" >/dev/null 2>&1; then
    ok "image tag ${TAG} found in ${CANARY_ECR_REPO}"
  else
    err "tag ${TAG} is not in the ${CANARY_ECR_REPO} repository"
    info "build and push it first:  ./scripts/build-push.sh --tag ${TAG}"
    exit 1
  fi
fi

ALARM_NAMES="$(canary_alarm_names)"
[ -n "$ALARM_NAMES" ] || warn "no canary alarms configured: the rollout will not be able to abort itself"

if [ "$DRY_RUN" = true ]; then
  hr
  warn "dry run, nothing was changed"
  exit 0
fi

confirm "start the canary rollout of ${IMAGE}?" || die "aborted"

# --------------------------------------------------- 1. canary task definition --

hr
step "1/5  registering a canary task definition with the new image"
NEW_CANARY_TASKDEF="$(ecs_register_with_image "$CANARY_TASKDEF_CANARY" "$IMAGE")"
ok "registered ${NEW_CANARY_TASKDEF##*/}"

# ------------------------------------------------------- 2. start the canary --

step "2/5  starting ${CANARY_TASKS} canary task(s)"
ROLLOUT_ACTIVE=true
awsx ecs update-service \
  --cluster "$CANARY_CLUSTER" \
  --service "$CANARY_SVC_CANARY" \
  --task-definition "$NEW_CANARY_TASKDEF" \
  --desired-count "$CANARY_TASKS" \
  --force-new-deployment >/dev/null
ok "canary service updated"

if ! ecs_wait_stable "$CANARY_SVC_CANARY"; then
  rollback "the canary service never reached a steady state"
  exit 1
fi

if ! tg_wait_healthy "$CANARY_TG_CANARY" "$CANARY_TASKS" 300; then
  rollback "canary targets never became healthy"
  exit 1
fi

# --------------------------------------------------------- 3. reset alarms ----

if [ "$RESET_ALARMS" = true ] && [ -n "$ALARM_NAMES" ]; then
  step "3/5  clearing stale alarm state"
  reset_canary_alarms
else
  step "3/5  skipping the alarm reset"
fi

# ------------------------------------------------------- 4. shift traffic -----

step "4/5  shifting traffic"
FAILED_ALARMS=""
for percent in $STEP_LIST; do
  stable_weight=$((100 - percent))
  hr
  step "canary at ${percent}%"
  alb_set_weights "$stable_weight" "$percent"
  print_split_bar "$stable_weight" "$percent"

  if [ -z "$ALARM_NAMES" ]; then
    info "no alarms to watch, sleeping ${BAKE}s"
    sleep "$BAKE"
    continue
  fi

  if ! FAILED_ALARMS="$(watch_alarms "$BAKE" "$POLL" "baking at ${percent}%")"; then
    err "alarm fired: $(printf '%s' "$FAILED_ALARMS" | tr '\n' ' ')"
    print_alarm_states
    rollback "CloudWatch alarm(s) breached at ${percent}% canary traffic"
    exit 1
  fi
  ok "canary healthy at ${percent}%"
done

# ------------------------------------------------------------- 5. promote -----

hr
if [ "$PROMOTE" != true ]; then
  step "5/5  stopping before promotion, as asked"
  ok "the canary is serving 100% of traffic and the rollout is still open"
  hr
  info "finish it when you are ready:"
  info "  ./scripts/promote.sh --tag ${TAG:-custom}   # stable takes the new image"
  info "  ./scripts/rollback.sh                       # back to the previous version"
  exit 0
fi

step "5/5  promoting ${IMAGE} to the stable service"
NEW_STABLE_TASKDEF="$(ecs_register_with_image "$CANARY_TASKDEF_STABLE" "$IMAGE")"
info "registered ${NEW_STABLE_TASKDEF##*/}"

ecs_set_task_definition "$CANARY_SVC_STABLE" "$NEW_STABLE_TASKDEF"
if ! ecs_wait_stable "$CANARY_SVC_STABLE"; then
  rollback "the stable service failed to roll out the promoted image"
  exit 1
fi

if ! tg_wait_healthy "$CANARY_TG_STABLE" 1 300; then
  rollback "the promoted stable tasks never became healthy"
  exit 1
fi

step "returning all traffic to the stable target group"
alb_set_weights 100 0
ok "listener is 100% stable, now running the new version"

step "scaling the canary back to zero"
ecs_scale "$CANARY_SVC_CANARY" 0
ROLLOUT_ACTIVE=false
ok "canary idle, ready for the next release"

hr
ok "rollout complete: ${IMAGE} is live on the stable track"
info "verify:  ./scripts/status.sh"
info "dashboard: $(app_url)"
