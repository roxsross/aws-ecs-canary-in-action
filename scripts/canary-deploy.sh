#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Canary rollout using ECS's native deployment strategy.
#
#   ./scripts/canary-deploy.sh --tag v2
#   ./scripts/canary-deploy.sh --tag v2 --version 2.0.0
#
# What happens, in order:
#   1. register a task definition pointing at the new image
#   2. update the service, forcing a new deployment
#   3. ECS creates the "green" revision, scales it up and waits for healthy
#      targets in the alternate target group
#   4. ECS shifts canary_percent of production traffic to it, and bakes for
#      canary_bake_time_in_minutes while watching the alarms below
#   5. if the alarms stay clear, ECS shifts the rest of the traffic at once
#   6. ECS bakes again for bake_time_in_minutes, then terminates the old
#      revision — the deployment is COMPLETED
#   7. if any alarm fires at any point, ECS rolls back on its own: traffic
#      goes back to the old revision and the new one is torn down
#
# All of steps 3-7 are driven by var.canary_percent, var.canary_bake_time_in_minutes,
# var.bake_time_in_minutes and the alarms block in infra/terraform/ecs.tf — this
# script only starts the rollout and polls `rolloutState` to report progress.
# There is no traffic-shifting logic here anymore; ECS owns it.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

TAG=""
IMAGE=""
VERSION=""
POLL=15
TIMEOUT=1800
RESET_ALARMS=true
DRY_RUN=false

usage() {
  print_header_help "${BASH_SOURCE[0]}"
  cat <<'EOF'
Options
  --tag TAG          Image tag to roll out (resolved against the ECR repository)
  --image URI        Full image reference instead of --tag
  --version VERSION  APP_VERSION to report (default: the tag, or unchanged if --image)
  --poll SECONDS     Rollout status poll interval (default: 15)
  --timeout SECONDS  Give up waiting after this long (default: 1800)
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
    --version) VERSION="$2"; shift 2 ;;
    --poll) POLL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
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
  CANARY_CLUSTER CANARY_SERVICE CANARY_TASKDEF_FAMILY CANARY_TG_PRIMARY CANARY_TG_ALTERNATE

[ -n "$TAG" ] || [ -n "$IMAGE" ] || {
  err "pass --tag v2 (or --image with a full reference)"
  usage >&2
  exit 2
}

if [ -z "$IMAGE" ]; then
  [ -n "${CANARY_ECR_URI:-}" ] || die "CANARY_ECR_URI is missing; re-run scripts/load-env.sh"
  IMAGE="${CANARY_ECR_URI}:${TAG}"
fi
[ -n "$VERSION" ] || VERSION="${TAG:-$(ecs_current_image 2>/dev/null || printf 'unknown')}"

# ------------------------------------------------------------------ preflight --

step "preflight"
CURRENT_IMAGE="$(ecs_current_image 2>/dev/null || printf 'unknown')"
CURRENT_STATE="$(ecs_rollout_state)"

info "cluster          ${CANARY_CLUSTER}"
info "service          ${CANARY_SERVICE}"
info "current image    ${CURRENT_IMAGE}"
info "new image        ${IMAGE}"
info "new APP_VERSION  ${VERSION}"
info "rollout state    ${CURRENT_STATE}"
info "dashboard        $(app_url)"

if [ "$CURRENT_STATE" = "IN_PROGRESS" ]; then
  die "a deployment is already in progress. Wait for it, or ./scripts/rollback.sh first."
fi

# An image that is not in the registry would fail well into the rollout.
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
[ -n "$ALARM_NAMES" ] || warn "no canary alarms configured: ECS will not be able to roll this back on its own"

if [ "$DRY_RUN" = true ]; then
  hr
  warn "dry run, nothing was changed"
  exit 0
fi

confirm "start the canary rollout of ${IMAGE}?" || die "aborted"

# ECS ignores an alarm that is already in ALARM state at deployment start, so
# stale state from a previous demo would silently disable the safety net.
if [ "$RESET_ALARMS" = true ] && [ -n "$ALARM_NAMES" ]; then
  step "clearing stale alarm state"
  reset_canary_alarms
fi

hr
step "starting the rollout"
NEW_TASKDEF="$(ecs_start_rollout "$IMAGE" "$VERSION")"
ok "registered ${NEW_TASKDEF##*/} and updated ${CANARY_SERVICE}"

hr
step "ECS is now driving the rollout: green revision, canary traffic shift, bake, promote"
info "canary        $(canary_deployment_summary)"
info "watch it live: ./scripts/status.sh --watch"
info "dashboard:     $(app_url)"
hr

if ! ecs_wait_rollout "$NEW_TASKDEF" "$TIMEOUT" "$POLL"; then
  hr
  err "the rollout did not complete successfully"
  print_alarm_states
  info "check what happened:"
  info "  ./scripts/status.sh"
  info "  aws logs tail ${CANARY_LOG_GROUP:-/ecs/canary-lab} --since 20m"
  info "if traffic is not already back on the old revision:"
  info "  ./scripts/rollback.sh"
  exit 1
fi

hr
ok "rollout complete: ${IMAGE} is live and serving 100% of traffic"
info "verify:    ./scripts/status.sh"
info "dashboard: $(app_url)"
