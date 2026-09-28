#!/usr/bin/env bash
# M8 / NFR "customer sink < 60 s": time from POST /v1/orders to that order's log line in the customer
# sink (customer-sim's received-records file), with the Cobalt overlay on; then back to Beacon-only.
#   bash tests/m8-sink-freshness.sh [samples]
# Needs: customer-sim running, Secret observability/customer-splunk-hec (M7). Opens its own orders
# port-forward (PID recorded, stopped at the end).
set -uo pipefail
cd "$(dirname "$0")/.."
N=${1:-3}
say() { echo "$(date -u +%H:%M:%S) $*"; }
gw() { helm upgrade otel-gateway open-telemetry/opentelemetry-collector --version 0.173.1 -n observability "$@" >/dev/null &&
  kubectl -n observability rollout status deploy/otel-gateway --timeout=120s >/dev/null; }

say "== Cobalt overlay on (export-splunk-values.yaml)"
gw -f deploy/observability/otel-gateway-values.yaml -f deploy/observability/export-splunk-values.yaml || { say "helm upgrade FAILED"; exit 1; }
kubectl -n freightline port-forward svc/orders 18080:8080 >/dev/null 2>&1 & PF=$!
until curl -sf localhost:18080/healthz >/dev/null; do sleep 1; done
sleep 20   # new gateway pods: SDK and agent connections re-established

for i in $(seq "$N"); do
  t0=$(date +%s.%N)
  oid=$(curl -s -H "Idempotency-Key: m8-sink-$(date +%s)-$RANDOM" -H 'Content-Type: application/json' \
    -d '{"sku":"SKU-007","qty":1,"ship_to":"8 Sink Road","consignee_name":"M8 Freshness"}' localhost:18080/v1/orders | jq -r '.id // empty')
  [ -n "$oid" ] || { say "FAIL: no order id (port-forward?)"; break; }
  s=""; for _ in $(seq 120); do
    kubectl -n customer-sim exec deploy/customer-sim -c inspector -- grep -q "$oid" /received/logs.jsonl 2>/dev/null &&
      { s=$(awk -v a="$(date +%s.%N)" -v b="$t0" 'BEGIN{printf "%.1f", a-b}'); break; }
    sleep 0.5
  done
  say "sample $i: order $oid in the customer sink after ${s:-NOT within 60+ s} s (NFR < 60 s)"
  sleep 5
done

kill "$PF" 2>/dev/null
say "== back to Beacon-only (gateway values only)"
gw -f deploy/observability/otel-gateway-values.yaml && say "gateway rolled back to Beacon-only" || say "rollback FAILED"
