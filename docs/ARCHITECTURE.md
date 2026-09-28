# Architecture (as built)

The target is spec section 3. This file tracks what exists today; `[x]` means built and gated.

```text
 ZONE: workloads (ns freightline, PSA restricted)       ZONE: pipeline (ns observability)
 +-----------------------------------------+   OTLP    +---------------------------------------+
 | [x] orders (Go)  --HTTP+traceparent-->  |   :4317   | [x] otel-gateway (contrib 0.161, x2, PDB) |
 | [x] inventory (Python)                  |---------->|     memory_limiter (80%/25% of 1Gi) >     |
 |     SDK traces + metrics (OTLP/gRPC,    |           |     k8s_attributes (pod UID, then IP) >   |
 |     metrics every 15 s)                 |           |     resource (k8s.cluster.name) >         |
 |     stdout JSON logs (trace_id,span_id) |           |     otlp_grpc/tempo, otlp_http/prometheus,|
 | [x] postgres (1 instance, db per svc)   |           |     otlp_http/loki (sending_queue.batch)  |
 | [x] mailpit (SMTP sink for alerts)      |           |     :8888 otelcol_* -> ServiceMonitor     |
 +-------------------+---------------------+           +-------------------------------------------+
                     | /var/log/pods/freightline_*/app/*.log                ^ OTLP/gRPC
 +-------------------v-----------------------------------------------------+-+
 | [x] otel-agent DaemonSet: file_log > container parser > json_parser    |
 |     (severity from level; trace_id/span_id -> record) > memory_limiter |
 |     > k8s_attributes (pod UID; label app.kubernetes.io/name ->         |
 |     service.name) > otlp_grpc                                          |
 +------------------------------------------------------------------------+
 ZONE: backends (ns monitoring)   [x] Prometheus "kps" 3.14.0: OTLP receiver, exemplars, 12h (M2)
                                  [x] Alertmanager: page / ticket -> Mailpit, Watchdog -> null (M2)
                                  [x] Grafana 13.2.2 (datasources for Tempo/Loki pre-provisioned) (M2)
                                  [x] Tempo 3.0.3 monolithic: OTLP :4317, query :3200, metrics-generator
                                      (span-metrics, service-graphs) -> remote write + exemplars -> Prometheus (M3)
                                  [x] Loki 3.7.8 monolithic: OTLP /otlp :3100, trace_id/span_id as
                                      structured metadata, service_name indexed, 12h retention (M3)
                                  [ ] kube-state-metrics (D-14)
 TRUST BOUNDARY: customer egress  [ ] export overlay + customer-sim + proxy-sim (M7)

 Runtime: kind "freightline", 1 node, Kubernetes v1.36.4, containerd 2.3.4 (Tier A)
```

## Signal routing

| Signal | Emitted by | Transport today | Target path (milestone) |
|---|---|---|---|
| Traces | orders (OTel Go SDK + otelhttp + otelpgx), inventory (FastAPI instrumented in code; psycopg via `opentelemetry-instrument`) | OTLP/gRPC to `otel-gateway.observability:4317` (the gateway arrives in M4; until then spans are dropped) | gateway `otlp_grpc/tempo` → `tempo.monitoring:4317`; Tempo's metrics-generator writes `traces_spanmetrics_*` and `traces_service_graph_*` (with exemplars) to Prometheus (backend live since M3) |
| Metrics | same SDKs, every 15 s: `http.server.request.duration` (s) with `http.route`, DB client metrics | same as traces | gateway → `http://kps-prometheus.monitoring:9090/api/v1/otlp` (receiver live since M2; the gateway arrives in M4). In PromQL: `http_server_request_duration_seconds_*{job="freightline/<svc>", instance="<pod uid>"}` plus promoted labels `service_version`, `deployment_environment_name`, `freightline_pod_template_hash` (`k8s_namespace_name`, `k8s_pod_name` arrive with the gateway's `k8s_attributes`); other resource attributes on `target_info` |
| Logs | stdout JSON with `trace_id`, `span_id`, lowercase `level` | container runtime log files on the node | agent `file_log` → gateway `otlp_http/loki` → `http://loki.monitoring:3100/otlp` (backend live since M3). Loki indexes `service_name` (plus its default OTLP index labels, including `service_instance_id` and `k8s_pod_name`); `trace_id`/`span_id` are structured metadata: `{service_name="orders"} \| trace_id="<id>"` |
| Alerts | kps rules (M2), Sloth rules (M6) | Alertmanager: `severity="page"` → `page@lab.local`, everything else → `ticket@lab.local`, `Watchdog` → `null`, via `mailpit.freightline:1025` | done (routing verified M2) |

## App contract (set only by the library chart)

| Variable | Value | Why |
|---|---|---|
| `POD_UID`, `POD_TEMPLATE_HASH` | downward API (`metadata.uid`, label `pod-template-hash`) | inputs for the next line; must come first in `env` |
| `OTEL_RESOURCE_ATTRIBUTES` | `service.namespace=freightline,deployment.environment.name=kind,service.version=<tag>,service.instance.id=$(POD_UID),freightline.pod_template_hash=$(POD_TEMPLATE_HASH)` | Prometheus `job` = `freightline/<service>`, `instance` = pod UID (M1); P03's canary split (M2) |
| `OTEL_SERVICE_NAME` | `orders` / `inventory` | |
| `OTEL_EXPORTER_OTLP_ENDPOINT`, `_PROTOCOL` | `http://otel-gateway.observability:4317`, `grpc` | ADR-P04-1: one destination, chosen by the platform |
| `OTEL_METRICS_EXEMPLAR_FILTER` | `trace_based` | exemplars only from sampled spans (M1) |
| `OTEL_PYTHON_FASTAPI_EXCLUDED_URLS` | `healthz,readyz` | probe exclusion for Python (Go filters in code) (M1) |
| `OTEL_SEMCONV_STABILITY_OPT_IN` | `http,database` | same stable metric names in both languages |
| `OTEL_TRACES_SAMPLER` / `_ARG` | `parentbased_traceidratio` / `1.0` | lab: keep everything |
| `OTEL_LOGS_EXPORTER` | `none` | logs via stdout and the node agent (ADR-P04-2) |

**Instrumentation hygiene (M1, measured with a debug Collector):** probes produce no spans and no histogram samples (0 spans in about 77 s idle across 3 pods); server spans are named by route (`POST /v1/orders`, `POST /v1/reservations`) with `http.route` on the duration histogram; inventory emits 3 spans per request (server, INSERT, UPDATE) and orders 6 (server, client, pool.acquire ×2, query, UPDATE); histogram buckets include 0.25 s.

## Self-monitoring (FR-8, M4)

`deploy/observability/pipeline-alerts.yaml` (PrometheusRule `telemetry-pipeline`, promtool-tested):

| Alert | Expression (Collector 0.161 names, no `_total`) | Severity |
|---|---|---|
| TelemetryExportFailing | `rate(otelcol_exporter_send_failed_{spans,metric_points,log_records}[5m]) > 0` for 10m, by exporter | ticket |
| TelemetryQueueFilling | `otelcol_exporter_queue_size / otelcol_exporter_queue_capacity > 0.8` for 10m (capacity 1000) | page |
| TelemetryRefused | `rate(otelcol_receiver_refused_{spans,metric_points,log_records}[5m]) > 0`, by receiver | ticket |
| OrdersMetricsAbsent | `absent_over_time(target_info{job="freightline/orders"}[10m])` (D-21: not the request histogram, which a fresh idle pod does not export) | page |

**Measured freshness (M4, n=3):** Loki 1.1 s; complete trace in Tempo 4.8–5.3 s (inventory's BatchSpanProcessor 5 s delay); newest metric sample 1.4–10.9 s old (15 s push interval).

## Dashboards (M5)

Generated by `deploy/observability/dashboards/generate.py` into `json/*.json` (review) and `*.yaml` (ConfigMaps labelled `grafana_dashboard: "1"`, loaded by kps's Grafana sidecar from any namespace).

| Dashboard | uid | Panels | Built on |
|---|---|---|---|
| Freightline / RED | `freightline-red` | rate, rate by route and status, error ratio (reads 0, not "No data"), p50/p99 with exemplars, requests within 250 ms, warn/error logs | `http_server_request_duration_seconds_*` (OTLP), Loki |
| Freightline / USE | `freightline-use` | per pod: CPU cores, CPU vs request*, CFS throttling (none: no CPU limits), working set, working set vs limit*, restarts*, OOMKilled*, OOM events; node: CPU, load per core, memory, major faults, network errors | cAdvisor, node-exporter, *kube-state-metrics (D-14) |
| Freightline / Flow | `freightline-flow` | order outcomes (LogQL on the JSON line), reservation results, precheck degraded, pool exhausted, p99 by span, Tempo service graph | Loki, OTLP metrics, Tempo span metrics and service graph |

All three carry **rollout annotations** derived from `target_info` (a new `freightline_pod_template_hash` per job). Click path verified in M5: RED p99 exemplar → Tempo trace → Loki lines by `trace_id` (`docs/evidence/p04/m5-*.png`).

## SLOs (M6)

`deploy/observability/slo/orders.yaml` (Sloth) → `slo/generated/orders.rules.yaml` (PrometheusRule `freightline-orders`, 34 rules, committed).

| SLO | Objective (30 d) | SLI | Page | Ticket |
|---|---|---|---|---|
| requests-availability | 99.9% | non-5xx / all orders requests | 14.4× over 1 h and 5 m, or 6× over 6 h and 30 m | 3× over 1 d and 2 h, or 1× over 3 d and 6 h |
| requests-latency | 99% | requests in `le="0.25"` / all | same factors | same factors |

Routing (M2): `severity=page` → `page@lab.local`, otherwise → `ticket@lab.local`. Measured (M6, live): 0.1% for 20 min → no page; 50% → page firing in 60 s, email in 90 s, resolved 30 m 23 s after the fix (the 6×/30 m pair); +300 ms on every request → page firing in 211 s, email in 236 s.
