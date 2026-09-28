#!/usr/bin/env bash
# M8 game day (spec M8): shrink inventory's DB pool to 2 under load and time the detection chain.
#   bash tests/m8-gameday.sh start [rate] [minutes]   baseline 3 min, inject DB_POOL_MAX=2, watch until a page email
#   bash tests/m8-gameday.sh restore                  DB_POOL_MAX back to 10, stop k6
# The incident is left RUNNING after "start" so participants can investigate it live; the fault goes
# in through Helm values, like every other change. Needs port-forwards: Prometheus 9090, Mailpit 18025.
set -uo pipefail
cd "$(dirname "$0")/.."
PROM=http://localhost:9090; MAIL=http://localhost:18025
say() { echo "$(date -u +%H:%M:%S) $*"; }
q() { curl -s "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "none"'; }
fmt() { awk -v v="$1" -v m="${2:-1}" -v u="${3:-}" 'BEGIN{ if (v=="none") print "none"; else printf "%.3f%s\n", v*m, u }'; }

# Both phases run with each reservation holding its connection SLOW_MS (default 30 ms, D-36): P04-lite's
# real query is a few ms, so a pool of 2 alone did not exhaust at 100 req/s (attempt 1, measured).
# Capacity ~ pool / hold time: 10 / 0.03 s = 333 req/s (healthy), 2 / 0.03 s = 66 req/s (exhausted).
SLOW_MS=${SLOW_MS:-30}
pool() { # DB_POOL_MAX [FAULT_DB_SLOW_MS]
  bash app/deploy.sh --set "services.inventory.env.DB_POOL_MAX=$1" --set "services.inventory.env.FAULT_DB_SLOW_MS=${2:-$SLOW_MS}" >/dev/null 2>&1 || say "helm upgrade FAILED"
  kubectl -n freightline rollout status deploy/inventory --timeout=120s >/dev/null
}

case "${1:-}" in
  start)
    rate=${2:-100}; min=${3:-60}
    say "== setup: clear Mailpit, k6 at $rate req/s for $min min, 3 min of healthy baseline"
    curl -s -XDELETE "$MAIL/api/v1/messages" >/dev/null
    kubectl -n freightline delete job k6-steady --ignore-not-found --wait >/dev/null
    kubectl -n freightline create configmap k6-steady --from-file=load/steady.js --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    sed -e "s/value: \"10\"/value: \"$rate\"/" -e "s/value: \"60s\"/value: \"${min}m\"/" load/k6-job.yaml | kubectl apply -f - >/dev/null
    pool 10; say "baseline: DB_POOL_MAX=10, FAULT_DB_SLOW_MS=$SLOW_MS"
    sleep 180
    say "== baseline orders p99=$(fmt "$(q 'histogram_quantile(0.99, sum by (le) (rate(http_server_request_duration_seconds_bucket{job="freightline/orders",http_route="/v1/orders"}[2m])))')" 1000 ms)"
    say "== INJECT: helm upgrade with services.inventory.env.DB_POOL_MAX=2"
    pool 2; t0=$(date +%s); say "inventory rolled out with DB_POOL_MAX=2 (t=0)"
    declare -A first=()
    while [ "$(date +%s)" -lt $(( t0 + 30 * 60 )) ]; do
      el=$(( $(date +%s) - t0 ))
      p99=$(q 'histogram_quantile(0.99, sum by (le) (rate(http_server_request_duration_seconds_bucket{job="freightline/orders",http_route="/v1/orders"}[1m])))')
      i503=$(q 'sum(rate(http_server_request_duration_seconds_count{job="freightline/inventory",http_response_status_code="503"}[1m])) or vector(0)')
      bad=$(q 'slo:sli_error:ratio_rate5m{sloth_slo="requests-latency"}')
      firing=$(curl -s "$PROM/api/v1/query" --data-urlencode 'query=ALERTS{alertstate="firing",alertname!="Watchdog"}' | jq -r '[.data.result[].metric | "\(.alertname)/\(.severity)"] | unique | join(",")')
      for a in ${firing//,/ }; do [ -z "${first[$a]:-}" ] && { first[$a]=$el; say "   ALERT FIRING: $a at t+${el}s"; }; done
      mail=$(curl -s "$MAIL/api/v1/messages" | jq -r '[.messages[] | select(.To[0].Address | startswith("page@"))] | length')
      echo "   t+${el}s orders p99=$(fmt "$p99" 1000 ms) inventory 503/s=$(fmt "$i503") latency SLI bad ratio 5m=$(fmt "$bad") firing=[${firing}] page mails=$mail"
      [ "${mail:-0}" -gt 0 ] && { say "== PAGE EMAIL delivered at t+${el}s (Mailpit)"; break; }
      sleep 15
    done
    curl -s "$MAIL/api/v1/messages" | jq -r '.messages[] | "   \(.Created[11:19]) to=\(.To[0].Address) \(.Subject)"'
    say "== incident left running for the participants; restore with: bash tests/m8-gameday.sh restore" ;;
  restore)
    pool 10 0; kubectl -n freightline delete job k6-steady --ignore-not-found >/dev/null
    say "DB_POOL_MAX=10 and FAULT_DB_SLOW_MS=0 restored, k6 stopped" ;;
  *) sed -n 2,6p "$0"; exit 2 ;;
esac
