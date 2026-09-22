#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Generates traffic and reports the split it actually observed. Useful as
# proof: at 5% canary weight, roughly 5% of these requests hit the canary.
#
#   ./scripts/traffic-gen.sh                                 # 5 rps for 60s
#   ./scripts/traffic-gen.sh --rps 20 --duration 300
#   ./scripts/traffic-gen.sh --requests 200                  # a fixed count, as fast as it can
#   ./scripts/traffic-gen.sh --track canary                  # pin to one version
#   ./scripts/traffic-gen.sh --url http://localhost:8080      # the local mini-alb
#
# The split is read two ways from the response headers:
#   - X-Track   (stable/canary): meaningful on local/mini-alb, where the two
#     revisions are separate services.
#   - X-Version (APP_VERSION):   meaningful on AWS, where ECS runs one service
#     and every task reports track=stable, so the version is what tells the
#     revisions apart. The observed canary share falls back to the minority
#     version when the track can't distinguish them.
#
# The dashboard does the same thing from the browser; this is the terminal
# version, handy for CI or when you want a number to quote.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

RPS=5
DURATION=60
REQUESTS=0
PATH_SUFFIX="/api/hit"
TRACK=""
BASE_URL=""
CONCURRENCY=4
QUIET=false
AS_JSON=false

usage() {
  print_header_help "${BASH_SOURCE[0]}"
  cat <<'EOF'
Options
  --rps N           Requests per second (default: 5)
  --duration N      Seconds to run (default: 60)
  --requests N      Send exactly N requests and stop, ignoring --duration
  --track NAME      Pin every request to stable or canary via ?track=
  --path PATH       Path to request (default: /api/hit)
  --url URL         Base URL (default: the ALB from .canary.env)
  --concurrency N   Parallel curl workers (default: 4)
  --quiet           Only print the final summary
  --json            Print a JSON summary on stdout (for CI assertions)
  -h, --help        This help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --rps) RPS="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --requests) REQUESTS="$2"; shift 2 ;;
    --track) TRACK="$2"; shift 2 ;;
    --path) PATH_SUFFIX="$2"; shift 2 ;;
    --url) BASE_URL="$2"; shift 2 ;;
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    --quiet) QUIET=true; shift ;;
    --json) AS_JSON=true; QUIET=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

require_tools curl
[ "$AS_JSON" = false ] || require_tools jq

if [ -z "$BASE_URL" ]; then
  load_canary_env || true
  if [ -n "${CANARY_ALB_DNS:-}" ]; then
    BASE_URL="http://${CANARY_ALB_DNS}"
  else
    BASE_URL="http://localhost:8080"
    info "no .canary.env found, using ${BASE_URL}"
  fi
fi
BASE_URL="${BASE_URL%/}"

URL="${BASE_URL}${PATH_SUFFIX}"
if [ -n "$TRACK" ]; then
  case "$TRACK" in
    stable | canary) ;;
    *) die "--track must be stable or canary" ;;
  esac
  case "$URL" in
    *\?*) URL="${URL}&track=${TRACK}" ;;
    *) URL="${URL}?track=${TRACK}" ;;
  esac
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/canary-traffic.XXXXXX")"
RESULTS="${TMP_DIR}/results.tsv"
: >"$RESULTS"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

STOPPING=false
on_interrupt() {
  STOPPING=true
}
trap on_interrupt INT TERM

# Always prints a single integer. `grep -c` is avoided on purpose: it writes 0 and
# exits 1 when there is no match, which turns `|| echo 0` into the string "0\n0".
count_track() {
  awk -F'\t' -v want="$1" '$1 == want { n++ } END { print n + 0 }' "$RESULTS"
}

# One request: records "<track>\t<version>\t<status>\t<time_total>" so the
# summary can be built without keeping anything in memory.
#
# The caller passes a unique id: bash 3.2 has no BASHPID, and $$ inside a
# background job still resolves to the parent shell, so concurrent workers would
# otherwise all write to the same header file and lose each other's headers.
send_one() {
  local id="$1"
  local header_file="${TMP_DIR}/h.${id}"
  local out
  out="$(curl -s -o /dev/null \
    --max-time 15 \
    -w '%{http_code}\t%{time_total}' \
    -H 'Accept: application/json' \
    -D "$header_file" \
    "$URL" 2>/dev/null || printf '000\t0')"

  local track version
  track="$(awk 'BEGIN{IGNORECASE=1} /^x-track:/ { gsub(/\r/, ""); print $2; exit }' \
    "$header_file" 2>/dev/null || true)"
  version="$(awk 'BEGIN{IGNORECASE=1} /^x-version:/ { gsub(/\r/, ""); print $2; exit }' \
    "$header_file" 2>/dev/null || true)"
  [ -n "$track" ] || track="unknown"
  [ -n "$version" ] || version="unknown"
  rm -f "$header_file"

  printf '%s\t%s\t%s\n' "$track" "$version" "$out" >>"$RESULTS"
}

step "generating traffic"
info "url          ${URL}"
if [ "$REQUESTS" -gt 0 ]; then
  info "requests     ${REQUESTS} (concurrency ${CONCURRENCY})"
else
  info "rate         ${RPS} rps for ${DURATION}s"
fi
[ -n "$TRACK" ] && warn "pinned to the ${TRACK} track, so this does not measure the split"
hr

SENT=0

if [ "$REQUESTS" -gt 0 ]; then
  # Fixed count: keep --concurrency workers busy.
  while [ "$SENT" -lt "$REQUESTS" ] && [ "$STOPPING" != true ]; do
    running=0
    while [ "$running" -lt "$CONCURRENCY" ] && [ "$SENT" -lt "$REQUESTS" ]; do
      send_one "$SENT" &
      SENT=$((SENT + 1))
      running=$((running + 1))
    done
    wait
    if [ "$QUIET" != true ] && [ $((SENT % 50)) -eq 0 ]; then
      info "sent ${SENT}/${REQUESTS}"
    fi
  done
  wait
else
  # Rate limited: one batch of RPS requests per second.
  ELAPSED=0
  while [ "$ELAPSED" -lt "$DURATION" ] && [ "$STOPPING" != true ]; do
    batch=0
    while [ "$batch" -lt "$RPS" ]; do
      send_one "$SENT" &
      SENT=$((SENT + 1))
      batch=$((batch + 1))
    done
    wait
    sleep 1
    ELAPSED=$((ELAPSED + 1))

    if [ "$QUIET" != true ] && [ $((ELAPSED % 10)) -eq 0 ]; then
      info "${ELAPSED}/${DURATION}s  sent=${SENT}  stable=$(count_track stable)  canary=$(count_track canary)"
    fi
  done
  wait
fi

[ "$STOPPING" = true ] && warn "stopped early"

# ---------------------------------------------------------------- summary ----

TOTAL="$(wc -l <"$RESULTS" | tr -d ' ')"
[ "$TOTAL" -gt 0 ] || die "no responses were recorded; is ${BASE_URL} reachable?"

STABLE_COUNT="$(count_track stable)"
CANARY_COUNT="$(count_track canary)"
UNKNOWN_COUNT="$(count_track unknown)"
ERRORS="$(awk -F'\t' '$3 >= 500 || $3 == "000" { n++ } END { print n+0 }' "$RESULTS")"
AVG_MS="$(awk -F'\t' '{ sum += $4; n++ } END { if (n > 0) printf "%.0f", (sum / n) * 1000; else print 0 }' "$RESULTS")"
IDENTIFIED=$((STABLE_COUNT + CANARY_COUNT))

# Per-version counts (field 2). On AWS every task reports track=stable, so the
# version is what actually separates the revisions.
VERSIONS_SEEN="$(awk -F'\t' '$2 != "" && $2 != "unknown" { print $2 }' "$RESULTS" | sort -u | wc -l | tr -d ' ')"
VERSIONED_TOTAL="$(awk -F'\t' '$2 != "" && $2 != "unknown" { n++ } END { print n+0 }' "$RESULTS")"
TOP_VERSION_COUNT="$(awk -F'\t' '$2 != "" && $2 != "unknown" { c[$2]++ } END { m=0; for (v in c) if (c[v] > m) m = c[v]; print m+0 }' "$RESULTS")"

# Observed canary share: prefer the track split (local), fall back to the
# minority version (AWS, where a rollout means two versions are serving).
if [ "$IDENTIFIED" -gt 0 ] && [ "$CANARY_COUNT" -gt 0 ]; then
  OBSERVED_CANARY_PCT=$((CANARY_COUNT * 100 / IDENTIFIED))
elif [ "$VERSIONS_SEEN" -ge 2 ] && [ "$VERSIONED_TOTAL" -gt 0 ]; then
  OBSERVED_CANARY_PCT=$(((VERSIONED_TOTAL - TOP_VERSION_COUNT) * 100 / VERSIONED_TOTAL))
else
  OBSERVED_CANARY_PCT=0
fi

hr
ok "sent ${TOTAL} requests"
if [ "$IDENTIFIED" -gt 0 ] && [ "$CANARY_COUNT" -gt 0 ]; then
  STABLE_PCT=$((STABLE_COUNT * 100 / IDENTIFIED))
  CANARY_PCT=$((100 - STABLE_PCT))
  print_split_bar "$STABLE_COUNT" "$CANARY_COUNT"
  printf '  stable     %s requests (%s%%)\n' "$STABLE_COUNT" "$STABLE_PCT" >&2
  printf '  canary     %s requests (%s%%)\n' "$CANARY_COUNT" "$CANARY_PCT" >&2
fi
if [ "$VERSIONED_TOTAL" -gt 0 ]; then
  printf '  by version (X-Version, the real split on AWS):\n' >&2
  awk -F'\t' '
    $2 != "" && $2 != "unknown" { c[$2]++; t++ }
    END { for (v in c) printf "  v%-10s %s requests (%d%%)\n", v, c[v], (100 * c[v] / t) }
  ' "$RESULTS" | sort >&2
  printf '  observed canary share: %s%%\n' "$OBSERVED_CANARY_PCT" >&2
fi
printf '  errors     %s (5xx or no response)\n' "$ERRORS" >&2
printf '  latency    %s ms average, end to end\n' "$AVG_MS" >&2
if [ "$UNKNOWN_COUNT" -gt 0 ]; then
  warn "${UNKNOWN_COUNT} responses had no X-Track/X-Version header (usually a 503 from the load balancer itself)"
fi

# Per status code breakdown, so a partial failure is visible.
printf '  statuses   ' >&2
awk -F'\t' '{ count[$3]++ } END { for (code in count) printf "%s=%s  ", code, count[code] }' "$RESULTS" >&2
printf '\n' >&2
hr

if [ -z "$TRACK" ] && { [ "$IDENTIFIED" -gt 0 ] || [ "$VERSIONED_TOTAL" -gt 0 ]; }; then
  info "compare with the configured weights:  ./scripts/weights.sh"
fi

# Machine readable summary, so CI can assert on the observed split.
if [ "$AS_JSON" = true ]; then
  STATUS_JSON="$(awk -F'\t' '
    { count[$3]++ }
    END {
      printf "{";
      first = 1;
      for (code in count) {
        if (!first) printf ",";
        printf "\"%s\":%s", code, count[code];
        first = 0;
      }
      printf "}";
    }' "$RESULTS")"

  VERSIONS_JSON="$(awk -F'\t' '
    $2 != "" && $2 != "unknown" { count[$2]++ }
    END {
      printf "{";
      first = 1;
      for (v in count) {
        if (!first) printf ",";
        printf "\"%s\":%s", v, count[v];
        first = 0;
      }
      printf "}";
    }' "$RESULTS")"

  jq -nc \
    --argjson total "$TOTAL" \
    --argjson stable "$STABLE_COUNT" \
    --argjson canary "$CANARY_COUNT" \
    --argjson unknown "$UNKNOWN_COUNT" \
    --argjson errors "$ERRORS" \
    --argjson avgMs "$AVG_MS" \
    --argjson statuses "$STATUS_JSON" \
    --argjson versions "$VERSIONS_JSON" \
    --argjson observedCanaryPercent "$OBSERVED_CANARY_PCT" \
    --arg url "$URL" \
    '{
       url: $url,
       total: $total,
       stable: $stable,
       canary: $canary,
       unknown: $unknown,
       errors: $errors,
       avgLatencyMs: $avgMs,
       statuses: $statuses,
       versions: $versions,
       observedCanaryPercent: $observedCanaryPercent
     }'
fi
