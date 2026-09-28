# Runbook: telemetry pipeline (TelemetryQueueFilling, TelemetryExportFailing, TelemetryRefused)

**Alerts** (`deploy/observability/pipeline-alerts.yaml`, from the gateway's own `otelcol_*` metrics):

| Alert | Meaning | Severity |
|---|---|---|
| TelemetryQueueFilling | an exporter's `sending_queue` is above 80% of capacity for 10 min | page: when full, new data is **rejected** (`block_on_overflow` defaults to false); loss is minutes away |
| TelemetryExportFailing | an exporter's send failures are non-zero for 10 min | ticket; page for a contractual customer sink (M7) |
| TelemetryRefused | a receiver is refusing data, usually `memory_limiter` pushback | ticket |

Collector 0.161 metric names have **no `_total` suffix** (`otelcol_exporter_send_failed_log_records`, not `…_total`); `send_failed_*` series only exist after a first failure (DEVIATIONS D-20).

## First 5 minutes

1. **Which exporter?** The alert's `exporter` label: `otlp_grpc/tempo`, `otlp_http/prometheus`, `otlp_http/loki`, or a customer exporter (M7: `splunk_hec/cobalt`).
2. **Why is it failing?** `kubectl -n observability logs deploy/otel-gateway --since=15m | grep 'Exporting failed'`. The retry line is logged at **INFO**, not WARN/ERROR, so a level filter misses it (M7); its `error` field names the cause.
   - `connection refused` / `no such host` to an in-cluster backend: the backend is down (`kubectl -n monitoring get pods`).
   - **TLS or connection errors to the customer sink mean proxy or CA** (reproduced in M7, `docs/evidence/p04/m7-proxy.txt`). `x509: certificate signed by unknown authority`: the proxy re-signs TLS with the customer's CA; mount it and set `tls.ca_file`. In-cluster calls sent to the proxy: `NO_PROXY` must cover every in-cluster name the gateway uses. `.svc,.cluster.local` is **not** enough for short names like `tempo.monitoring` (gRPC honours `HTTPS_PROXY`); add the namespace suffixes and the service/pod CIDRs (M7, D-31). The proxy's own log is the quickest check: in-cluster hosts must never appear in it. Test from the gateway's network with the customer's network team. **Never set `insecure_skip_verify`.**
   - HTTP 4xx from the sink (401/403): token or index permissions; the token is the `customer-splunk-hec` Secret, never in values.
3. **How long do we have?** `max by (exporter) (otelcol_exporter_queue_size / otelcol_exporter_queue_capacity)` in Prometheus, and its slope. Capacity: 1000 batches per in-cluster exporter per replica; 200,000 log records for the customer exporter in export mode (D-29: the default 1000 batches overflows in ~5.4 min of sink outage at 10 req/s).
4. **Tell the customer's SOC the affected window first** if data will be lost or late: the start of the failures to now, per signal. They treat missing logs as an incident of their own.

## Refused data (`TelemetryRefused`)

The gateway is above its `memory_limiter` threshold (80% of its 1 GiB limit) and is protecting itself: senders retry, nothing crashes. Check `container_memory_working_set_bytes{namespace="observability"}` (*Freightline / USE*, namespace `observability`). Causes: a traffic spike, a stuck exporter filling its queue (fix that first), or a cardinality explosion in one pipeline. Mitigate by scaling the gateway (`replicaCount`) through Helm values, never by raising the limit above the node's headroom.

## After

Queues drain on their own once the sink recovers (M7 measures the drain time after a 10-minute sink outage). With the persistent queue (`file_storage`, M7 export mode) a **container restart** does not lose queued data. A **rollout** does, while the queue sits on an emptyDir: new pods get new, empty volumes (M7 lost 3,866 queued records this way while fixing the CA). Fix the cause first, wait for the queue to drain, then roll out; in production run the gateway as a StatefulSet with a PVC (D-32).
