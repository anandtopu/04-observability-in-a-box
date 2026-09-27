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
