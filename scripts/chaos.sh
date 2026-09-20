#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Breaks a version on purpose, so you can watch the alarms fire and the rollout
# roll itself back.
#
#   ./scripts/chaos.sh --show                        # what is injected right now
#   ./scripts/chaos.sh --break                       # the usual demo: 50% 5xx + 1200ms
#   ./scripts/chaos.sh --fail-rate 100               # every canary request 500s
#   ./scripts/chaos.sh --latency 2000                # blow the latency budget
#   ./scripts/chaos.sh --unhealthy                   # fail the health check itself
#   ./scripts/chaos.sh --clear                       # back to normal
#
# The setting is stored in DynamoDB and polled by every task, so it applies to a
# whole track rather than to whichever container happened to answer. Requests are
# pinned with ?track= so the write always lands on the intended version.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

TRACK="canary"
FAIL_RATE=""
LATENCY=""
UNHEALTHY=""
CLEAR=false
SHOW=false
BREAK=false
BASE_URL=""

usage() {
  print_header_help "${BASH_SOURCE[0]}"
  cat <<'EOF'
Options
  --track NAME       stable or canary (default: canary)
  --fail-rate N      Percentage of requests answered with a 500 (0-100)
  --latency MS       Extra milliseconds added to every response
  --unhealthy        Answer /api/health with 503 so the ALB drops the targets
  --healthy          Undo --unhealthy
  --break            Shortcut for --fail-rate 50 --latency 1200
  --clear            Remove all injected faults from both tracks
  --show             Print the current state and exit
  --url URL          Base URL (default: the ALB from .canary.env)
  --token TOKEN      X-Admin-Token, if the stack sets one
  -h, --help         This help
EOF
}

ADMIN_TOKEN="${CANARY_ADMIN_TOKEN:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --track) TRACK="$2"; shift 2 ;;
    --fail-rate) FAIL_RATE="$2"; shift 2 ;;
    --latency) LATENCY="$2"; shift 2 ;;
    --unhealthy) UNHEALTHY=true; shift ;;
    --healthy) UNHEALTHY=false; shift ;;
    --break) BREAK=true; shift ;;
    --clear) CLEAR=true; shift ;;
    --show) SHOW=true; shift ;;
    --url) BASE_URL="$2"; shift 2 ;;
    --token) ADMIN_TOKEN="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

require_tools curl jq

case "$TRACK" in
  stable | canary) ;;
  *) die "--track must be stable or canary" ;;
esac

if [ -z "$BASE_URL" ]; then
  load_canary_env || true
  if [ -n "${CANARY_ALB_DNS:-}" ]; then
    BASE_URL="http://${CANARY_ALB_DNS}"
  else
    BASE_URL="http://localhost:8080"
    info "no .canary.env found, falling back to ${BASE_URL}"
  fi
fi
BASE_URL="${BASE_URL%/}"

curl_args() {
  printf '%s\n' "-sS" "--max-time" "15"
  if [ -n "$ADMIN_TOKEN" ]; then
    printf '%s\n' "-H" "X-Admin-Token: ${ADMIN_TOKEN}"
  fi
}

CURL_OPTS=()
while IFS= read -r opt; do
  CURL_OPTS+=("$opt")
done < <(curl_args)

if [ "$BREAK" = true ]; then
  [ -n "$FAIL_RATE" ] || FAIL_RATE=50
  [ -n "$LATENCY" ] || LATENCY=1200
fi

show_state() {
  local response
  # Pinned to a track so the read comes from a task of that version.
  response="$(curl "${CURL_OPTS[@]}" "${BASE_URL}/api/chaos?track=${TRACK}")" ||
    die "could not reach ${BASE_URL}. Is the stack up, and does the security group allow your IP?"
  printf '%s' "$response" | jq -r '
    "  stable    fail=\(.chaos.stable.failRate)%  latency=\(.chaos.stable.latencyMs)ms  unhealthy=\(.chaos.stable.unhealthy)",
    "  canary    fail=\(.chaos.canary.failRate)%  latency=\(.chaos.canary.latencyMs)ms  unhealthy=\(.chaos.canary.unhealthy)"
  ' >&2
}

if [ "$SHOW" = true ]; then
  step "injected faults at ${BASE_URL}"
  show_state
  exit 0
fi

if [ "$CLEAR" = true ]; then
  step "clearing injected faults on both tracks"
  curl "${CURL_OPTS[@]}" -X DELETE "${BASE_URL}/api/chaos" >/dev/null ||
    die "could not clear the faults"
  ok "cleared"
  show_state
  hr
  info "the canary target group becomes healthy again within a couple of health checks"
  info "alarms return to OK once a clean period is evaluated"
  exit 0
fi

if [ -z "$FAIL_RATE" ] && [ -z "$LATENCY" ] && [ -z "$UNHEALTHY" ]; then
  err "nothing to inject"
  info "try --break, or pick --fail-rate / --latency / --unhealthy"
  usage >&2
  exit 2
fi

PAYLOAD="$(
  jq -nc \
    --arg track "$TRACK" \
    --arg failRate "${FAIL_RATE:-}" \
    --arg latencyMs "${LATENCY:-}" \
    --arg unhealthy "${UNHEALTHY:-}" \
    '{track: $track}
     + (if $failRate  != "" then {failRate:  ($failRate  | tonumber)} else {} end)
     + (if $latencyMs != "" then {latencyMs: ($latencyMs | tonumber)} else {} end)
     + (if $unhealthy != "" then {unhealthy: ($unhealthy == "true")} else {} end)'
)"

step "injecting into the ${TRACK} track"
info "payload ${PAYLOAD}"

RESPONSE="$(curl "${CURL_OPTS[@]}" -X POST "${BASE_URL}/api/chaos?track=${TRACK}" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD")" || die "the request failed"

if [ "$(printf '%s' "$RESPONSE" | jq -r '.ok // false')" != "true" ]; then
  err "the app rejected it: $(printf '%s' "$RESPONSE" | jq -r '.error // "unknown error"')"
  info "if the stack sets ADMIN_TOKEN, pass it with --token"
  exit 1
fi

ok "applied to every ${TRACK} task"
show_state

hr
info "now watch it land:"
info "  ./scripts/status.sh --watch"
info "  ./scripts/traffic-gen.sh --rps 10 --duration 120"
if [ "$TRACK" = "canary" ]; then
  info "alarms usually flip to ALARM within a period or two (60s by default)"
  info "a rollout running in another terminal will roll itself back"
fi
