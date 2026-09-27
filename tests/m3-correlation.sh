#!/usr/bin/env bash
# M3 gate (build prompt): one trace and one log line found by the same trace_id.
# Takes a real "order accepted" line from orders' stdout, posts it through the gateway's OTLP/HTTP
# logs endpoint (the path the M4 agent will use), then finds the trace in Tempo and the line in Loki
# by that trace_id. Also checks that Tempo's metrics-generator writes span metrics and the service
# graph into Prometheus.
# Needs port-forwards: otel-gateway 4318, loki 3100, tempo 3200, kps-prometheus 9090.
#   kubectl -n observability port-forward svc/otel-gateway 4318:4318
#   kubectl -n monitoring port-forward svc/loki 3100:3100
#   kubectl -n monitoring port-forward svc/tempo 3200:3200
#   kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090
set -uo pipefail
GW="${GW_URL:-http://localhost:4318}"; LOKI="${LOKI_URL:-http://localhost:3100}"
TEMPO="${TEMPO_URL:-http://localhost:3200}"; PROM="${PROM_URL:-http://localhost:9090}"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1 ($3)"; pass=$((pass+1)); else echo "FAIL  $1: expected $2, got $3"; fail=$((fail+1)); fi; }
atleast() { if [ "${3:-0}" -ge "$2" ] 2>/dev/null; then echo "PASS  $1 ($3 >= $2)"; pass=$((pass+1)); else echo "FAIL  $1: expected >= $2, got ${3:-none}"; fail=$((fail+1)); fi; }

pod=$(kubectl -n freightline get pod -l app.kubernetes.io/name=orders -o jsonpath='{.items[0].metadata.name}')
uid=$(kubectl -n freightline get pod "$pod" -o jsonpath='{.metadata.uid}')
line=$(kubectl -n freightline logs "$pod" --tail=500 | jq -c 'select(.msg=="order accepted" and .trace_id != null)' | tail -1)
tid=$(jq -r .trace_id <<<"$line"); sid=$(jq -r .span_id <<<"$line")
echo "== source: $pod, trace_id=$tid span_id=$sid"
check "log line has a 32-hex trace_id" 32 "${#tid}"

echo "== trace in Tempo"
trace=$(curl -s "$TEMPO/api/v2/traces/$tid")
spans=$(jq '[.trace.resourceSpans[]?.scopeSpans[]?.spans[]?] | length' <<<"$trace" 2>/dev/null)
svcs=$(jq -r '[.trace.resourceSpans[]?.resource.attributes[]? | select(.key=="service.name") | .value.stringValue] | unique | join(",")' <<<"$trace" 2>/dev/null)
atleast "Tempo returns the trace's spans" 5 "$spans"
check "trace contains both services" "inventory,orders" "$svcs"

echo "== log line through the gateway's OTLP/HTTP endpoint into Loki (stand-in for the M4 agent)"
ts_ns=$(date -d "$(jq -r .time <<<"$line")" +%s%N)
payload=$(jq -n --arg body "$line" --arg tid "$tid" --arg sid "$sid" --arg uid "$uid" --arg ts "$ts_ns" '{
  resourceLogs: [{
    resource: { attributes: [
      {key:"service.name", value:{stringValue:"orders"}},
      {key:"service.namespace", value:{stringValue:"freightline"}},
      {key:"service.instance.id", value:{stringValue:$uid}} ] },
    scopeLogs: [{ scope: {name:"m3-correlation-test"}, logRecords: [{
      timeUnixNano: $ts, observedTimeUnixNano: $ts, severityNumber: 9, severityText: "info",
      body: {stringValue: $body}, traceId: $tid, spanId: $sid }] }] }] }')
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d "$payload" "$GW/v1/logs")
check "gateway accepted the log record" 200 "$code"
found=""
for _ in $(seq 20); do
  found=$(curl -s -G "$LOKI/loki/api/v1/query_range" --data-urlencode "query={service_name=\"orders\"} | trace_id=\"$tid\"" \
    --data-urlencode "start=$(( $(date +%s) - 900 ))000000000" --data-urlencode 'limit=5' | jq -r '.data.result[0].values[0][1] // empty')
  [ -n "$found" ] && break; sleep 1
done
check "Loki finds the line by trace_id" "$tid" "$(jq -r .trace_id <<<"$found" 2>/dev/null)"
labels=$(curl -s -G "$LOKI/loki/api/v1/query_range" --data-urlencode "query={service_name=\"orders\"} | trace_id=\"$tid\"" \
  --data-urlencode "start=$(( $(date +%s) - 900 ))000000000" --data-urlencode 'limit=1' | jq -c '.data.result[0].stream')
echo "   stream + structured metadata: $labels"
check "trace_id is NOT an index label" "false" "$(curl -s "$LOKI/loki/api/v1/labels" | jq '.data | index("trace_id") != null')"

echo "== Tempo metrics-generator -> Prometheus (remote write)"
q() { curl -s "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result | length'; }
atleast "span metrics (traces_spanmetrics_calls_total) series" 1 "$(q 'traces_spanmetrics_calls_total{service="orders"}')"
atleast "service graph edge orders -> inventory" 1 "$(q 'traces_service_graph_request_total{client="orders",server="inventory"}')"
ex=$(curl -s "$PROM/api/v1/query_exemplars" --data-urlencode 'query=traces_spanmetrics_latency_bucket{service="orders"}' \
  --data-urlencode "start=$(( $(date +%s) - 900 ))" --data-urlencode "end=$(date +%s)" | jq '[.data[].exemplars[]] | length')
atleast "span-metrics exemplars (send_exemplars: true)" 1 "$ex"

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
