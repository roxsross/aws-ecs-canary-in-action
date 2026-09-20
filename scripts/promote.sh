#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Promotes a version to the stable track and parks the canary.
#
#   ./scripts/promote.sh --tag v2
#   ./scripts/promote.sh --from-canary     # promote whatever the canary runs now
#
# Use this after `canary-deploy.sh --no-promote`, when you wanted to sit at 100%
# canary traffic for a while before making it the new normal.
#
# The stable service gets the image, the listener goes back to 100% stable and
# the canary scales to zero. Users notice nothing: they were already being served
# this version through the canary target group.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

TAG=""
IMAGE=""
FROM_CANARY=false
KEEP_CANARY_RUNNING=false

usage() {
  print_header_help "${BASH_SOURCE[0]}"
  cat <<'EOF'
Options
  --tag TAG          Tag to promote (resolved against the ECR repository)
  --image URI        Full image reference instead of --tag
  --from-canary      Promote the image the canary service is running right now
  --keep-canary      Do not scale the canary down afterwards
  --yes              Do not ask for confirmation
  --region REGION    AWS region
  -h, --help         This help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --from-canary) FROM_CANARY=true; shift ;;
    --keep-canary) KEEP_CANARY_RUNNING=true; shift ;;
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

if [ "$FROM_CANARY" = true ]; then
  IMAGE="$(ecs_current_image "$CANARY_SVC_CANARY")" ||
    die "could not read the image the canary service is running"
  [ -n "$IMAGE" ] && [ "$IMAGE" != "None" ] || die "the canary service has no image to promote"
fi

if [ -z "$IMAGE" ]; then
  [ -n "$TAG" ] || {
    err "pass --tag, --image or --from-canary"
    usage >&2
    exit 2
  }
  [ -n "${CANARY_ECR_URI:-}" ] || die "CANARY_ECR_URI is missing; re-run scripts/load-env.sh"
  IMAGE="${CANARY_ECR_URI}:${TAG}"
fi

CURRENT_STABLE_IMAGE="$(ecs_current_image "$CANARY_SVC_STABLE" 2>/dev/null || printf 'unknown')"
WEIGHTS="$(alb_weights)"

step "promotion plan"
info "stable now   ${CURRENT_STABLE_IMAGE}"
info "promoting    ${IMAGE}"
info "split now    stable=${WEIGHTS%% *} canary=${WEIGHTS##* }"

if [ "$CURRENT_STABLE_IMAGE" = "$IMAGE" ]; then
  ok "the stable service already runs this image"
  step "normalising the split and parking the canary"
  alb_set_weights 100 0
  [ "$KEEP_CANARY_RUNNING" = true ] || ecs_scale "$CANARY_SVC_CANARY" 0
  ok "done"
  exit 0
fi

confirm "promote ${IMAGE} to stable?" || die "aborted"

hr
step "1/4  registering a stable task definition with the new image"
NEW_TASKDEF="$(ecs_register_with_image "$CANARY_TASKDEF_STABLE" "$IMAGE")"
ok "registered ${NEW_TASKDEF##*/}"

step "2/4  rolling the stable service"
ecs_set_task_definition "$CANARY_SVC_STABLE" "$NEW_TASKDEF"
if ! ecs_wait_stable "$CANARY_SVC_STABLE"; then
  err "the stable service did not stabilise"
  info "traffic has not been moved. Investigate, then either retry or run:"
  info "  ./scripts/rollback.sh --previous"
  exit 1
fi

if ! tg_wait_healthy "$CANARY_TG_STABLE" 1 300; then
  err "the promoted stable tasks never became healthy"
  info "traffic has not been moved yet, so the canary is still serving users"
  exit 1
fi

step "3/4  returning traffic to the stable target group"
alb_set_weights 100 0
ok "listener is 100% stable"
print_split_bar 100 0

step "4/4  parking the canary"
if [ "$KEEP_CANARY_RUNNING" = true ]; then
  warn "canary left running (--keep-canary)"
else
  ecs_scale "$CANARY_SVC_CANARY" 0
  ok "canary scaled to 0"
fi

hr
ok "${IMAGE} is now the stable version"
info "verify:     ./scripts/status.sh"
info "dashboard:  $(app_url)"
