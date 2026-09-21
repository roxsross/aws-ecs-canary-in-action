# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Shared helpers for the canary scripts. Sourced, never executed.
# Every script reads the CANARY_* contract written by load-env.sh.
# Written for bash 3.2 so it runs on a stock macOS shell.
# ---------------------------------------------------------------------------

CANARY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${CANARY_LIB_DIR}/.." && pwd)"
ENV_FILE="${CANARY_ENV_FILE:-${REPO_ROOT}/.canary.env}"

# ------------------------------------------------------------------- output --
# All log output goes to stderr so stdout stays usable for piping.

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_MAGENTA=$'\033[35m'
  C_CYAN=$'\033[36m'
else
  C_RESET='' C_DIM='' C_BOLD='' C_RED='' C_GREEN='' C_YELLOW='' C_MAGENTA='' C_CYAN=''
fi

step() { printf '%s▶%s %s%s%s\n' "$C_MAGENTA" "$C_RESET" "$C_BOLD" "$*" "$C_RESET" >&2; }
info() { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; }
note() { printf '  %s→%s %s\n' "$C_CYAN" "$C_RESET" "$*" >&2; }
ok() { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err() { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() {
  err "$*"
  exit 1
}

hr() { printf '%s%s%s\n' "$C_DIM" "────────────────────────────────────────────────────────" "$C_RESET" >&2; }

# Reprints the header comment of the calling script, stopping at the first line
# of real code. Keeps help text and file documentation in one place.
print_header_help() {
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$1"
}

# ------------------------------------------------------------------- guards --

require_tools() {
  local missing_count=0
  local missing_list=""
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing_count=$((missing_count + 1))
      missing_list="${missing_list} ${tool}"
    fi
  done
  if [ "$missing_count" -gt 0 ]; then
    err "missing required tools:${missing_list}"
    info "on macOS:  brew install awscli jq"
    exit 1
  fi
}

load_canary_env() {
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090  # path is resolved at runtime
    . "$ENV_FILE"
    set +a
    return 0
  fi
  return 1
}

# require_canary_env VAR [VAR...]
require_canary_env() {
  load_canary_env || true
  local missing_count=0
  local missing_list=""
  local var
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      missing_count=$((missing_count + 1))
      missing_list="${missing_list} ${var}"
    fi
  done
  if [ "$missing_count" -gt 0 ]; then
    err "missing environment:${missing_list}"
    info "generate it once with:  ./scripts/load-env.sh"
    exit 1
  fi
}

canary_region() {
  printf '%s\n' "${CANARY_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}}"
}

# aws with the region already pinned.
awsx() {
  aws --region "$(canary_region)" "$@"
}

confirm() {
  local prompt="$1"
  if [ "${CANARY_ASSUME_YES:-false}" = "true" ]; then
    return 0
  fi
  printf '%s%s%s [y/N] ' "$C_YELLOW" "$prompt" "$C_RESET" >&2
  local answer
  read -r answer
  case "$answer" in
    y | Y | yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

# --------------------------------------------------------- load balancer ----

alb_default_target_groups() {
  # shellcheck disable=SC2016  # backticks are JMESPath literals
  awsx elbv2 describe-rules \
    --listener-arn "$CANARY_LISTENER_ARN" \
    --query 'Rules[?IsDefault==`true`]|[0].Actions[0].ForwardConfig.TargetGroups' \
    --output json
}

alb_weights() {
  local json stable canary
  json="$(alb_default_target_groups)" || return 1
  stable="$(printf '%s' "$json" | jq -r --arg tg "$CANARY_TG_STABLE" \
    '[.[] | select(.TargetGroupArn == $tg) | .Weight] | first // 0')"
  canary="$(printf '%s' "$json" | jq -r --arg tg "$CANARY_TG_CANARY" \
    '[.[] | select(.TargetGroupArn == $tg) | .Weight] | first // 0')"
  printf '%s %s\n' "$stable" "$canary"
}

alb_canary_percent() {
  local pair stable canary total
  pair="$(alb_weights)" || return 1
  stable="${pair%% *}"
  canary="${pair##* }"
  total=$((stable + canary))
  if [ "$total" -le 0 ]; then
    printf '0\n'
  else
    printf '%s\n' $((canary * 100 / total))
  fi
}

alb_set_weights() {
  local stable="$1" canary="$2" actions
  actions="$(
    jq -nc \
      --arg stableTg "$CANARY_TG_STABLE" \
      --arg canaryTg "$CANARY_TG_CANARY" \
      --argjson stableWeight "$stable" \
      --argjson canaryWeight "$canary" \
      '[{
         Type: "forward",
         ForwardConfig: {
           TargetGroups: [
             { TargetGroupArn: $stableTg, Weight: $stableWeight },
             { TargetGroupArn: $canaryTg, Weight: $canaryWeight }
           ],
           TargetGroupStickinessConfig: { Enabled: false }
         }
       }]'
  )"
  awsx elbv2 modify-listener \
    --listener-arn "$CANARY_LISTENER_ARN" \
    --default-actions "$actions" >/dev/null
}

# ----------------------------------------------------------- target health --

tg_health_states() {
  awsx elbv2 describe-target-health \
    --target-group-arn "$1" \
    --query 'TargetHealthDescriptions[].TargetHealth.State' \
    --output json
}

tg_healthy_count() {
  tg_health_states "$1" | jq '[.[] | select(. == "healthy")] | length'
}

tg_total_count() {
  tg_health_states "$1" | jq 'length'
}

# Waits until the target group reports at least N healthy targets.
tg_wait_healthy() {
  local tg_arn="$1" want="$2" timeout="${3:-300}"
  local waited=0 healthy=0
  while [ "$waited" -lt "$timeout" ]; do
    healthy="$(tg_healthy_count "$tg_arn")"
    if [ "$healthy" -ge "$want" ]; then
      ok "target group healthy: ${healthy}/${want} targets passing health checks"
      return 0
    fi
    info "waiting for healthy targets: ${healthy}/${want} (${waited}s)"
    sleep 10
    waited=$((waited + 10))
  done
  err "timed out after ${timeout}s waiting for ${want} healthy target(s), have ${healthy}"
  return 1
}

# -------------------------------------------------------------------- ECS ----

ecs_service_json() {
  awsx ecs describe-services \
    --cluster "$CANARY_CLUSTER" \
    --services "$1" \
    --query 'services[0]' \
    --output json
}

ecs_desired_count() {
  ecs_service_json "$1" | jq -r '.desiredCount // 0'
}

ecs_running_count() {
  ecs_service_json "$1" | jq -r '.runningCount // 0'
}

ecs_task_definition() {
  ecs_service_json "$1" | jq -r '.taskDefinition // ""'
}

ecs_scale() {
  awsx ecs update-service \
    --cluster "$CANARY_CLUSTER" \
    --service "$1" \
    --desired-count "$2" >/dev/null
}

# Points a service at a task definition and forces a new deployment.
ecs_set_task_definition() {
  awsx ecs update-service \
    --cluster "$CANARY_CLUSTER" \
    --service "$1" \
    --task-definition "$2" \
    --force-new-deployment >/dev/null
}

ecs_wait_stable() {
  local service="$1"
  info "waiting for ${service} to reach a steady state (up to 10 min)"
  if awsx ecs wait services-stable --cluster "$CANARY_CLUSTER" --services "$service"; then
    ok "${service} is stable"
    return 0
  fi
  err "${service} did not stabilise"
  return 1
}

# Registers a copy of a task definition family with a new image.
# Echoes the new task definition ARN.
ecs_register_with_image() {
  local family="$1" image="$2" current new_def
  current="$(awsx ecs describe-task-definition --task-definition "$family" \
    --query 'taskDefinition' --output json)"
  new_def="$(printf '%s' "$current" | jq --arg image "$image" --arg name "${CANARY_CONTAINER_NAME:-app}" '
    {
      family,
      taskRoleArn,
      executionRoleArn,
      networkMode,
      cpu,
      memory,
      requiresCompatibilities,
      runtimePlatform,
      volumes,
      placementConstraints,
      containerDefinitions: (
        .containerDefinitions | map(if .name == $name then .image = $image else . end)
      )
    }
    | with_entries(select(.value != null))
  ')"
  awsx ecs register-task-definition \
    --cli-input-json "$new_def" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text
}

# Echoes the image currently used by a service's task definition.
ecs_current_image() {
  local service="$1" task_def
  task_def="$(ecs_task_definition "$service")"
  [ -n "$task_def" ] || return 1
  awsx ecs describe-task-definition --task-definition "$task_def" \
    --query "taskDefinition.containerDefinitions[?name=='${CANARY_CONTAINER_NAME:-app}'].image | [0]" \
    --output text
}

# ----------------------------------------------------------------- alarms ----

# Echoes the canary alarm names, space separated.
canary_alarm_names() {
  local names="" candidate
  for candidate in \
    "${CANARY_ALARM_5XX:-}" \
    "${CANARY_ALARM_LATENCY:-}" \
    "${CANARY_ALARM_UNHEALTHY:-}" \
    "${CANARY_ALARM_ERRORRATE:-}"; do
    if [ -n "$candidate" ]; then
      names="${names}${names:+ }${candidate}"
    fi
  done
  printf '%s\n' "$names"
}

alarms_json() {
  local names
  names="$(canary_alarm_names)"
  [ -n "$names" ] || {
    printf '[]\n'
    return 0
  }
  # shellcheck disable=SC2086  # intentional word splitting: one arg per alarm name
  awsx cloudwatch describe-alarms \
    --alarm-names $names \
    --query 'MetricAlarms[].{name:AlarmName,state:StateValue,reason:StateReason,updated:StateUpdatedTimestamp}' \
    --output json
}

alarms_in_alarm() {
  alarms_json | jq -r '.[] | select(.state == "ALARM") | .name'
}

print_alarm_states() {
  local json
  json="$(alarms_json)"
  printf '%s' "$json" | jq -r '.[] | "\(.state)\t\(.name)"' | while IFS=$'\t' read -r state name; do
    case "$state" in
      ALARM) err "${name}: ${state}" ;;
      OK) ok "${name}: ${state}" ;;
      *) info "${name}: ${state}" ;;
    esac
  done
}

# Clears stale state left over from a previous demo so a rollout does not abort
# on history. CloudWatch re-evaluates from real data within a period or two.
reset_canary_alarms() {
  local names name
  names="$(canary_alarm_names)"
  for name in $names; do
    awsx cloudwatch set-alarm-state \
      --alarm-name "$name" \
      --state-value OK \
      --state-reason "reset by canary-deploy before a new rollout" >/dev/null 2>&1 ||
      warn "could not reset alarm ${name}"
  done
  info "alarm state reset; CloudWatch will re-evaluate from live metrics"
}

# Watches the canary alarms for a window, returning non-zero the moment one
# fires. Echoes the offending alarm names on stdout.
# usage: watch_alarms <seconds> <poll_interval> <label>
watch_alarms() {
  local duration="$1" interval="${2:-15}" label="${3:-baking}"
  local waited=0 firing=""
  while [ "$waited" -lt "$duration" ]; do
    firing="$(alarms_in_alarm)"
    if [ -n "$firing" ]; then
      printf '%s\n' "$firing"
      return 1
    fi
    info "${label}: ${waited}/${duration}s elapsed, alarms clear"
    sleep "$interval"
    waited=$((waited + interval))
  done
  firing="$(alarms_in_alarm)"
  if [ -n "$firing" ]; then
    printf '%s\n' "$firing"
    return 1
  fi
  return 0
}

# ------------------------------------------------------------------ misc ----

app_url() {
  printf 'http://%s\n' "${CANARY_ALB_DNS}"
}

# Draws a small ASCII bar for the traffic split, so terminal output shows the
# same picture as the dashboard.
print_split_bar() {
  local stable="$1" canary="$2" width="${3:-40}"
  local total=$((stable + canary))
  [ "$total" -gt 0 ] || total=1
  local canary_cells=$((canary * width / total))
  local stable_cells=$((width - canary_cells))
  local bar="" i
  i=0
  while [ "$i" -lt "$stable_cells" ]; do
    bar="${bar}█"
    i=$((i + 1))
  done
  local canary_bar="" j
  j=0
  while [ "$j" -lt "$canary_cells" ]; do
    canary_bar="${canary_bar}█"
    j=$((j + 1))
  done
  printf '  %s%s%s%s%s%s  stable %s%% / canary %s%%\n' \
    "$C_CYAN" "$bar" "$C_RESET" \
    "$C_MAGENTA" "$canary_bar" "$C_RESET" \
    $((stable * 100 / total)) $((canary * 100 / total)) >&2
}
