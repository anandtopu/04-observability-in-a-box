#!/usr/bin/env bash
# M6 live burn tests (spec section 7 "Fast / slow burn", success criterion 3), in-cluster traffic.
# Phases, in this order so each starts from clean alert windows:
#   1. slow burn: FAULT_5XX_RATE=0.001 (1x burn)           -> must NOT page
#   2. fast burn: FAULT_5XX_RATE=0.5 (500x burn)            -> page expected in < 5 min; then fix and time the resolve
#   3. latency:   every orders request +300 ms (100x burn)  -> latency page expected after ~9 min
# Faults are set through Helm values (bash app/deploy.sh --set ...), never kubectl set env.
# Needs port-forwards: kps-prometheus 9090, mailpit 18025. Durations (minutes) can be overridden:
#   SLOW_MIN=20 FAST_MAX_MIN=8 RESOLVE_MAX_MIN=12 LAT_MAX_MIN=20 bash tests/burn-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.."
PROM=http://localhost:9090; MAIL=http://localhost:18025
# RESOLVE_MAX_MIN 35: after a fix the 6x pair (6h AND 30m) can hold a page until the burst leaves
# the 30m window; in the lab's sparse history it did (first run: still firing 12 min after the fix).
SLOW_MIN=${SLOW_MIN:-20}; FAST_MAX_MIN=${FAST_MAX_MIN:-8}; RESOLVE_MAX_MIN=${RESOLVE_MAX_MIN:-35}; LAT_MAX_MIN=${LAT_MAX_MIN:-20}
ts() { date -u +%H:%M:%S; }
say() { echo "$(ts) $*"; }

set_faults() { # 5xx_rate latency_rate latency_ms
  bash app/deploy.sh --set "services.orders.env.FAULT_5XX_RATE=$1" --set "services.orders.env.FAULT_LATENCY_RATE=$2" \
    --set "services.orders.env.FAULT_LATENCY_MS=$3" >/dev/null 2>&1 || say "helm upgrade FAILED"
  kubectl -n freightline rollout status deploy/orders --timeout=120s >/dev/null
  say "faults now: FAULT_5XX_RATE=$1 FAULT_LATENCY_RATE=$2 FAULT_LATENCY_MS=$3 (orders pod ready)"
}
firing() { # alertname severity -> 1/0
  curl -s "$PROM/api/v1/query" --data-urlencode "query=count(ALERTS{alertname=\"$1\",severity=\"$2\",alertstate=\"firing\"})" \
    | jq -r '.data.result[0].value[1] // "0"'
}
mails() { curl -s "$MAIL/api/v1/messages" | jq -r --arg a "$1" '[.messages[] | select(.Subject | contains($a))] | map("\(.To[0].Address)") | join(",")'; }
ratio() { curl -s "$PROM/api/v1/query" --data-urlencode "query=slo:sli_error:ratio_rate$2{sloth_slo=\"$1\"}" | jq -r '.data.result[0].value[1] // "none" | if . == "none" then . else (tonumber*1000|round/1000|tostring) end'; }
# Wait until an alert fires (or max minutes pass); prints elapsed seconds since $start.
wait_for() { # alertname severity want(1/0) max_min
  local deadline=$(( $(date +%s) + $4 * 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(firing "$1" "$2")" = "$3" ] && { echo $(( $(date +%s) - start )); return 0; }
    sleep 15
  done; echo "none"; return 1
}

say "== setup: clear Mailpit, start in-cluster k6 at 10 req/s for 90 min"
curl -s -XDELETE "$MAIL/api/v1/messages" >/dev/null
kubectl -n freightline delete job k6-steady --ignore-not-found >/dev/null
kubectl -n freightline create configmap k6-steady --from-file=load/steady.js --dry-run=client -o yaml | kubectl apply -f - >/dev/null
sed 's/value: "60s"/value: "90m"/' load/k6-job.yaml | kubectl apply -f - >/dev/null
set_faults 0 0 0
sleep 180

say "== phase 1: slow burn, 0.1% errors (1x) for ${SLOW_MIN} min: must NOT page"
set_faults 0.001 0 0; start=$(date +%s); pages=0
for _ in $(seq $(( SLOW_MIN * 4 ))); do
  p=$(firing OrdersAvailabilityBurn page); [ "$p" != "0" ] && pages=$((pages+1))
  sleep 15
done
say "slow burn result: page firing in $pages of $(( SLOW_MIN * 4 )) checks; ratios 5m=$(ratio requests-availability 5m) 1h=$(ratio requests-availability 1h); page mails: [$(mails OrdersAvailabilityBurn)]"

say "== phase 2: fast burn, 50% errors (500x): page expected < 5 min"
set_faults 0.5 0 0; start=$(date +%s)
t=$(wait_for OrdersAvailabilityBurn page 1 "$FAST_MAX_MIN"); say "fast burn: OrdersAvailabilityBurn page FIRING after ${t}s in Prometheus (ratios 5m=$(ratio requests-availability 5m) 1h=$(ratio requests-availability 1h))"
# Wait for the PAGE email specifically (the ticket often arrives first; first run stopped at it).
for _ in $(seq 12); do m=$(mails 'OrdersAvailabilityBurn'); [[ "$m" == *page@* ]] && break; sleep 10; done
say "fast burn: page email after $(( $(date +%s) - start ))s, recipients so far: [$m]"
say "== fix: FAULT_5XX_RATE=0, time until the page resolves"
set_faults 0 0 0; start=$(date +%s)
t=$(wait_for OrdersAvailabilityBurn page 0 "$RESOLVE_MAX_MIN"); say "fast burn: page RESOLVED ${t}s after the fix (ratios 5m=$(ratio requests-availability 5m) 1h=$(ratio requests-availability 1h))"
say "ticket for availability firing now: $(firing OrdersAvailabilityBurn ticket)"

say "== phase 3: latency burn, every orders request +300 ms (100x): page expected ~9 min"
set_faults 0 1 300; start=$(date +%s)
t=$(wait_for OrdersLatencyBurn page 1 "$LAT_MAX_MIN"); say "latency burn: OrdersLatencyBurn page FIRING after ${t}s (ratios 5m=$(ratio requests-latency 5m) 30m=$(ratio requests-latency 30m) 1h=$(ratio requests-latency 1h) 6h=$(ratio requests-latency 6h))"
for _ in $(seq 12); do m=$(mails 'OrdersLatencyBurn'); [[ "$m" == *page@* ]] && break; sleep 10; done
say "latency burn: page email after $(( $(date +%s) - start ))s, recipients so far: [$m]"
set_faults 0 0 0

say "== Mailpit inbox at the end"
curl -s "$MAIL/api/v1/messages" | jq -r '.messages[] | "   \(.Created[11:19]) to=\(.To[0].Address) \(.Subject)"'
kubectl -n freightline delete job k6-steady --ignore-not-found >/dev/null
say "== done"
