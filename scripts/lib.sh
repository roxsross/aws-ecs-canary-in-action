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

# Reads whichever target group the production listener rule is sending most of
# the traffic to right now. ECS's native canary strategy still uses a weighted
# ForwardConfig under the hood (like the old hand-rolled listener did), it just
# owns the weights itself: 100/0 at rest, temporarily split during a rollout.
alb_production_target_group() {
  awsx elbv2 describe-rules \
    --rule-arns "$CANARY_PRODUCTION_RULE_ARN" \
    --query 'Rules[0].Actions[0].ForwardConfig.TargetGroups | sort_by(@, &Weight) | [-1].TargetGroupArn' \
    --output text
}

# Both weights of the production rule, as "primary alternate", for status.sh.
alb_production_weights() {
  local json primary alternate
  json="$(awsx elbv2 describe-rules \
    --rule-arns "$CANARY_PRODUCTION_RULE_ARN" \
    --query 'Rules[0].Actions[0].ForwardConfig.TargetGroups' \
    --output json)"
  primary="$(printf '%s' "$json" | jq -r --arg tg "$CANARY_TG_PRIMARY" \
    '[.[] | select(.TargetGroupArn == $tg) | .Weight] | first // 0')"
  alternate="$(printf '%s' "$json" | jq -r --arg tg "$CANARY_TG_ALTERNATE" \
    '[.[] | select(.TargetGroupArn == $tg) | .Weight] | first // 0')"
  printf '%s %s\n' "$primary" "$alternate"
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
# One service now, using ECS's native CANARY deployment strategy: a rollout is
# `update-service --task-definition ... --force-new-deployment`, and ECS itself
# creates the "green" revision, shifts the production listener rule between the
# primary/alternate target groups, watches the alarms and rolls back if one
# fires. These helpers just read that state; they don't drive it step by step
# the way the old two-service design did.

ecs_service_json() {
  awsx ecs describe-services \
    --cluster "$CANARY_CLUSTER" \
    --services "$CANARY_SERVICE" \
    --query 'services[0]' \
    --output json
}

ecs_desired_count() {
  ecs_service_json | jq -r '.desiredCount // 0'
}

ecs_task_definition() {
  ecs_service_json | jq -r '.taskDefinition // ""'
}

ecs_rollout_state() {
  ecs_service_json | jq -r '[.deployments[]? | select(.status == "PRIMARY")][0].rolloutState // "UNKNOWN"'
}

# Echoes the image currently used by the service's task definition.
ecs_current_image() {
  local task_def
  task_def="$(ecs_task_definition)"
  [ -n "$task_def" ] || return 1
  awsx ecs describe-task-definition --task-definition "$task_def" \
    --query "taskDefinition.containerDefinitions[?name=='${CANARY_CONTAINER_NAME:-app}'].image | [0]" \
    --output text
}

# Registers a copy of the task definition family with a new image and
# APP_VERSION. Echoes the new task definition ARN.
ecs_register_with_image() {
  local image="$1" version="$2" current new_def
  current="$(awsx ecs describe-task-definition --task-definition "$CANARY_TASKDEF_FAMILY" \
    --query 'taskDefinition' --output json)"
  new_def="$(printf '%s' "$current" | jq \
    --arg image "$image" \
    --arg version "$version" \
    --arg name "${CANARY_CONTAINER_NAME:-app}" '
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
        .containerDefinitions | map(
          if .name == $name then
            .image = $image
            | .environment = ((.environment // []) | map(select(.name != "APP_VERSION")) + [{name: "APP_VERSION", value: $version}])
          else . end
        )
      )
    }
    | with_entries(select(.value != null))
  ')"
  awsx ecs register-task-definition \
    --cli-input-json "$new_def" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text
}

# Starts a canary rollout: register the new task definition, then update the
# service. ECS takes it from there (green revision, traffic shift, bake time,
# alarm watch, rollback), driven entirely by deployment_configuration in
# Terraform. Echoes the new task definition ARN.
ecs_start_rollout() {
  local image="$1" version="$2" new_taskdef
  new_taskdef="$(ecs_register_with_image "$image" "$version")"
  awsx ecs update-service \
    --cluster "$CANARY_CLUSTER" \
    --service "$CANARY_SERVICE" \
    --task-definition "$new_taskdef" \
    --force-new-deployment >/dev/null
  printf '%s\n' "$new_taskdef"
}

# One line summary of the canary strategy configured in Terraform, for humans
# watching a rollout start.
canary_deployment_summary() {
  ecs_service_json | jq -r '
    .deploymentConfiguration as $dc
    | if $dc.strategy == "CANARY" then
        "\($dc.canaryConfiguration.canaryPercent)% for \($dc.canaryConfiguration.canaryBakeTimeInMinutes)min, then 100% (bake \($dc.bakeTimeInMinutes // 0)min)"
      else
        ($dc.strategy // "ROLLING")
      end
  '
}

# Polls rolloutState until it leaves IN_PROGRESS, printing progress. Returns 0
# only if it completes AND the running task definition matches what we asked
# for — rolloutState alone is ambiguous: ECS reports COMPLETED both when a
# rollout finishes *and* when a rollback it triggered finishes. 1 covers both
# FAILED and "completed, but rolled back to the old task definition".
ecs_wait_rollout() {
  local expected_taskdef="${1:-}" timeout="${2:-1800}" poll="${3:-15}" waited=0 state current_taskdef
  while [ "$waited" -lt "$timeout" ]; do
    state="$(ecs_rollout_state)"
    case "$state" in
      COMPLETED)
        current_taskdef="$(ecs_task_definition)"
        if [ -z "$expected_taskdef" ] || [ "$current_taskdef" = "$expected_taskdef" ]; then
          ok "rollout completed"
          return 0
        fi
        err "ECS rolled back: the service is back on ${current_taskdef##*/}, not ${expected_taskdef##*/}"
        return 1
        ;;
      FAILED)
        err "rollout failed (ECS rolled back automatically if alarms/rollback were enabled)"
        return 1
        ;;
      *)
        info "rollout state: ${state} (${waited}s elapsed)"
        ;;
    esac
    sleep "$poll"
    waited=$((waited + poll))
  done
  err "timed out after ${timeout}s waiting for the rollout to finish, last state: $(ecs_rollout_state)"
  return 1
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
# same picture as the dashboard. Labels default to stable/canary (local mini-alb);
# pass a 4th/5th arg to relabel for AWS's primary/alternate.
print_split_bar() {
  local stable="$1" canary="$2" width="${3:-40}" left_label="${4:-stable}" right_label="${5:-canary}"
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
  printf '  %s%s%s%s%s%s  %s %s%% / %s %s%%\n' \
    "$C_CYAN" "$bar" "$C_RESET" \
    "$C_MAGENTA" "$canary_bar" "$C_RESET" \
    "$left_label" $((stable * 100 / total)) "$right_label" $((canary * 100 / total)) >&2
}
