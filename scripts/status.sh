#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One screen with everything that matters during a rollout: the traffic split,
# both services, target health, alarm state and what the app itself reports.
#
#   ./scripts/status.sh
#   ./scripts/status.sh --watch          # refresh every 10 seconds
#   ./scripts/status.sh --json           # machine readable, for CI summaries
#
# Read only: it changes nothing.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

WATCH=false
INTERVAL=10
AS_JSON=false

usage() {
  print_header_help "${BASH_SOURCE[0]}"
  cat <<'EOF'
Options
  --watch           Refresh until interrupted
  --interval N      Seconds between refreshes (default: 10)
  --json            Print a single JSON document instead
  --region REGION   AWS region
  -h, --help        This help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --watch) WATCH=true; shift ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --json) AS_JSON=true; shift ;;
    --region) export AWS_REGION="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

require_tools aws jq
require_canary_env \
  CANARY_CLUSTER CANARY_LISTENER_ARN CANARY_TG_STABLE CANARY_TG_CANARY \
  CANARY_SVC_STABLE CANARY_SVC_CANARY

collect_json() {
  local weights stable_json canary_json
  weights="$(alb_weights)"
  stable_json="$(ecs_service_json "$CANARY_SVC_STABLE")"
  canary_json="$(ecs_service_json "$CANARY_SVC_CANARY")"

  jq -n \
    --argjson stableWeight "${weights%% *}" \
    --argjson canaryWeight "${weights##* }" \
    --argjson stableService "$stable_json" \
    --argjson canaryService "$canary_json" \
    --argjson stableHealth "$(tg_health_states "$CANARY_TG_STABLE")" \
    --argjson canaryHealth "$(tg_health_states "$CANARY_TG_CANARY")" \
    --argjson alarms "$(alarms_json)" \
    --arg albDns "${CANARY_ALB_DNS:-}" \
    --arg cluster "$CANARY_CLUSTER" \
    --arg region "$(canary_region)" \
    '
    def health_summary:
      { total: length, healthy: ([.[] | select(. == "healthy")] | length), states: . };
    def service_summary:
      {
        name: .serviceName,
        desired: .desiredCount,
        running: .runningCount,
        pending: .pendingCount,
        taskDefinition: (.taskDefinition | split("/") | last),
        deployments: ([.deployments[]? | {status, rollout: .rolloutState, desired: .desiredCount, running: .runningCount}])
      };
    ($stableWeight + $canaryWeight) as $total
    | {
        region: $region,
        cluster: $cluster,
        dashboard: ("http://" + $albDns),
        split: {
          stableWeight: $stableWeight,
          canaryWeight: $canaryWeight,
          stablePercent: (if $total > 0 then (100 * $stableWeight / $total) else 0 end),
          canaryPercent: (if $total > 0 then (100 * $canaryWeight / $total) else 0 end)
        },
        services: {
          stable: ($stableService | service_summary),
          canary: ($canaryService | service_summary)
        },
        targets: {
          stable: ($stableHealth | health_summary),
          canary: ($canaryHealth | health_summary)
        },
        alarms: $alarms,
        alarmsFiring: [$alarms[] | select(.state == "ALARM") | .name]
      }
    '
}

print_report() {
  local snapshot="$1"

  hr
  printf '  %sECS CANARY STATUS%s   %s\n' "$C_BOLD" "$C_RESET" "$(date '+%H:%M:%S')" >&2
  hr

  printf '%s' "$snapshot" | jq -r '
    "  cluster    \(.cluster)  (\(.region))",
    "  dashboard  \(.dashboard)"
  ' >&2

  local stable_weight canary_weight
  stable_weight="$(printf '%s' "$snapshot" | jq -r '.split.stableWeight')"
  canary_weight="$(printf '%s' "$snapshot" | jq -r '.split.canaryWeight')"

  printf '\n  %sTRAFFIC SPLIT%s\n' "$C_BOLD" "$C_RESET" >&2
  print_split_bar "$stable_weight" "$canary_weight"
  printf '  %sweights    stable=%s  canary=%s%s\n' "$C_DIM" "$stable_weight" "$canary_weight" "$C_RESET" >&2

  printf '\n  %sSERVICES%s\n' "$C_BOLD" "$C_RESET" >&2
  printf '%s' "$snapshot" | jq -r '
    def row(label; svc; tg):
      "  \(label)\tdesired=\(svc.desired) running=\(svc.running) pending=\(svc.pending)\t\(svc.taskDefinition)\thealthy=\(tg.healthy)/\(tg.total)";
    row("stable"; .services.stable; .targets.stable),
    row("canary"; .services.canary; .targets.canary)
  ' | while IFS= read -r line; do
    printf '%s\n' "$line" >&2
  done

  local rollouts
  rollouts="$(printf '%s' "$snapshot" | jq -r '
    [.services.stable, .services.canary]
    | map(select(.deployments[]? | .rollout != null and .rollout != "COMPLETED"))
    | .[] | "  \(.name): deployment \(.deployments[0].rollout)"
  ')"
  if [ -n "$rollouts" ]; then
    printf '\n  %sIN FLIGHT%s\n' "$C_BOLD" "$C_RESET" >&2
    printf '%s\n' "$rollouts" >&2
  fi

  printf '\n  %sALARMS%s\n' "$C_BOLD" "$C_RESET" >&2
  if [ "$(printf '%s' "$snapshot" | jq '.alarms | length')" -eq 0 ]; then
    info "no canary alarms found"
  else
    print_alarm_states
  fi

  local firing
  firing="$(printf '%s' "$snapshot" | jq -r '.alarmsFiring | join(" ")')"
  if [ -n "$firing" ]; then
    printf '\n' >&2
    err "alarms firing: ${firing}"
    info "roll back with:  ./scripts/rollback.sh"
  fi

  # What the app itself reports, straight through the load balancer.
  local alb_dns
  alb_dns="$(printf '%s' "$snapshot" | jq -r '.dashboard')"
  if command -v curl >/dev/null 2>&1; then
    local app_stats
    if app_stats="$(curl -sf --max-time 5 "${alb_dns}/api/stats?minutes=5&recent=0" 2>/dev/null)"; then
      printf '\n  %sAPP COUNTERS (from DynamoDB)%s\n' "$C_BOLD" "$C_RESET" >&2
      printf '%s' "$app_stats" | jq -r '
        "  requests   total=\(.totals.hits) errors=\(.totals.errors) (\(.totals.errorRate)%)",
        "  stable     \(.tracks.stable.hits) reqs  \(.tracks.stable.errorRate)% errors  \(.tracks.stable.avgLatencyMs)ms avg  v\(.tracks.stable.versions[0].version // "-")",
        "  canary     \(.tracks.canary.hits) reqs  \(.tracks.canary.errorRate)% errors  \(.tracks.canary.avgLatencyMs)ms avg  v\(.tracks.canary.versions[0].version // "-")",
        (if (.chaos.stable.failRate > 0 or .chaos.stable.latencyMs > 0 or .chaos.stable.unhealthy
             or .chaos.canary.failRate > 0 or .chaos.canary.latencyMs > 0 or .chaos.canary.unhealthy)
         then "  chaos      stable(fail=\(.chaos.stable.failRate)% lat=\(.chaos.stable.latencyMs)ms unhealthy=\(.chaos.stable.unhealthy)) canary(fail=\(.chaos.canary.failRate)% lat=\(.chaos.canary.latencyMs)ms unhealthy=\(.chaos.canary.unhealthy))"
         else empty end)
      ' >&2
    fi
  fi
  hr
}

if [ "$AS_JSON" = true ]; then
  collect_json
  exit 0
fi

if [ "$WATCH" = true ]; then
  trap 'printf "\n"; exit 0' INT TERM
  while true; do
    printf '\033[2J\033[H' >&2
    print_report "$(collect_json)"
    info "refreshing every ${INTERVAL}s, Ctrl-C to stop"
    sleep "$INTERVAL"
  done
fi

print_report "$(collect_json)"
