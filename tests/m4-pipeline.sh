#!/usr/bin/env bash
# M4 end-to-end checks on the real pipeline (apps -> agent/gateway -> Prometheus, Tempo, Loki).
#   bash tests/m4-pipeline.sh            # correlation, enrichment, freshness, self-metrics
#   bash tests/m4-pipeline.sh idle-gate  # the spec's idle gate only (run after >= 5 min without traffic)
# Needs port-forwards: orders 18080, kps-prometheus 9090, loki 3100, tempo 3200.
set -uo pipefail
ORDERS="${ORDERS_URL:-http://localhost:18080}"; PROM="${PROM_URL:-http://localhost:9090}"
LOKI="${LOKI_URL:-http://localhost:3100}"; TEMPO="${TEMPO_URL:-http://localhost:3200}"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1 ($3)"; pass=$((pass+1)); else echo "FAIL  $1: expected $2, got $3"; fail=$((fail+1)); fi; }
atleast() { if [ "${3:-0}" -ge "$2" ] 2>/dev/null; then echo "PASS  $1 ($3 >= $2)"; pass=$((pass+1)); else echo "FAIL  $1: expected >= $2, got ${3:-none}"; fail=$((fail+1)); fi; }
below() { if awk -v a="${3:-999}" -v b="$2" 'BEGIN{exit !(a < b)}'; then echo "PASS  $1 (${3}s < ${2}s)"; pass=$((pass+1)); else echo "FAIL  $1: expected < ${2}s, got ${3:-none}"; fail=$((fail+1)); fi; }
pq() { curl -s "$PROM/api/v1/query" --data-urlencode "query=$1"; }

if [ "${1:-}" = "idle-gate" ]; then
  echo "== spec M4 gate: idle traffic reads 0 for every Freightline job (probe filter works end to end)"
  echo '$ curl -s localhost:9090/api/v1/query --data-urlencode '"'"'query=sum by (job) (rate(http_server_request_duration_seconds_count{job=~"freightline/.*"}[5m]))'"'"
  r=$(pq 'sum by (job) (rate(http_server_request_duration_seconds_count{job=~"freightline/.*"}[5m]))')
  echo "$r"
  for job in freightline/orders freightline/inventory; do
    check "idle rate for $job" 0 "$(jq -r --arg j "$job" '.data.result[] | select(.metric.job==$j) | .value[1]' <<<"$r")"
  done
  echo "== $pass passed, $fail failed"; [ "$fail" -eq 0 ]; exit
fi

echo "== spec M4 gate (logs): an orders log line carries a trace ID (one stream returned)"
echo '$ curl -s -G localhost:3100/loki/api/v1/query_range --data-urlencode '"'"'query={service_name="orders"} | trace_id != ""'"'"' --data-urlencode '"'"'limit=1'"'"
r=$(curl -s -G "$LOKI/loki/api/v1/query_range" --data-urlencode 'query={service_name="orders"} | trace_id != ""' --data-urlencode 'limit=1')
jq -c '{status, streams: (.data.result | length), stream: .data.result[0].stream | {service_name, k8s_namespace_name, k8s_pod_name, trace_id, span_id, severity_text}}' <<<"$r"
check "streams returned" 1 "$(jq '.data.result | length' <<<"$r")"

echo "== one request, followed through every backend (freshness = time until queryable)"
key="m4-$(date +%s)-$RANDOM"; t0=$(date +%s.%N)
resp=$(curl -s -H "Idempotency-Key: $key" -H 'Content-Type: application/json' \
  -d '{"sku":"SKU-007","qty":1,"ship_to":"7 Probe Road","consignee_name":"M4 Freshness"}' "$ORDERS/v1/orders")
oid=$(jq -r '.id // empty' <<<"$resp" 2>/dev/null); echo "   order_id=${oid:-none}"
# Without an order ID every later query would match any line and report a fake "0 s" (M4 finding).
[ -n "$oid" ] || { echo "FAIL  POST /v1/orders returned no id (is the orders port-forward up?)"; exit 1; }
line=""; loki_s=""
for _ in $(seq 120); do
  line=$(curl -s -G "$LOKI/loki/api/v1/query_range" --data-urlencode "query={service_name=\"orders\"} |= \"$oid\"" \
    --data-urlencode "start=$(( ${t0%.*} - 60 ))000000000" --data-urlencode 'limit=1' | jq -r '.data.result[0] // empty')
  [ -n "$line" ] && { loki_s=$(awk -v a="$(date +%s.%N)" -v b="$t0" 'BEGIN{printf "%.1f", a-b}'); break; }
  sleep 0.5
done
below "Loki freshness (NFR < 15 s)" 15 "$loki_s"
tid=$(jq -r '.stream.trace_id' <<<"$line"); body=$(jq -r '.values[0][1]' <<<"$line")
check "trace_id lifted into structured metadata equals the one in the JSON body" "$(jq -r .trace_id <<<"$body")" "$tid"
check "severity parsed from the JSON level" "info" "$(jq -r '.stream.severity_text' <<<"$line")"
check "service_name from the pod label (agent k8s_attributes)" "orders" "$(jq -r '.stream.service_name' <<<"$line")"
# A trace is "fresh" when it is complete: orders alone has 6 spans, and inventory's Python
# BatchSpanProcessor exports up to OTEL_BSP_SCHEDULE_DELAY (5 s) later (M4 finding).
tempo_s=""; svcs=""
for _ in $(seq 120); do
  svcs=$(curl -s "$TEMPO/api/v2/traces/$tid" | jq -r '[.trace.resourceSpans[]?.resource.attributes[]? | select(.key=="service.name") | .value.stringValue] | unique | join(",")' 2>/dev/null)
  [ "$svcs" = "inventory,orders" ] && { tempo_s=$(awk -v a="$(date +%s.%N)" -v b="$t0" 'BEGIN{printf "%.1f", a-b}'); break; }
  sleep 0.5
done
check "the log line's trace has both services" "inventory,orders" "$svcs"
below "Tempo freshness (complete trace queryable)" 30 "$tempo_s"
age=$(pq 'time() - max(timestamp(target_info{job="freightline/orders"}))' | jq -r '.data.result[0].value[1] | tonumber | . * 10 | floor / 10')
below "metrics freshness: newest orders sample age (NFR < 30 s)" 30 "$age"

echo "== gateway enrichment on metrics (k8s_attributes -> promoted labels)"
m=$(pq 'http_server_request_duration_seconds_count{job="freightline/orders"}' | jq -r '.data.result[-1].metric')
check "k8s_namespace_name promoted" freightline "$(jq -r .k8s_namespace_name <<<"$m")"
check "k8s_pod_name promoted" "$(kubectl -n freightline get pod -l app.kubernetes.io/name=orders -o jsonpath='{.items[0].metadata.name}')" "$(jq -r .k8s_pod_name <<<"$m")"

echo "== the pipeline's own metrics (gateway ServiceMonitor)"
# Collector 0.161 counters have no _total suffix, and send_failed_* series appear only after the
# first failure (spec section 8 uses *_total names: they would never match; DEVIATIONS D-20).
atleast "gateway targets scraped (2 replicas)" 2 "$(pq 'count(up{job="otel-gateway"} == 1)' | jq -r '.data.result[0].value[1] // 0')"
for e in otlp_grpc/tempo otlp_http/prometheus otlp_http/loki; do
  sent=$(pq "sum(otelcol_exporter_sent_spans{exporter=\"$e\"} or otelcol_exporter_sent_metric_points{exporter=\"$e\"} or otelcol_exporter_sent_log_records{exporter=\"$e\"})" | jq -r '.data.result[0].value[1] // 0 | tonumber | floor')
  atleast "items sent by $e" 1 "$sent"
done
check "send failures (all exporters)" 0 "$(pq 'sum(otelcol_exporter_send_failed_spans or otelcol_exporter_send_failed_metric_points or otelcol_exporter_send_failed_log_records) or vector(0)' | jq -r '.data.result[0].value[1] | tonumber | floor')"
check "refused by receivers (all signals)" 0 "$(pq 'sum(otelcol_receiver_refused_spans or otelcol_receiver_refused_metric_points or otelcol_receiver_refused_log_records) or vector(0)' | jq -r '.data.result[0].value[1] | tonumber | floor')"

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
