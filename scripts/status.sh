#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One screen with everything that matters: the service's rollout state, which
# target group is production right now, target health, alarm state and what
# the app itself reports.
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
  CANARY_CLUSTER CANARY_SERVICE CANARY_TG_PRIMARY CANARY_TG_ALTERNATE

collect_json() {
  local service_json production_tg
  service_json="$(ecs_service_json)"
  production_tg="$(alb_production_target_group 2>/dev/null || printf '')"

  jq -n \
    --argjson service "$service_json" \
    --argjson primaryHealth "$(tg_health_states "$CANARY_TG_PRIMARY")" \
    --argjson alternateHealth "$(tg_health_states "$CANARY_TG_ALTERNATE")" \
    --argjson alarms "$(alarms_json)" \
    --arg productionTg "$production_tg" \
    --arg primaryTg "$CANARY_TG_PRIMARY" \
    --arg alternateTg "$CANARY_TG_ALTERNATE" \
    --arg albDns "${CANARY_ALB_DNS:-}" \
    --arg cluster "$CANARY_CLUSTER" \
    --arg region "$(canary_region)" \
    '
    def health_summary:
      { total: length, healthy: ([.[] | select(. == "healthy")] | length), states: . };
    ($service.deployments // [] | map(select(.status == "PRIMARY")) | first) as $primaryDeployment
    | {
        region: $region,
        cluster: $cluster,
        dashboard: ("http://" + $albDns),
        service: {
          name: $service.serviceName,
          desired: $service.desiredCount,
          running: $service.runningCount,
          pending: $service.pendingCount,
          taskDefinition: ($service.taskDefinition | split("/") | last),
          rolloutState: ($primaryDeployment.rolloutState // "UNKNOWN"),
          rolloutStateReason: ($primaryDeployment.rolloutStateReason // null),
          strategy: ($service.deploymentConfiguration.strategy // "ROLLING"),
          canaryPercent: ($service.deploymentConfiguration.canaryConfiguration.canaryPercent // null)
        },
        productionTargetGroup: (if $productionTg == $primaryTg then "primary" elif $productionTg == $alternateTg then "alternate" else "unknown" end),
        targets: {
          primary: ($primaryHealth | health_summary),
          alternate: ($alternateHealth | health_summary)
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

  printf '\n  %sSERVICE%s\n' "$C_BOLD" "$C_RESET" >&2
  printf '%s' "$snapshot" | jq -r '
    "  \(.service.name)\tdesired=\(.service.desired) running=\(.service.running) pending=\(.service.pending)\t\(.service.taskDefinition)",
    "  strategy=\(.service.strategy)\(if .service.canaryPercent then " canary_percent=\(.service.canaryPercent)%" else "" end)  rollout=\(.service.rolloutState)",
    "  production traffic -> \(.productionTargetGroup) target group",
    "  healthy   primary=\(.targets.primary.healthy)/\(.targets.primary.total)  alternate=\(.targets.alternate.healthy)/\(.targets.alternate.total)"
  ' >&2

  local reason
  reason="$(printf '%s' "$snapshot" | jq -r '.service.rolloutStateReason // ""')"
  [ -z "$reason" ] || info "reason: ${reason}"

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
    info "ECS rolls this back automatically if the service's alarms block has rollback enabled"
    info "to cut it short yourself:  ./scripts/rollback.sh"
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
        "  reported version: v\(.tracks.stable.versions[0].version // .tracks.canary.versions[0].version // "-")"
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
