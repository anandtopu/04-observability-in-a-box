#!/usr/bin/env bash
# M8 blind game day: restore, wait for a clean alert state, inject ONE fault picked at random, watch until
# the page email. Output shows timings only; the fault's name goes to $SECRET (revealed after the run).
#   SECRET=/path/outside/the/chat bash tests/m8-blind.sh
# k6 must already be running (load/k6-job.yaml at 100 req/s). Port-forwards: Prometheus 9090, Alertmanager 9093, Mailpit 18025.
set -uo pipefail
cd "$(dirname "$0")/.."
PROM=http://localhost:9090; MAIL=http://localhost:18025; SECRET=${SECRET:?set SECRET to a file path}
say() { echo "$(date -u +%H:%M:%S) $*"; }
pages() { curl -s "$PROM/api/v1/query" --data-urlencode 'query=count(ALERTS{severity="page",alertstate="firing"}) or vector(0)' | jq -r '.data.result[0].value[1]'; }
deploy() { bash app/deploy.sh "$@" >/dev/null 2>&1 || say "helm upgrade FAILED"
  kubectl -n freightline rollout status deploy/orders --timeout=120s >/dev/null
  kubectl -n freightline rollout status deploy/inventory --timeout=120s >/dev/null; }

say "== restore: every fault off, DB_POOL_MAX=10 (chart defaults)"; deploy
say "== waiting for clean SLO windows (the 6h/30m pair can hold a page ~30 min after a fix)"
# "No page firing" is not enough: right after a Prometheus restart ALERTS is empty while the windows
# still hold the last incident, and the old page re-fires minutes later (M8, found before injecting).
# Clean = no page AND, for both SLOs, 5m < 14.4x and 30m < 6x the 1% / 0.1% budgets' page thresholds.
clean() {
  local bad; bad=$(curl -s "$PROM/api/v1/query" --data-urlencode 'query=
      (count(slo:sli_error:ratio_rate5m{sloth_service="orders"} > on (sloth_id) 14.4 * (1 - slo:objective:ratio{sloth_service="orders"})) or vector(0))
    + (count(slo:sli_error:ratio_rate30m{sloth_service="orders"} > on (sloth_id) 6 * (1 - slo:objective:ratio{sloth_service="orders"})) or vector(0))' | jq -r '.data.result[0].value[1]')
  # Alertmanager too: while it still holds a page as active, a new incident with the same labels is
  # deduplicated (repeat_interval 12h) and nobody is emailed (M8, the notification log survived a restart).
  local am; am=$(curl -s "http://localhost:9093/api/v2/alerts?active=true&filter=severity%3D%22page%22" | jq 'length')
  [ "$(pages)" = "0" ] && [ "$bad" = "0" ] && [ "$am" = "0" ]
}
n=0; while [ $n -lt 4 ]; do if clean; then n=$((n+1)); else n=0; fi; sleep 30; done   # clean for 2 min
say "SLO windows clean and no page firing for 2 min"
curl -s -XDELETE "$MAIL/api/v1/messages" >/dev/null; say "Mailpit cleared"

FAULTS=(
  "A orders 5xx 20%|--set services.orders.env.FAULT_5XX_RATE=0.2"
  "B orders +400 ms on 50% of requests|--set services.orders.env.FAULT_LATENCY_RATE=0.5 --set services.orders.env.FAULT_LATENCY_MS=400"
  "C inventory slow query 120 ms (pool 10: ~83 req/s capacity)|--set services.inventory.env.FAULT_DB_SLOW_MS=120"
)
pick=${FAULTS[$(( RANDOM % ${#FAULTS[@]} ))]}
echo "${pick%%|*}" > "$SECRET"
# shellcheck disable=SC2086
deploy ${pick#*|}; t0=$(date +%s); say "== INJECTED (t=0); fault recorded in the secret file"
while [ "$(date +%s)" -lt $(( t0 + 60 * 60 )) ]; do
  n=$(curl -s "$MAIL/api/v1/messages" | jq -r '[.messages[] | select(.To[0].Address=="page@lab.local")] | length')
  [ "${n:-0}" -gt 0 ] && { say "== PAGE EMAIL delivered at t+$(( $(date +%s) - t0 ))s"; exit 0; }
  sleep 10
done
say "no page within 60 min"; exit 1
