# Architecture (as built)

The target is spec section 3. This file tracks what exists today; `[x]` means built and gated.

```text
 ZONE: workloads (ns freightline, PSA restricted)       ZONE: pipeline (ns observability)
 +-----------------------------------------+   OTLP    +---------------------------------------+
 | [x] orders (Go)  --HTTP+traceparent-->  |   :4317   | [ ] otel-gateway (contrib 0.161, x2)  |
 | [x] inventory (Python)                  |---------->|     memory_limiter > k8s_attributes > |
 |     SDK traces + metrics (OTLP/gRPC)    |  (M4; the |     resource > exporters with         |
 |     stdout JSON logs (trace_id,span_id) |  exporters|     sending_queue.batch               |
 | [x] postgres (1 instance, db per svc)   |  drop data+---------------------------------------+
 | [x] mailpit (SMTP sink for alerts)      |  until then)
 +-------------------+---------------------+
                     | /var/log/pods
 +-------------------v---------------------+
 | [ ] otel-agent DaemonSet (M4)           |
 +-----------------------------------------+
 ZONE: backends (ns monitoring)   [ ] Prometheus "kps" (M2)  [ ] Tempo, Loki (M3)  [ ] Grafana (M2/M5)
 TRUST BOUNDARY: customer egress  [ ] export overlay + customer-sim + proxy-sim (M7)

 Runtime: kind "freightline", 1 node, Kubernetes v1.36.4, containerd 2.3.4 (Tier A)
```

## Signal routing

| Signal | Emitted by | Transport today | Target path (milestone) |
|---|---|---|---|
| Traces | orders (OTel Go SDK + otelhttp + otelpgx), inventory (`opentelemetry-instrument`: FastAPI, psycopg) | OTLP/gRPC to `otel-gateway.observability:4317`, **not listening yet**, so spans are dropped | gateway → Tempo (M3/M4) |
| Metrics | same SDKs: `http.server.request.duration` (s), DB client metrics | same as traces | gateway → Prometheus OTLP receiver (M2/M4) |
| Logs | stdout JSON with `trace_id`, `span_id`, lowercase `level` | container runtime log files on the node | agent `file_log` → gateway → Loki (M3/M4) |
| Alerts | — | — | Alertmanager → Mailpit `page@` / `ticket@` (M2/M6) |

## App contract (set only by the library chart)

`OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES=service.namespace=freightline,deployment.environment.name=kind,service.version=<tag>`, `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-gateway.observability:4317`, `OTEL_EXPORTER_OTLP_PROTOCOL=grpc`, `OTEL_SEMCONV_STABILITY_OPT_IN=http,database`, `OTEL_TRACES_SAMPLER=parentbased_traceidratio` (`1.0`), `OTEL_LOGS_EXPORTER=none`. M1 adds `service.instance.id=$(POD_UID)` and `OTEL_METRICS_EXEMPLAR_FILTER=trace_based`.
