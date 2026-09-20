#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Reads and shifts the traffic split. This is the single knob the whole canary
# flow turns: the ALB listener's default rule forwards to two target groups with
# weights, and moving those weights moves real user traffic.
#
#   ./scripts/weights.sh                          # show the current split
#   ./scripts/weights.sh --canary 5               # 5% to the canary
#   ./scripts/weights.sh --canary 100             # everything to the canary
#   ./scripts/weights.sh --stable 90 --canary 10  # explicit weights
#   ./scripts/weights.sh --target local --canary 25   # the docker compose mini-alb
#
# Weights are relative, not percentages: 90/10 and 9/1 are the same split. The
# script normalises to 100 when you use --canary on its own.
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
  --canary N        Canary weight. Alone, it means N% and stable becomes 100-N
  --stable N        Stable weight (use together with --canary for raw weights)
  --target WHERE    aws (default) or local for the docker compose mini-alb
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

# --------------------------------------------------------------------- aws ----

require_tools aws jq
require_canary_env CANARY_LISTENER_ARN CANARY_TG_STABLE CANARY_TG_CANARY

if [ -z "$CANARY" ]; then
  step "current split on the listener"
  CURRENT="$(alb_weights)"
  CURRENT_STABLE="${CURRENT%% *}"
  CURRENT_CANARY="${CURRENT##* }"
  info "weights   stable=${CURRENT_STABLE} canary=${CURRENT_CANARY}"
  print_split_bar "$CURRENT_STABLE" "$CURRENT_CANARY"
  info "healthy   stable=$(tg_healthy_count "$CANARY_TG_STABLE") canary=$(tg_healthy_count "$CANARY_TG_CANARY")"
  exit 0
fi

BEFORE="$(alb_weights)"
step "shifting traffic: stable=${STABLE} canary=${CANARY}"
info "before    stable=${BEFORE%% *} canary=${BEFORE##* }"

# A weight above zero with no healthy targets behind it means 5xx for that share
# of traffic, so say it out loud rather than letting the demo fail quietly.
if [ "$CANARY" -gt 0 ]; then
  HEALTHY="$(tg_healthy_count "$CANARY_TG_CANARY")"
  if [ "$HEALTHY" -eq 0 ]; then
    warn "the canary target group has no healthy targets right now"
    warn "sending it ${CANARY} weight will return 503 for that share of requests"
    confirm "shift anyway?" || die "aborted"
  fi
fi

alb_set_weights "$STABLE" "$CANARY"
AFTER="$(alb_weights)"
ok "listener updated"
info "after     stable=${AFTER%% *} canary=${AFTER##* }"
print_split_bar "${AFTER%% *}" "${AFTER##* }"
info "watch it live at $(app_url)"
