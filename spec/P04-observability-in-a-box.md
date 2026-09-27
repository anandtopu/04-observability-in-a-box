## P04 — Observability-in-a-Box

| Field | Value |
|---|---|
| ID | P04 |
| Tier | **T2 Intermediate** |
| Time estimate | 25-35 hours |
| Industry framing | Beacon's standard observability pack, forced by Cobalt Bank (fictional; its SOC mandates Splunk and a proxy inspects all TLS) and Northstar Retail (fictional; a Datadog shop) |
| Required categories covered | Observability dashboards |
| Languages | YAML (Collector, Helm, Sloth), PromQL, LogQL; small Go, Python and TypeScript changes |
| Cloud(s) | None; kind. Export profiles reach Splunk or Datadog without a cloud account |
| Estimated cost / keeping it near $0 | $0. Adds about 5 GB of RAM to P02 (use P02's low-RAM profile on 16 GB); 72 h retention; the in-cluster `customer-sim` Collector stands in for Splunk. Revoke any Datadog trial key the same day |
| Prerequisites | [C12](../02-curriculum/C12-observability-and-monitoring.md) T2, [C09](../02-curriculum/C09-containers-and-kubernetes.md) T1, [C15](../02-curriculum/C15-production-readiness-and-incident-response.md) T2; P02 running on kind |

### 1. Problem statement

**Business context (composite scenario).** In a Beacon incident, Freightline orders sat in `PENDING` for 70 minutes. On-call had Prometheus graphs and `kubectl logs` but no traces; the cause, an exhausted Postgres pool in inventory, sat in one trace nobody could find. Cobalt Bank then wrote observability into its contract: its security operations center (SOC) wants every application log in Splunk within 60 s, its CAB approves configuration but not per-customer code, and all egress crosses a TLS-inspecting proxy. Northstar wants the same telemetry in Datadog.

**Constraints.** One image per service everywhere: the destination must be configuration. Ship-to addresses and consignee names never leave the cluster. Egress crosses a proxy with a corporate CA and later sites are air-gapped (P16), so the default mode needs no SaaS. Cobalt pays for Splunk ingest per GB.

**Stakeholders.** Beacon's SRE lead (owns on-call), Freightline service owners, Cobalt's SOC lead and CAB chair, Northstar's platform team, and Beacon's FDE (you).

**Measurable success criteria.**
1. Alert → failing trace → its logs in 3 clicks and under 2 minutes, timed in a game day.
2. RED panels for all four services and USE panels for every pod and node, from one template.
3. A 50% error burst on `orders` pages within 5 minutes; a steady 0.1% error rate (1x burn of a 99.9% SLO) never pages in 2 hours.
4. Export mode is a values change only: no pod or image changes in `freightline`, counts within 0.1% of the Loki path over 30 minutes of k6, and no log loss across a 10-minute sink outage.
5. Under 50,000 active series for the whole lab.

### 2. Requirements

**Functional requirements**
- **FR-1** Services send traces and metrics over OTLP only to `otel-gateway.observability:4317`; a node agent collects stdout JSON logs.
- **FR-2** Metrics reach Prometheus's OTLP receiver with promoted resource attributes, including `freightline_pod_template_hash` for P03.
- **FR-3** Traces reach Tempo (span metrics and exemplars included); logs reach Loki with `trace_id` and `span_id` as structured metadata.
- **FR-4** Grafana links exemplar → trace → logs and log line → trace.
- **FR-5** RED, USE and Freightline-flow dashboards are JSON in Git.
- **FR-6** SLO specs in Git generate multi-window, multi-burn-rate rules with separate `page` and `ticket` routes.
- **FR-7** An overlay adds Splunk HEC or Datadog exporters with PII removal, a persistent queue and proxy/CA support.
- **FR-8** The pipeline alerts on its own queue depth, send failures and refused data.

**Non-functional requirements**

| Attribute | Target |
|---|---|
| Overhead | SDK CPU overhead < 5% at 100 req/s; gateway `memory_limiter` at 80% of a 1 Gi limit |
| Freshness | Metrics < 30 s; Loki < 15 s; customer sink < 60 s |
| Durability | No log loss across a 10-minute sink outage; gateway ×2 with a PDB |
| Cardinality | < 50,000 active series; no order, customer or trace IDs as labels |
| Retention / cost | 72 h per signal; $0 in the lab; customer ingest volume signed off before go-live |

**Constraints.** No per-customer code; pinned charts and images; applications speak only OTLP.

**Out of scope.** Long-term metrics (Mimir, Thanos), tail sampling (an extension), audit logging for the customer's SIEM of record, and OpenTelemetry Profiles (public alpha as of September 2026).

### 3. Architecture

```text
 ZONE: workloads (ns freightline, PSA restricted)     ZONE: pipeline (ns observability)
 +---------------------------------------+   OTLP    +--------------------------------------------+
 | orders (Go), inventory (Py),          |   :4317   | otel-gateway (Collector contrib 0.161, x2) |
 | billing + notifications (TS):         |---------->| memory_limiter > k8s_attributes > resource |
 | SDK traces, metrics, exemplars;       |           | [attributes/pii in export mode]            |
 | stdout JSON logs (trace_id, span_id)  |           | exporters with sending_queue + batch       |
 +------------------+--------------------+           +------+-----------+-----------+--------+----+
                    | /var/log/pods                         |           |           |        |
 +------------------v--------------------+   OTLP    ^      |           |           |        |
 | otel-agent DaemonSet: file_log >      |-----------+      |           |           |        |
 | container > json_parser (trace, level)|                  |           |           |        |
 | alloy (optional): pyroscope.ebpf ---> Pyroscope :4040    |           |           |        |
 +---------------------------------------+                  v           v           v        |
 ZONE: backends (ns monitoring)                  Tempo :4317/:3200  Loki :3100  Prometheus   |
   Tempo metrics-generator --remote_write + exemplars--> Prometheus "kps" :9090 (OTLP recv)  |
   Grafana: exemplar > Tempo > Loki (trace_id); Loki derived field > Tempo                   |
   Alertmanager: page / ticket > Mailpit (lab) or the customer's incident tool               |
 ===== TRUST BOUNDARY: customer egress (proxy re-signs TLS; destination allow-list) ==========|
   export mode: splunk_hec/cobalt > Cobalt Splunk HEC :8088 | datadog/northstar > Datadog <--+
   lab stand-in: ns customer-sim (Collector with a splunk_hec receiver and a debug exporter)
```

| Component | Responsibility | Technology | Why | Alternative considered |
|---|---|---|---|---|
| `otel-gateway` | Receive, enrich, fan out | Collector contrib, Deployment ×2 | Vendor-neutral; all customer exporters in contrib | Vendor agent per customer |
| `otel-agent` | Tail pod logs, lift `trace_id` | Collector contrib DaemonSet | Same config and path as the gateway | Alloy (Loki-only output) |
| Prometheus + Alertmanager | Metrics, exemplars, rules, routing | kube-prometheus-stack | Built-in OTLP receiver; P03 depends on it | Mimir 3 (needs Kafka) |
| Tempo / Loki | Traces / logs | Monolithic modes | No Kafka; native OTLP | Jaeger v2 / OpenSearch |
| Grafana | Dashboards, cross-signal links | Bundled with the stack | One UI over every backend | Perses (pre-1.0) |
| Alloy + Pyroscope (optional) | eBPF CPU profiles | DaemonSet | No code change | Pyroscope SDK |

**Mini-ADRs**

| # | Decision | Options | Choice | Consequences |
|---|---|---|---|---|
| ADR-P04-1 | How telemetry leaves the app | SDK to each backend; vendor agent per customer; one OTLP gateway | OTLP to `otel-gateway` only | A customer backend is a values overlay; the gateway becomes tier 1 (replicas, PDB, `memory_limiter`, queue alerts) |
| ADR-P04-2 | Log collection | OTel logs SDK; node agent on stdout | Node agent parsing JSON | JS and Python OTel logs SDKs are still "Development", and `kubectl logs` keeps working. Cost: one parser per log format |
| ADR-P04-3 | Metrics transport | Scrape `/metrics`; OTLP push | OTLP push | One protocol, exportable as-is. No `up` metric (use `absent_over_time()`); pushers need an out-of-order window |
| ADR-P04-4 | SLO tooling | Hand-written rules; Pyrra; Sloth | Sloth in CI | No controller in customer clusters; the rule diff is change evidence. SLO views live in Grafana |

### 4. Tools & technologies

| Tool | Version / status (as of September 2026) | Notes |
|---|---|---|
| OpenTelemetry | CNCF Graduated 2026-05-11 | HTTP semconv stable; logs SDK maturity varies by language |
| Collector contrib / chart | 0.161.0 / `opentelemetry-collector` 0.173.1 | snake_case renames (`otlp_grpc`, `otlp_http`, `file_log`, `k8s_attributes`); old names are deprecated aliases. Exporter `sending_queue.batch` replaces the `batch` processor |
| Prometheus / kube-prometheus-stack | 3.14.0 / 91.5.1 | Exemplars still need `exemplar-storage`; native histograms stable since 3.8 |
| Grafana / Loki / Tempo | 13.2.2 / 3.7.8 / 3.0.3 | OSS charts are community-maintained at `grafana-community` (Loki's moved 2026-03-16): grafana 13.2.5, loki 18.13.5, tempo 3.0.0 |
| Alloy / Pyroscope | v1.19.2 / 2.3.1 | Grafana Agent EOL 2025-11-01; Alloy's `alloy otel` engine is experimental |
| Sloth / Pyrra | v0.16.0 / v0.10.2 | Multi-window, multi-burn-rate rule generators |
| Incident routing | Alertmanager → your incident tool | Opsgenie shuts down 2027-04-05 |

### 5. Step-by-step implementation plan

**M1 — Instrumentation hygiene (3 h).** *Identity:* the library chart appends `service.instance.id=$(POD_UID)` (downward API) to `OTEL_RESOURCE_ATTRIBUTES`, or two replicas push identical series. *Probes:* kubelet probes add about 0.6 req/s of free "good" traffic per pod, so exclude them (Python: `OTEL_PYTHON_FASTAPI_EXCLUDED_URLS=healthz,readyz`; Node: an `instrumentation.ts` that registers `@opentelemetry/instrumentation/hook.mjs` and sets `ignoreIncomingRequestHook`; Go below). *Exemplars:* set `OTEL_METRICS_EXEMPLAR_FILTER=trace_based` everywhere.

```go
// services/orders/cmd/orders/main.go: replaces otelhttp.NewHandler(mux, "orders") from P02 M2
notProbe := func(r *http.Request) bool { return r.URL.Path != "/healthz" && r.URL.Path != "/readyz" }
apiHandler := otelhttp.NewHandler(mux, "orders", otelhttp.WithFilter(notProbe))
```

*Done when* the rendered chart carries the instance ID for all four services (expected: `4`):

```bash
helm template freightline deploy/helm/freightline -f deploy/envs/kind/values.yaml | grep -c 'service.instance.id=$(POD_UID)'
```

**M2 — Prometheus with the OTLP receiver (4 h).** P03 installs Prometheus with this file; `fullnameOverride: kps` yields the `kps-prometheus` Service its AnalysisTemplate queries. OTLP metrics get `job` = `service.namespace/service.name` and `instance` = `service.instance.id`.

```yaml
# deploy/observability/kps-values.yaml
fullnameOverride: kps
prometheus:
  prometheusSpec:
    enableOTLPReceiver: true            # --web.enable-otlp-receiver
    enableRemoteWriteReceiver: true     # Tempo's metrics-generator writes here
    enableFeatures: [exemplar-storage]
    exemplars: { maxSize: 100000 }
    tsdb: { outOfOrderTimeWindow: 30m } # several gateway replicas push
    otlp:
      promoteResourceAttributes: [service.version, deployment.environment.name, k8s.namespace.name, k8s.pod.name, freightline.pod_template_hash]
    retention: 72h
    ruleSelectorNilUsesHelmValues: false
    serviceMonitorSelectorNilUsesHelmValues: false
prometheus-node-exporter:
  hostRootFsMount: { enabled: false }   # kind / Docker Desktop reject the shared root mount
alertmanager:
  config:                               # lists replace the chart defaults, so keep "null"
    route:
      receiver: ticket
      group_by: [alertname, service]
      routes:
        - { matchers: ['alertname="Watchdog"'], receiver: "null" }
        - { matchers: ['severity="page"'], receiver: page }
    receivers:
      - name: "null"
      - name: page
        email_configs: [{ to: page@lab.local, from: am@lab.local, smarthost: "mailpit.freightline:1025", require_tls: false }]
      - name: ticket
        email_configs: [{ to: ticket@lab.local, from: am@lab.local, smarthost: "mailpit.freightline:1025", require_tls: false }]
grafana:
  sidecar:
    datasources:
      exemplarTraceIdDestinations: { datasourceUid: tempo, traceIdLabelName: trace_id }
  additionalDataSources:
    - name: Tempo
      uid: tempo
      type: tempo
      url: http://tempo.monitoring:3200
      jsonData:
        serviceMap: { datasourceUid: prometheus }
        tracesToLogsV2:
          datasourceUid: loki
          filterByTraceID: true
          spanStartTimeShift: "-5m"
          spanEndTimeShift: "5m"
          tags: [{ key: service.name, value: service_name }]
    - name: Loki
      uid: loki
      type: loki
      url: http://loki.monitoring:3100
      jsonData:
        derivedFields:   # "$$" stops Grafana provisioning from expanding ${__value.raw}
          - { name: trace_id, matcherType: label, matcherRegex: trace_id, datasourceUid: tempo, url: "$${__value.raw}" }
```

*Done when* the container args include `--web.enable-otlp-receiver` and `--enable-feature=exemplar-storage`:

```bash
kubectl -n monitoring get pod prometheus-kps-prometheus-0 -o jsonpath='{.spec.containers[?(@.name=="prometheus")].args}'
```

**M3 — Tempo and Loki, monolithic (3 h).** Loki's OTLP endpoint stores `trace_id` and `span_id` as structured metadata and indexes `service.name` as `service_name`.

```yaml
# deploy/observability/tempo-values.yaml
tempo:
  reportingEnabled: false
  retention: 72h
  metricsGenerator:
    enabled: true
    storage:
      path: /var/tempo/generator
      remote_write: [{ url: "http://kps-prometheus.monitoring:9090/api/v1/write", send_exemplars: true }]
  overrides:
    defaults:
      metrics_generator: { processors: [service-graphs, span-metrics] }
```

```yaml
# deploy/observability/loki-values.yaml
deploymentMode: Monolithic
loki:
  auth_enabled: false
  commonConfig: { replication_factor: 1 }
  storage: { type: filesystem }
  useTestSchema: true          # lab only; production pins a real schemaConfig
  limits_config: { allow_structured_metadata: true }
singleBinary: { replicas: 1 }
gateway: { enabled: false }
chunksCache: { enabled: false }
resultsCache: { enabled: false }
lokiCanary: { enabled: false }
test: { enabled: false }
```

*Done when* `kubectl -n monitoring get pods` shows `tempo-0` and `loki-0` Ready.

**M4 — Gateway and agent Collectors (5 h).**

```yaml
# deploy/observability/otel-gateway-values.yaml
mode: deployment
replicaCount: 2
fullnameOverride: otel-gateway       # Service otel-gateway.observability, the P02 contract
image: { repository: otel/opentelemetry-collector-contrib, tag: "0.161.0" }
command: { name: otelcol-contrib }
resources: { limits: { memory: 1Gi } }
podDisruptionBudget: { enabled: true, minAvailable: 1 }
presets: { kubernetesAttributes: { enabled: true } }
ports: { metrics: { enabled: true } }
serviceMonitor: { enabled: true }
config:
  receivers: { jaeger: null, zipkin: null, prometheus: null }
  processors:
    batch: null                      # batching moves into each exporter's sending_queue
    k8s_attributes:
      pod_association:               # logs arrive from the agent: match on pod UID, not source IP
        - sources: [{ from: resource_attribute, name: k8s.pod.uid }]
        - sources: [{ from: connection }]
    resource:
      attributes: [{ key: k8s.cluster.name, value: freightline-kind, action: upsert }]
  exporters:
    otlp_grpc/tempo: { endpoint: "tempo.monitoring:4317", tls: { insecure: true }, sending_queue: { batch: {} } }
    otlp_http/prometheus: { endpoint: "http://kps-prometheus.monitoring:9090/api/v1/otlp", sending_queue: { batch: {} } }
    otlp_http/loki: { endpoint: "http://loki.monitoring:3100/otlp", sending_queue: { batch: {} } }
  service:
    pipelines:
      traces: { receivers: [otlp], processors: [memory_limiter, k8s_attributes, resource], exporters: [otlp_grpc/tempo] }
      metrics: { receivers: [otlp], processors: [memory_limiter, k8s_attributes, resource], exporters: [otlp_http/prometheus] }
      logs: { receivers: [otlp], processors: [memory_limiter, k8s_attributes, resource], exporters: [otlp_http/loki] }
```

The agent is the same chart as a DaemonSet (`otel-agent`, `presets.logsCollection.enabled: true`, other defaults set to `null`) with one pipeline: `file_log → memory_limiter → k8s_attributes → otlp_grpc` to the gateway. Its `k8s_attributes` maps the pod label `app.kubernetes.io/name` to `service.name`, which gives Loki its `service_name`. Parsing:

```yaml
# deploy/observability/otel-agent-values.yaml (receiver excerpt)
config:
  receivers:
    file_log:
      include: [/var/log/pods/freightline_*/app/*.log]
      operators:
        - { type: container, id: container-parser }
        - type: json_parser
          if: 'body matches "^\\{"'
          parse_from: body
          severity:
            parse_from: attributes.level
            mapping: { info: 30, warn: 40, error: 50, fatal: 60 }   # pino (Node) logs numeric levels
          trace:
            trace_id: { parse_from: attributes.trace_id }
            span_id: { parse_from: attributes.span_id }
```

*Done when* (with section 6's port-forwards running) idle traffic reads `0` for all four jobs, proving the probe filter:

```bash
curl -s localhost:9090/api/v1/query --data-urlencode 'query=sum by (job) (rate(http_server_request_duration_seconds_count{job=~"freightline/.*"}[5m]))'
```

and an `orders` log line carries a trace ID (one stream returned):

```bash
curl -s -G localhost:3100/loki/api/v1/query_range --data-urlencode 'query={service_name="orders"} | trace_id != ""' --data-urlencode 'limit=1'
```

**M5 — RED and USE dashboards as code (5 h).** Three JSON dashboards in `deploy/observability/dashboards/`, shipped as ConfigMaps labeled `grafana_dashboard: "1"`: *RED* (a `$service` variable over `job`), *USE* (pods and nodes) and *Flow* (P02's outbox backlog age, consumer lag and DLQ depth, plus Tempo's service graph), all with P03's deploy annotations.

| Panel | PromQL |
|---|---|
| Rate / errors | `sum by (job) (rate(http_server_request_duration_seconds_count{job=~"$service"}[$__rate_interval]))`; errors add `http_response_status_code=~"5.."` and divide |
| Duration p99, exemplars on | `histogram_quantile(0.99, sum by (job, le) (rate(http_server_request_duration_seconds_bucket{job=~"$service"}[$__rate_interval])))` |
| USE | `container_cpu_usage_seconds_total` ÷ CPU request; throttled ÷ total CFS periods; working-set memory ÷ limit; restarts and `OOMKilled` from kube-state-metrics |

*Done when* the three dashboards are loaded (expected: `3`):

```bash
kubectl -n monitoring get configmap -l grafana_dashboard=1 --no-headers | grep -c freightline
```

**M6 — SLOs and burn-rate alerts (4 h).** Two 30-day SLOs for `orders`: availability 99.9% and latency 99% within 250 ms. 250 ms, not the 300 ms NFR, because 0.25 is a default HTTP histogram bucket boundary and 0.3 would be interpolated. Helm never renders this file, because `{{.window}}` is Sloth's placeholder:

```yaml
# deploy/observability/slo/orders.yaml
apiVersion: sloth.slok.dev/v1
kind: PrometheusServiceLevel
metadata: { name: freightline-orders, namespace: monitoring }
spec:
  service: orders
  slos:
    - name: requests-availability
      objective: 99.9
      sli:
        events:
          errorQuery: sum(rate(http_server_request_duration_seconds_count{job="freightline/orders",http_response_status_code=~"5.."}[{{.window}}]))
          totalQuery: sum(rate(http_server_request_duration_seconds_count{job="freightline/orders"}[{{.window}}]))
      alerting:
        name: OrdersAvailabilityBurn
        annotations: { runbook_url: "docs/runbooks/slo-burn.md" }
        pageAlert: { labels: { severity: page } }
        ticketAlert: { labels: { severity: ticket } }
```

The latency SLO's `errorQuery` is total requests minus the `le="0.25"` bucket. Sloth emits the SRE-workbook pairs: page on 14.4x burn over 1 h and 5 m or 6x over 6 h and 30 m; ticket on 3x over 1 d and 2 h or 1x over 3 d and 6 h. From a clean hour, burn rate *B* trips the 1 h window after about 60 × 14.4 / *B* minutes: under 2 minutes for a 50% error burst (*B* = 500), about 43 for 2% errors (*B* = 20). Alertmanager (M2 file) routes `page` and `ticket` to different Mailpit addresses and `Watchdog` to `null`.

*Done when* the rule exists and section 7's burn tests pass:

```bash
kubectl -n monitoring get prometheusrule freightline-orders
```

**M7 — Customer export mode (5 h).** The Cobalt profile overlays the gateway release; Helm merges maps and replaces lists, so it names only what changes:

```yaml
# deploy/observability/export-splunk-values.yaml (Cobalt profile)
extraEnvs:
  - name: SPLUNK_HEC_TOKEN
    valueFrom: { secretKeyRef: { name: customer-splunk-hec, key: token } }
  # At Cobalt also: HTTPS_PROXY=http://<proxy>:8080 and NO_PROXY=.svc,.cluster.local
extraVolumes: [{ name: queue, emptyDir: {} }]            # production: statefulset mode + PVC
extraVolumeMounts: [{ name: queue, mountPath: /var/lib/otelcol/queue }]
config:
  extensions:
    file_storage/queue: { directory: /var/lib/otelcol/queue }
  processors:
    attributes/pii:
      actions: [{ key: ship_to, action: delete }, { key: consignee_name, action: delete }]
  exporters:
    splunk_hec/cobalt:
      endpoint: http://customer-sim.customer-sim:8088/services/collector   # Cobalt: https://<hec-host>:8088/...
      token: ${env:SPLUNK_HEC_TOKEN}
      index: freightline
      sourcetype: freightline:otel
      # tls: { ca_file: /etc/cobalt-ca/ca.crt }   # the proxy re-signs TLS with Cobalt's CA
      sending_queue: { storage: file_storage/queue, batch: {} }
      retry_on_failure: { max_elapsed_time: 0s }  # retry until the persistent queue fills
  service:
    extensions: [health_check, file_storage/queue]
    pipelines:
      logs:
        processors: [memory_limiter, k8s_attributes, resource, attributes/pii]
        exporters: [otlp_http/loki, splunk_hec/cobalt]
```

The Northstar profile adds a `datadog/connector` (it computes APM stats; the exporter no longer does by default) and a `datadog/northstar` exporter (`api: { site: datadoghq.com, key: ${env:DD_API_KEY} }`); the connector exports from the traces pipeline and receives into the metrics pipeline. An OTLP-native backend needs only an `otlp_http/customer` exporter with endpoint and auth header; Cobalt's Splunk takes HEC, hence `splunk_hec`. `customer-sim` is a third release of the chart with only a `splunk_hec` receiver on 8088 and a `debug` exporter.

*Done when* section 6's `diff` is empty and both log exporters report the same count:

```bash
curl -s localhost:9090/api/v1/query --data-urlencode 'query=sum by (exporter) (increase(otelcol_exporter_sent_log_records_total[30m]))'
```

**M8 — Profiles (optional) and the game day (3 h).** Run Alloy's `pyroscope.ebpf` as a DaemonSet writing to `http://pyroscope.monitoring:4040`; it needs root in the host PID namespace, so lab only unless a customer approves in writing. Then shrink inventory's pool to 2, drive 100 req/s and time alert → exemplar → trace → logs.

*Done when* two people who did not build the stack each reach the failing span's logs in under 2 minutes, with timings in `docs/evidence/p04/`.

### 6. Deployment instructions

Order: Prometheus and Grafana, Tempo and Loki, gateway, agent, SLOs and dashboards, then the Freightline upgrade (M1). Secrets such as `SPLUNK_HEC_TOKEN` never go into values files.

```bash
helm install kps prometheus-community/kube-prometheus-stack --version 91.5.1 -n monitoring --create-namespace -f deploy/observability/kps-values.yaml
```

```bash
helm install tempo oci://ghcr.io/grafana-community/helm-charts/tempo --version 3.0.0 -n monitoring -f deploy/observability/tempo-values.yaml
```

```bash
helm install loki oci://ghcr.io/grafana-community/helm-charts/loki --version 18.13.5 -n monitoring -f deploy/observability/loki-values.yaml
```

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
```

```bash
helm install otel-gateway open-telemetry/opentelemetry-collector --version 0.173.1 -n observability --create-namespace -f deploy/observability/otel-gateway-values.yaml
```

```bash
helm install otel-agent open-telemetry/opentelemetry-collector --version 0.173.1 -n observability -f deploy/observability/otel-agent-values.yaml
```

Generate the SLO rules (`go install github.com/slok/sloth/cmd/sloth@v0.16.0`), apply them with the dashboards, and upgrade Freightline:

```bash
sloth generate -i deploy/observability/slo/orders.yaml -o deploy/observability/slo/generated/orders.rules.yaml
```

```bash
kubectl apply -f deploy/observability/slo/generated/ -f deploy/observability/dashboards/
```

```bash
helm upgrade freightline deploy/helm/freightline -n freightline -f deploy/envs/kind/values.yaml --wait
```

Verify through port-forwards (one terminal each); Grafana is at `localhost:3000`, user `admin`, password from the last command:

```bash
kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090
```

```bash
kubectl -n monitoring port-forward svc/loki 3100:3100
```

```bash
kubectl -n monitoring port-forward svc/kps-grafana 3000:80
```

```bash
kubectl -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

**Customer export mode.** Snapshot the workloads, create the token and the stand-in sink, apply the overlay, and compare (expected: no output):

```bash
kubectl -n freightline get pods -o custom-columns=POD:.metadata.name,STARTED:.status.startTime,IMAGE:.spec.containers[0].image > before.txt
```

```bash
kubectl -n observability create secret generic customer-splunk-hec --from-literal=token=lab-only-token
```

```bash
helm install customer-sim open-telemetry/opentelemetry-collector --version 0.173.1 -n customer-sim --create-namespace -f deploy/observability/customer-sim-values.yaml
```

```bash
helm upgrade otel-gateway open-telemetry/opentelemetry-collector --version 0.173.1 -n observability -f deploy/observability/otel-gateway-values.yaml -f deploy/observability/export-splunk-values.yaml
```

```bash
kubectl -n freightline get pods -o custom-columns=POD:.metadata.name,STARTED:.status.startTime,IMAGE:.spec.containers[0].image | diff before.txt -
```

**Rollback** to Beacon-only mode; applications are untouched either way:

```bash
helm rollback otel-gateway -n observability
```

**Teardown.** Everything lives in P02's cluster:

```bash
kind delete cluster --name freightline
```

### 7. Testing & validation

| Test | How | Pass threshold |
|---|---|---|
| Config | `otelcol-contrib validate` on rendered configs in CI; `promtool check rules` on Sloth output | Zero errors; no deprecated component names |
| Correlation | Script: exemplar → Tempo trace → Loki by `trace_id` | 20/20 resolve to a trace with ≥ 1 log line |
| Fast / slow burn | `FAULT_5XX_RATE=0.5` (P03's fault hook), then `0.001` for 2 h | Page in < 5 min; no page on the slow burn |
| Export parity and outage | 30-min k6 run; `customer-sim` scaled to 0 for 10 min | Counts within 0.1%; queue drains in < 5 min |
| Gateway chaos | Delete a gateway pod every 2 min for 20 min | k6 `http_req_failed` unchanged; trace gaps < 1% |
| Cardinality and PII | Active series at 100 req/s; search Loki and the sink for a seeded consignee name | < 50,000 series; zero hits |

### 8. Observability & operations

Monitor the monitor via the gateway's ServiceMonitor:

| Alert | Expression (sketch) | Severity |
|---|---|---|
| TelemetryExportFailing | `rate(otelcol_exporter_send_failed_log_records_total[5m]) > 0` for 10 min, plus span and metric-point variants | Ticket; page for a contractual customer sink |
| TelemetryQueueFilling | `otelcol_exporter_queue_size / otelcol_exporter_queue_capacity > 0.8` for 10 min | Page: data loss is minutes away |
| TelemetryRefused | `rate(otelcol_receiver_refused_spans_total[5m]) > 0` | Ticket: usually `memory_limiter` pushback |
| OrdersMetricsAbsent | `absent_over_time(http_server_request_duration_seconds_count{job="freightline/orders"}[10m])` | Page: OTLP push has no `up` |

Runbook entries (`docs/runbooks/`):
1. **Queue filling.** TLS or connection errors to the customer sink mean proxy or CA: test from the gateway's network with the customer's network team, and never set `insecure_skip_verify`. A full queue rejects new data (`block_on_overflow` defaults to false), so tell the customer's SOC the affected window first.
2. **SLO page.** Follow an exemplar from the p99 panel, look for a deploy annotation, and switch to P03's abort runbook if a canary is live. If the trace-to-logs link is empty, check `trace_id` parsing and `service_name` extraction in the agent.

### 9. Security & compliance

| Threat | Scenario | Control implemented |
|---|---|---|
| Information disclosure | Consignee names reach a third-party backend | `attributes/pii`, log-field allow-lists, a signed-off payload sample |
| Spoofing | Any pod pushes fake telemetry | NetworkPolicy admits only `freightline` and `observability` on 4317; receiver TLS at customer sites |
| Credential exposure | HEC token or Datadog key in Git | Secret referenced as `${env:...}`; External Secrets in P05 |
| Denial of service | A telemetry storm exhausts the gateway | `memory_limiter`, bounded queues, promote only named attributes |
| Repudiation | Dropped logs treated as evidence | Persistent queue and delivery metrics; security audit logs stay on the customer's SIEM forwarder of record, because this pipeline is not tamper-evident |

**Compliance mapping (Cobalt).** PCI DSS v4.0.1 Requirement 10 (12 months' log retention, 3 immediately available) binds in-scope systems; Freightline is outside the cardholder data environment (see P25). The SIEM feed supports NYDFS Part 500 audit trails and DORA ICT-incident classification (applicable since 2025-01-17); the overlay goes through the CAB as configuration.

### 10. Extensions for advanced learners

1. **T3 — Tail sampling:** a `load_balancing` exporter tier routing by trace ID to a `tail_sampling` tier. *Hard because* it needs two tiers, memory sized for decision windows, and span metrics computed before sampling or every rate lies.
2. **T3 — Native histograms end to end** with Pyrra v0.10 SLOs. *Hard because* P03's `_bucket` queries and every dashboard change, and both series types coexist during migration.
3. **T4 — Air-gapped telemetry (P16)** on Mimir 3 and Tempo 3 in Kafka-backed RF1 modes. *Hard because* Kafka becomes a telemetry dependency you run without vendor support.
4. **T4 — Multi-tenant telemetry for P27.** *Hard because* cardinality must be capped per tenant and tenant A must provably never see tenant B's traces.
5. **T4 — Zero-code instrumentation with OBI v0.13 (pre-1.0)** for P01's SOAP façade. *Hard because* it needs kernel 5.8+ with BTF and privileges PSA `restricted` forbids.

### 11. How to demonstrate it in interviews

**2-minute pitch.** "Every customer mandates a different backend, so I made the destination configuration. Four services in three languages send only OTLP to a Collector gateway, and a node agent lifts trace IDs out of stdout JSON. By default everything lands in-cluster, in Prometheus with exemplars, Tempo and Loki, so one click goes from a latency spike to the trace to its logs. SLOs are Sloth specs generating multi-window burn-rate alerts. For a composite bank whose SOC mandated Splunk, export mode was a Helm overlay: a HEC exporter behind a persistent queue, PII stripped. No application pod restarted, counts matched within 0.1%, and a 10-minute sink outage lost nothing."

**10-minute demo flow.**
1. Diagram and ADR-P04-1 (1 min).
2. Latency panel → exemplar → trace → logs, live (2 min).
3. `kps-values.yaml` and why P03 depends on it (1 min).
4. Sloth spec, generated rules, detection maths (1.5 min).
5. Fast-burn injection; the page lands in Mailpit (1.5 min).
6. Export overlay: the empty `diff`, the parity query (2 min).
7. Sink outage and queue drain; trade-offs (1 min).

**Likely questions and strong-answer outlines.**
1. *"Why a gateway, not the vendor's agent?"* One build, one place for PII rules, queues and cardinality; concede the tier-1 component you now operate.
2. *"How do you stop cardinality blow-ups?"* Named promoted attributes only, no IDs as labels, series counted in CI load tests.
3. *"Why 250 ms when the requirement said 300?"* Bucket boundaries and interpolation error; native histograms fix it.
4. *"The customer's proxy breaks TLS?"* Mount their CA, set `NO_PROXY`, never skip verification; the queue buys time.
5. *"Splunk for traces too?"* Whoever operates it decides; the gateway keeps the choice reversible.

**Artifacts to bring:** diagram, ADRs, Sloth spec and rules, an exemplar-to-logs screenshot, the parity result with the empty `diff`, the game-day timings.

**Metrics to quote:** alert-to-logs time, active series at 100 req/s, export parity, queue drain time, SDK CPU overhead.

**What you would do differently:** fix probe filtering and instance IDs before the first dashboard (every early SLO number was wrong); book the customer's network team early: proxy and CA work is the long pole.

### 12. Common failure points while building

| Failure | Symptom | Fix |
|---|---|---|
| No `service.instance.id` | Counters "reset", `rate()` spikes, out-of-order sample errors | Pod UID in `OTEL_RESOURCE_ATTRIBUTES` (M1) |
| Trace-to-logs empty | "Logs for this span" returns nothing | Missing `service_name` (agent label extraction) or `trace_id` (JSON not parsed) |
| Old component names | Deprecation warnings; `dynamic_sampling` fails (renamed `adaptive_tail_sampling`, no alias) | `otlp_grpc`, `otlp_http`, `file_log`, `k8s_attributes`; exporter batching instead of `batch` |
| Wrong chart source | Stale Loki chart, no `Monolithic` mode | OSS Loki, Tempo and Grafana charts come from `grafana-community`; the in-repo Loki chart now targets GEL |
| Customer proxy | `x509: certificate signed by unknown authority`, or in-cluster calls sent to the proxy | CA as `tls.ca_file`; `NO_PROXY=.svc,.cluster.local` |
| NetworkPolicy | Alert emails never arrive | Freightline's default-deny blocks Alertmanager → Mailpit: allow ingress from `monitoring` on 1025 |

**See also:** [M09 Observability and production debugging](../../01-curriculum/M09-observability-and-production-debugging.md); [P4 Cloud deployment and monitoring](../../03-projects/P4-cloud-deployment-and-monitoring.md) (managed-cloud version).

---

