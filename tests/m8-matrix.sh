#!/usr/bin/env bash
# M8: the spec section 7 rows that need load (in-cluster k6, through the orders Service).
#   bash tests/m8-matrix.sh load <rate> <minutes> <label>   one run: rate, errors, p99, CPU, series, trace completeness
#   bash tests/m8-matrix.sh overhead <rate> <minutes>       SDK on vs OTEL_SDK_DISABLED=true, same load (NFR < 5%)
#   bash tests/m8-matrix.sh chaos <rate> <minutes>          delete a gateway pod every 2 min (pass: k6 errors
#                                                           unchanged vs the "on" run, trace gaps < 1%)
# Needs the Prometheus port-forward on :9090. Measured values only; a target the VM can't reach is
# reported as achieved vs target, never as the target.
set -uo pipefail
cd "$(dirname "$0")/.."
PROM=http://localhost:9090
say() { echo "$(date -u +%H:%M:%S) $*"; }
qat() { # query [epoch] -> first value or "none"
  curl -s "$PROM/api/v1/query" --data-urlencode "query=$1" ${2:+--data-urlencode "time=$2"} | jq -r '.data.result[0].value[1] // "none"'
}
# Every orders request makes exactly one orders server span (sampler ratio 1.0), so Tempo's span
# metrics counter vs k6's request count measures spans lost between the SDK and Tempo.
SPANS='sum(traces_spanmetrics_calls_total{service="orders",span_kind="SPAN_KIND_SERVER",span_name="POST /v1/orders"})'
# Reset-aware count between two instants: sum of positive steps per series, a drop counts as a restart
# from 0 (exact, unlike increase()'s extrapolation). M8 chaos run 1: Tempo restarted mid-run and a plain
# end-minus-start gave "-22,607 spans".
spans_between() { # t0 t1
  curl -s "$PROM/api/v1/query_range" --data-urlencode "query=${SPANS#sum}" --data-urlencode "start=$1" \
    --data-urlencode "end=$2" --data-urlencode step=15 | jq '[.data.result[].values | map(.[1] | tonumber)
    | [range(1; length) as $i | if .[$i] >= .[$i-1] then .[$i] - .[$i-1] else .[$i] end] | add // 0] | add // 0 | floor'
}
tempo_restarts() { kubectl -n monitoring get pod tempo-0 -o jsonpath='{.status.containerStatuses[0].restartCount}'; }

load() { # rate minutes label [chaos]
  local rate=$1 min=$2 label=$3 chaos=${4:-}
  kubectl -n freightline delete job k6-steady --ignore-not-found --wait >/dev/null
  kubectl -n freightline create configmap k6-steady --from-file=load/steady.js --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  local s0; s0=$(qat "$SPANS"); [ "$s0" = none ] && s0=0; local tr0; tr0=$(tempo_restarts)
  # k6 2.x's summary stops at p95 by default; ask for p99 (the SLO's percentile).
  sed -e "s/value: \"10\"/value: \"$rate\"/" -e "s/value: \"60s\"/value: \"${min}m\"/" \
      -e 's|"--quiet", |"--quiet", "--summary-trend-stats=avg,med,p(95),p(99),max", |' load/k6-job.yaml | kubectl apply -f - >/dev/null
  local t0; t0=$(date +%s); say "[$label] k6 started: target $rate req/s for $min min (orders server spans before: ${s0%.*})"
  local next=$(( t0 + 120 )) kills=0
  while ! kubectl -n freightline get job k6-steady -o jsonpath='{.status.conditions[*].type}' | grep -qE 'Complete|Failed'; do
    if [ -n "$chaos" ] && [ "$(date +%s)" -ge "$next" ] && [ "$(date +%s)" -lt $(( t0 + min * 60 - 30 )) ]; then
      local victim; victim=$(kubectl -n observability get pods -l app.kubernetes.io/instance=otel-gateway \
        --sort-by=.metadata.creationTimestamp -o name | head -1)
      kubectl -n observability delete "$victim" --wait=false >/dev/null; kills=$((kills+1))
      say "[$label] chaos: deleted $victim (#$kills)"; next=$(( next + 120 ))
    fi
    sleep 5
  done
  local t1; t1=$(date +%s)
  # CPU over the steady part of the run: skip the first minute (JIT, pools, connection set-up).
  local win=$(( t1 - t0 - 60 ))
  cpu() { qat "sum(rate(container_cpu_usage_seconds_total{namespace=\"freightline\",container=\"app\",pod=~\"$1-.*\"}[${win}s]))" "$t1"; }
  local cpu_o cpu_i cpu_gw series
  cpu_o=$(cpu orders); cpu_i=$(cpu inventory)
  cpu_gw=$(qat "sum(rate(container_cpu_usage_seconds_total{namespace=\"observability\",container!=\"\"}[${win}s]))" "$t1")
  # Head series include series gone stale since the last head compaction (~2 h): every rollout mints
  # new ones (service.instance.id is the pod UID). "Live" = has a sample in the last 5 min.
  series="$(qat 'prometheus_tsdb_head_series{job="kps-prometheus"}' "$t1" | cut -d. -f1) (live $(qat 'count({__name__=~".+"})' "$t1"))"
  kubectl -n freightline logs job/k6-steady > "/tmp/k6-$label.txt" 2>&1
  local reqs failed p99 dropped
  reqs=$(grep -oE 'http_reqs[ .:]+[0-9]+' "/tmp/k6-$label.txt" | grep -oE '[0-9]+$' | head -1)
  failed=$(grep -E 'http_req_failed' "/tmp/k6-$label.txt" | grep -oE '[0-9.]+%' | head -1)
  p99=$(grep -E 'http_req_duration\.\.' "/tmp/k6-$label.txt" | grep -oE 'p\(99\)=[0-9.]+[a-zµ]+' | head -1)
  dropped=$(grep -oE 'dropped_iterations[ .:]+[0-9]+' "/tmp/k6-$label.txt" | grep -oE '[0-9]+$' | head -1)
  sleep 90   # last spans: Python BSP 5 s, generator collection 15 s, remote write and scrape
  local spans; spans=$(spans_between $(( t0 - 30 )) "$(date +%s)")
  local tr1; tr1=$(tempo_restarts)
  [ "$tr1" != "$tr0" ] && say "[$label] WARNING Tempo restarted during the run ($tr0 -> $tr1): the generator's in-memory counts since its last remote write are lost, so the gap below overstates span loss"
  say "[$label] RESULT target=${rate}/s achieved=$(awk -v r="${reqs:-0}" -v m="$min" 'BEGIN{printf "%.1f", r/(m*60)}')/s requests=${reqs:-?} dropped_iterations=${dropped:-0} http_req_failed=${failed:-?} ${p99:-p99=?}"
  say "[$label] RESULT cpu cores: orders=$(printf %.4f "$cpu_o") inventory=$(printf %.4f "$cpu_i") observability-ns=$(printf %.3f "$cpu_gw") | head series=${series}"
  say "[$label] RESULT orders server spans in Tempo=$spans vs k6 requests=${reqs:-0}: gap $(awk -v s="$spans" -v r="${reqs:-0}" 'BEGIN{ if (r>0) printf "%.3f%%", (r-s)/r*100; else print "n/a"}')${chaos:+ (gateway pods deleted: $kills)}"
  echo "--- k6 summary ($label)"; grep -E 'http_req_duration|http_req_failed|http_reqs|dropped_iterations|checks' "/tmp/k6-$label.txt" | sed 's/^/   /'
  local v=${label//[^a-zA-Z0-9_]/_}; eval "CPU_O_$v=$cpu_o CPU_I_$v=$cpu_i"
}

sdk() { # true|false: OTEL_SDK_DISABLED on both services, through Helm
  bash app/deploy.sh --set "services.orders.env.OTEL_SDK_DISABLED=$1" --set "services.inventory.env.OTEL_SDK_DISABLED=$1" >/dev/null 2>&1 || say "helm upgrade FAILED"
  kubectl -n freightline rollout status deploy/orders --timeout=120s >/dev/null; kubectl -n freightline rollout status deploy/inventory --timeout=120s >/dev/null
  say "OTEL_SDK_DISABLED=$1 on orders and inventory (pods ready)"; sleep 30
}

case "${1:-}" in
  load) load "$2" "$3" "$4" ;;
  overhead)
    sdk false; load "$2" "$3" on
    sdk true;  load "$2" "$3" off
    sdk false
    for s in O I; do
      on=$(eval echo \$CPU_${s}_on); off=$(eval echo \$CPU_${s}_off)
      awk -v s="$s" -v a="$on" -v b="$off" 'BEGIN{ n=(s=="O"?"orders":"inventory"); printf "%s SDK overhead: on %.4f vs off %.4f cores = %+.1f%% (NFR < 5%%)\n", n, a, b, (a-b)/b*100 }'
    done ;;
  chaos) load "$2" "$3" chaos chaos ;;
  *) sed -n 2,8p "$0"; exit 2 ;;
esac
