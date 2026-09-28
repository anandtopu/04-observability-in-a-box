# Runbook: orders SLO burn (OrdersAvailabilityBurn, OrdersLatencyBurn, OrdersMetricsAbsent)

**Alerts:** `OrdersAvailabilityBurn` / `OrdersLatencyBurn` with `severity=page` or `severity=ticket` (Sloth, `deploy/observability/slo/`), and `OrdersMetricsAbsent` (page, `deploy/observability/pipeline-alerts.yaml`).
**SLOs (30 days):** availability 99.9% (non-5xx) and latency 99% within 250 ms, over all `freightline/orders` requests.

## What the page means

| Severity | Fires when | Budget impact | Your job |
|---|---|---|---|
| page | burn ≥ 14.4× over **1 h and 5 m**, or ≥ 6× over **6 h and 30 m** | 2% (1 h) or 5% (6 h) of the monthly budget already gone, **and still burning** (the short window) | act now |
| ticket | burn ≥ 3× over 1 d and 2 h, or ≥ 1× over 3 d and 6 h | on course to spend the whole budget this month | next working day |

Detection time from a clean history is about `60 × 14.4 / B` minutes: a 50% error burst (B = 500) pages in under 2 minutes, 2% errors (B = 20) in about 43 minutes, every request over 250 ms (B = 100) in about 9 minutes. A steady 0.1% (1×) never pages. Measured in M6: `docs/evidence/p04/m6-burn-tests.txt`.

## First 5 minutes

1. **Is it real traffic?** Grafana → *Freightline / RED*, `service = freightline/orders`. Error ratio and p99 should show the burn. If `OrdersMetricsAbsent` is firing instead, skip to "No metrics" below.
2. **Follow an exemplar.** On *Latency p50 / p99*, click a dot near the spike → the Tempo trace opens. Look at which span holds the time (the M5 walk-through: `UPDATE` in inventory took 43 of 50 ms).
3. **Read that request's logs.** In the trace, *Logs for this span* runs `{service_name=…} | trace_id="…"` in Loki. For 5xx look for `injected fault`, `insert order`, `db pool exhausted` (inventory 503, the P04 incident), `inventory precheck degraded` (orders accepted as PENDING, not an error).
4. **Was there a deploy?** The purple *Rollouts* annotation marks a new pod-template hash for the job. If a canary (P03) is live, switch to P03's abort runbook; a rollback is the fastest mitigation.
5. **Check the fault hooks** (lab and staging only): `kubectl -n freightline get deploy orders -o jsonpath='{.spec.template.spec.containers[0].env}' | jq -c '.[] | select(.name|startswith("FAULT_"))'`. Non-zero `FAULT_5XX_RATE` / `FAULT_LATENCY_*` explains the burn.

## Mitigate

- Roll back the last rollout (P03), or `bash app/deploy.sh` with the previous values.
- Inventory pool exhausted (`db pool exhausted`, reservation 503s on *Freightline / Flow*): raise `services.inventory.env.DB_POOL_MAX` through Helm values, then fix the slow query the trace shows.
- Never `kubectl scale` / `kubectl set env` a Helm-managed workload: Helm 4's server-side apply will conflict on the next upgrade (BUILD_LOG M1).

## If the trace-to-logs link is empty

- The line has no `trace_id` in structured metadata: the agent's `json_parser` did not lift it (check `kubectl -n observability logs ds/otel-agent-agent`).
- `service_name` is missing: the pod lost its `app.kubernetes.io/name` label, which the agent maps to `service.name`.

## No metrics (`OrdersMetricsAbsent`)

`target_info{job="freightline/orders"}` has not arrived for 10 minutes: orders is down, cannot reach `otel-gateway.observability:4317`, or the gateway cannot write to Prometheus. Check, in order: orders pods (`kubectl -n freightline get pods`), orders logs for `failed to upload metrics`, gateway self-metrics (`TelemetryExportFailing`, `TelemetryRefused`), then the queue runbook. After the gateway Service is recreated, Go clients can take 2–3 minutes to re-resolve DNS (BUILD_LOG M2).

## After

Resolution is automatic once the short window (5 m or 30 m) is clean, typically within minutes of the fix (measured in M6). Record the budget spent (`slo:period_error_budget_remaining:ratio`) in the incident review.
