#!/usr/bin/env bash
# M0 gate (P04-lite): the app answers POST /v1/orders and /readyz is green on every service.
# Extra checks: idempotency, the REJECTED path, and one trace_id in both services' logs
# (W3C trace context crosses Go -> Python, which M3-M5 rely on).
#
# Needs port-forwards (run each in the background):
#   kubectl -n freightline port-forward svc/orders 18080:8080
#   kubectl -n freightline port-forward svc/inventory 18081:8080
#   kubectl -n freightline port-forward svc/mailpit 18025:8025
set -uo pipefail
ORDERS="${ORDERS_URL:-http://localhost:18080}"
INVENTORY="${INVENTORY_URL:-http://localhost:18081}"
MAILPIT="${MAILPIT_URL:-http://localhost:18025}"
NS=freightline
pass=0; fail=0
check() { # name, expected, actual
  if [ "$2" = "$3" ]; then echo "PASS  $1 ($3)"; pass=$((pass+1)); else echo "FAIL  $1: expected $2, got $3"; fail=$((fail+1)); fi
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "== readiness"
check "orders /readyz" 200 "$(code "$ORDERS/readyz")"
check "inventory /readyz" 200 "$(code "$INVENTORY/readyz")"
check "mailpit /readyz" 200 "$(code "$MAILPIT/readyz")"
check "postgres pg_isready" 0 "$(kubectl -n $NS exec postgres-0 -- pg_isready -q -h 127.0.0.1; echo $?)"

echo "== POST /v1/orders"
key="m0-$(date +%s)-$RANDOM"
body='{"sku":"SKU-001","qty":1,"ship_to":"1 Test Street, Lab City","consignee_name":"Test Consignee"}'
resp=$(curl -s -D /tmp/m0-headers.$$ -H "Idempotency-Key: $key" -H 'Content-Type: application/json' -d "$body" "$ORDERS/v1/orders")
check "status code" 202 "$(awk 'NR==1{print $2}' /tmp/m0-headers.$$)"
id=$(jq -r .id <<<"$resp")
check "Location header" "/v1/orders/$id" "$(awk 'tolower($1)=="location:"{print $2}' /tmp/m0-headers.$$ | tr -d '\r')"
check "order confirmed by inventory" CONFIRMED "$(jq -r .status <<<"$resp")"
rm -f /tmp/m0-headers.$$

replay=$(curl -s -H "Idempotency-Key: $key" -H 'Content-Type: application/json' -d "$body" "$ORDERS/v1/orders")
check "replay returns the same order" "$id" "$(jq -r .id <<<"$replay")"
check "GET /v1/orders/{id}" 200 "$(code "$ORDERS/v1/orders/$id")"
check "missing Idempotency-Key" 400 "$(code -H 'Content-Type: application/json' -d "$body" "$ORDERS/v1/orders")"
rej=$(curl -s -H "Idempotency-Key: $key-rej" -H 'Content-Type: application/json' -d '{"sku":"SKU-000","qty":1,"ship_to":"x","consignee_name":"x"}' "$ORDERS/v1/orders")
check "out-of-stock order rejected" REJECTED "$(jq -r .status <<<"$rej")"

echo "== trace context crosses Go -> Python"
sleep 1
tid=$(kubectl -n $NS logs -l app.kubernetes.io/name=orders --tail=200 | jq -r --arg id "$id" 'select(.order_id==$id and .msg=="order accepted") | .trace_id' 2>/dev/null | head -1)
check "orders log line has a trace_id" 32 "${#tid}"
inv=$(kubectl -n $NS logs -l app.kubernetes.io/name=inventory --tail=200 | jq -r --arg t "$tid" 'select(.trace_id==$t) | .msg' 2>/dev/null | head -1)
check "inventory logged the same trace_id" "stock reserved" "$inv"
echo "   trace_id=$tid order_id=$id"

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
