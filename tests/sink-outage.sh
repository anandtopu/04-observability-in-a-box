#!/usr/bin/env bash
# M7: export parity and sink outage (spec section 7): a 30-min k6 run with customer-sim scaled to 0 for
# 10 min. Pass: Loki and Splunk exporter counts within 0.1% over the run, no enqueue failures,
# queue drains in < 5 min after the sink returns.
# customer-sim is scaled with kubectl: the upstream chart drops `replicas` when replicaCount is 0
# (DEVIATIONS D-28). Ending on 1 (the chart's value) leaves the field co-owned, so Helm won't conflict.
# Needs the Prometheus port-forward on :9090. Durations (minutes): RUN=30 DOWN_AT=5 DOWN_FOR=10
set -uo pipefail
cd "$(dirname "$0")/.."
PROM=http://localhost:9090; RUN=${RUN:-30}; DOWN_AT=${DOWN_AT:-5}; DOWN_FOR=${DOWN_FOR:-10}
say() { echo "$(date -u +%H:%M:%S) $*"; }
q() { curl -s "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "0"'; }
qsize() { q 'sum(otelcol_exporter_queue_size{job="otel-gateway",exporter="splunk_hec/cobalt"})'; }
restarts() { kubectl -n observability get pods -l app.kubernetes.io/instance=otel-gateway -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[0].restartCount} {end}'; }

say "== start: gateway pods $(restarts)"
kubectl -n freightline delete job k6-steady --ignore-not-found >/dev/null
kubectl -n freightline create configmap k6-steady --from-file=load/steady.js --dry-run=client -o yaml | kubectl apply -f - >/dev/null
sed "s/value: \"60s\"/value: \"${RUN}m\"/" load/k6-job.yaml | kubectl apply -f - >/dev/null
t0=$(date +%s); say "k6 started: 10 req/s for ${RUN} min"

sample_until() { # epoch
  while [ "$(date +%s)" -lt "$1" ]; do
    echo "   +$(( ($(date +%s) - t0) / 60 ))m$(( ($(date +%s) - t0) % 60 ))s queue(splunk items)=$(qsize) capacity=$(q 'max(otelcol_exporter_queue_capacity{exporter="splunk_hec/cobalt"})') send_failed=$(q 'sum(otelcol_exporter_send_failed_log_records{exporter="splunk_hec/cobalt"}) or vector(0)') enqueue_failed=$(q 'sum(otelcol_exporter_enqueue_failed_log_records) or vector(0)')"
    sleep 30
  done
}
sample_until $(( t0 + DOWN_AT * 60 ))
kubectl -n customer-sim scale deploy/customer-sim --replicas=0 >/dev/null; tdown=$(date +%s); say "== OUTAGE: customer-sim scaled to 0"
sample_until $(( tdown + DOWN_FOR * 60 ))
peak=$(qsize)
kubectl -n customer-sim scale deploy/customer-sim --replicas=1 >/dev/null; kubectl -n customer-sim rollout status deploy/customer-sim --timeout=120s >/dev/null
tup=$(date +%s); say "== RECOVERY: customer-sim back (ready); queue at ${peak} items"
drain=""
while [ "$(date +%s)" -lt $(( tup + 600 )) ]; do
  s=$(qsize); [ "$s" = "0" ] && { drain=$(( $(date +%s) - tup )); break; }; sleep 5
done
say "queue drained to 0 in ${drain:-NOT within 10 min}s after the sink returned (Prometheus scrape interval 30 s bounds the precision)"
sample_until $(( t0 + RUN * 60 + 60 ))
sleep 60   # last batches flushed and scraped

win=$(( $(date +%s) - t0 + 60 ))
loki=$(q "sum(increase(otelcol_exporter_sent_log_records{exporter=\"otlp_http/loki\"}[${win}s]))")
splunk=$(q "sum(increase(otelcol_exporter_sent_log_records{exporter=\"splunk_hec/cobalt\"}[${win}s]))")
recv=$(q "sum(increase(otelcol_receiver_accepted_log_records{job=\"otel-gateway\"}[${win}s]))")
say "== PARITY over the run (${win}s window): received by gateway=${recv%.*} sent to Loki=${loki%.*} sent to Splunk=${splunk%.*}"
awk -v l="$loki" -v s="$splunk" 'BEGIN{d=(l>s?l-s:s-l)/l*100; printf "   difference %.4f%% (pass < 0.1%%): %s\n", d, (d<0.1?"PASS":"FAIL")}'
echo "   the spec's query, corrected names (D-20): sum by (exporter) (increase(otelcol_exporter_sent_log_records[30m]))"
curl -s "$PROM/api/v1/query" --data-urlencode 'query=sum by (exporter) (increase(otelcol_exporter_sent_log_records{job="otel-gateway"}[30m]))' | jq -r '.data.result[] | "     \(.metric.exporter) \(.value[1] | tonumber | floor)"'
say "send_failed (splunk)=$(q 'sum(otelcol_exporter_send_failed_log_records{exporter="splunk_hec/cobalt"}) or vector(0)') enqueue_failed (all)=$(q 'sum(otelcol_exporter_enqueue_failed_log_records) or vector(0)')"
say "== end: gateway pods $(restarts) (a restart would have emptied the emptyDir queue)"
kubectl -n freightline delete job k6-steady --ignore-not-found >/dev/null
