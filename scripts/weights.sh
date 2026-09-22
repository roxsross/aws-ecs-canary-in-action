#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Shows the traffic split.
#
#   ./scripts/weights.sh                              # AWS: read-only status
#   ./scripts/weights.sh --target local               # the docker compose mini-alb
#   ./scripts/weights.sh --target local --canary 25    # local only: set the split by hand
#
# On AWS, traffic weighting is owned entirely by ECS's native canary strategy
# (deployment_configuration in infra/terraform/ecs.tf): there is no listener
# weight left to set by hand anymore, so this only reads and reports what ECS
# is doing. To change how traffic shifts, edit var.canary_percent /
# var.canary_bake_time_in_minutes and re-apply, then start a rollout with
# ./scripts/canary-deploy.sh.
#
# local/ is unaffected: the docker compose mini-alb still takes explicit
# weights, exactly as before, since it doesn't use ECS at all.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

STABLE=""
CANARY=""
TARGET="aws"
LOCAL_URL="${CANARY_LOCAL_ALB:-http://localhost:8080}"

usage() {
  print_header_help "${BASH_SOURCE[0]}"
  cat <<'EOF'
Options
  --target WHERE    aws (default, read-only) or local for the docker compose mini-alb
  --canary N        local only: canary weight. Alone, it means N% and stable becomes 100-N
  --stable N        local only: stable weight (use together with --canary for raw weights)
  --url URL         mini-alb base URL (default: http://localhost:8080)
  --region REGION   AWS region
  -h, --help        This help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --canary) CANARY="$2"; shift 2 ;;
    --stable) STABLE="$2"; shift 2 ;;
    --canary-percent) CANARY="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --url) LOCAL_URL="$2"; shift 2 ;;
    --region) export AWS_REGION="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

is_number() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

for value in "$STABLE" "$CANARY"; do
  if [ -n "$value" ] && ! is_number "$value"; then
    die "weights must be whole numbers, got '${value}'"
  fi
done

# --canary on its own is read as a percentage.
if [ -n "$CANARY" ] && [ -z "$STABLE" ]; then
  [ "$CANARY" -le 100 ] || die "--canary on its own is a percentage, so keep it at 100 or below"
  STABLE=$((100 - CANARY))
fi

# ------------------------------------------------------------------- local ----

if [ "$TARGET" = "local" ]; then
  require_tools curl jq

  if [ -z "$CANARY" ]; then
    step "current split on the local mini-alb"
    curl -sf "${LOCAL_URL}/_alb/status" |
      jq -r '"  weights   stable=\(.weights.stable) canary=\(.weights.canary)   (\(.weights.stablePercent)% / \(.weights.canaryPercent)%)",
             (.targets[] | "  target    \(.name)\thealthy=\(.healthy)\trequests=\(.requests)")' >&2
    exit 0
  fi

  step "shifting the local split to stable=${STABLE} canary=${CANARY}"
  RESPONSE="$(curl -sf -X POST "${LOCAL_URL}/_alb/weights" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --argjson s "$STABLE" --argjson c "$CANARY" '{stable: $s, canary: $c}')")" ||
    die "could not reach the mini-alb at ${LOCAL_URL}. Is docker compose up?"

  printf '%s' "$RESPONSE" | jq -r '"  weights   stable=\(.weights.stable) canary=\(.weights.canary)   (\(.weights.stablePercent)% / \(.weights.canaryPercent)%)"' >&2
  print_split_bar "$STABLE" "$CANARY"
  exit 0
fi

[ "$TARGET" = "aws" ] || die "unknown --target '${TARGET}' (use aws or local)"

if [ -n "$STABLE" ] || [ -n "$CANARY" ]; then
  die "AWS traffic weighting is owned by ECS's native canary strategy; there is no weight to set by hand. Start a rollout with ./scripts/canary-deploy.sh instead."
fi

# --------------------------------------------------------------------- aws ----

require_tools aws jq
require_canary_env CANARY_CLUSTER CANARY_SERVICE CANARY_TG_PRIMARY CANARY_TG_ALTERNATE

step "current rollout state"
STATE="$(ecs_rollout_state)"
WEIGHTS="$(alb_production_weights 2>/dev/null || printf '0 0')"
info "rollout state    ${STATE}"
info "canary strategy  $(canary_deployment_summary)"
info "healthy          primary=$(tg_healthy_count "$CANARY_TG_PRIMARY") alternate=$(tg_healthy_count "$CANARY_TG_ALTERNATE")"
print_split_bar "${WEIGHTS%% *}" "${WEIGHTS##* }" 40 primary alternate

if [ "$STATE" = "IN_PROGRESS" ]; then
  info ""
  info "a canary rollout is shifting traffic right now:  ./scripts/status.sh --watch"
fi
