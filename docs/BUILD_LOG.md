# P04 Observability-in-a-Box: build log

One section per milestone, in the template from `docs/CLOUD_BUILD_PROMPT.md`. Numbers are measured in the cloud VM unless marked as a spec target.

## M0 — Environment, tier decision, app import, base platform   (2026-09-27, session 1, tier A)

**Goal / requirement served:** the platform every later gate runs on. FR-1's OTLP contract (the app side), P02's lifecycle rules (probes, preStop, PSA `restricted`), and the base for ADR-P04-1 (applications never name a backend).

**Tier decision: A (kind, 1 node).** Measured: 4 CPUs, 15 GB RAM (15 available), 30 GB disk, Docker 29.3.1 on **cgroup v1**. RAM is well above the ~8 GB needed for Tier B, and kind boots once two VM-specific patches are applied (DEVIATIONS D-03, D-04). Retention drops from 72 h to 12 h starting in M2 (D-02).

**App decision: P04-lite** (DEVIATIONS D-01). P02 is still a starter commit.

**What we built:**
- `deploy/kind/cluster.yaml`: one node on `kindest/node:v1.36.4`, plus the `failCgroupV1: false` and `restrict_oom_score_adj` patches this VM needs.
- `app/services/orders/`: Go. `POST /v1/orders` (requires `Idempotency-Key`, returns 202 + `Location`), `GET /v1/orders/{id}`, `/healthz` and `/readyz`. OTel SDK over OTLP/gRPC, `otelhttp` without a probe filter yet (M1 adds it), `otelpgx` SQL spans, slog JSON with `trace_id`/`span_id`, and P03's `FAULT_5XX_RATE` hook.
- `app/services/inventory/`: Python / FastAPI under `opentelemetry-instrument`. `POST /v1/reservations` is idempotent on `order_id` and returns 409 when stock is short, 503 + `Retry-After` when the pool is exhausted. `DB_POOL_MAX` is M8's game-day knob. JSON logs with `trace_id`/`span_id`.
- `app/deploy/helm/freightline-service/`: library chart with P02's pod spec (probes, native `preStop` sleep, non-root, read-only root, no SA token), Service, PDB, and **the OTel env contract in one place** (`freightline-service.otelEnv`).
- `app/deploy/helm/freightline/`: umbrella chart. Services come from the library; Postgres (CNPG operand image, `initdb` bootstrap, one DB and role per service, fast-stop `preStop`), Mailpit, generated DB credentials (kept stable across upgrades with `lookup`), default-deny ingress NetworkPolicy.
- `app/deploy/envs/kind/values.yaml`: the low-RAM kind profile. `app/deploy/namespaces.yaml`: `freightline` with PSA `restricted` (enforce and warn).
- `app/build-images.sh` and `scripts/kind-load-images.sh`: build and side-load images (the node cannot pull through the session proxy).
- `load/steady.js`: k6 constant-arrival-rate driver with synthetic PII (M7 seeds a known consignee name).
- `tests/m0-smoke.sh`: the M0 gate, re-runnable in every session.
- `scripts/cloud-setup.sh`: now starts dockerd and prints Docker Hub's remaining quota (D-09).

**How the data flows (today, before any backend exists):**
- k6 or curl → `orders` `POST /v1/orders`. `otelhttp` starts a server span and records `http.server.request.duration` (a histogram in seconds, the stable semconv name).
- `orders` inserts a PENDING row. `otelpgx` adds a client span per SQL statement, and the pgx pool is the parent context.
- `orders` → `inventory` over HTTP. `otelhttp.NewTransport` injects `traceparent`, so inventory's FastAPI server span joins **the same trace**.
- `inventory` reserves stock in one transaction (psycopg spans) and logs `stock reserved` with the same `trace_id`.
- `orders` sets CONFIRMED or REJECTED and logs `order accepted` with `trace_id`, `span_id`, and (deliberately) `ship_to`/`consignee_name`, synthetic PII that M7 must strip on export.
- Both SDKs push OTLP to `otel-gateway.observability:4317`, which **does not exist yet**. The exporters log `name resolver error: produced zero addresses` and drop the data: telemetry failures never fail requests.
- Logs go to stdout only (`OTEL_LOGS_EXPORTER=none`, ADR-P04-2). The node agent will collect them in M4.

**Commands run, in order:**

| Command | What it does | Key output |
|---|---|---|
| `bash scripts/cloud-setup.sh` | Installs tools, reports resources and registry reachability | 4 CPU / 15 GB / 30 GB; all 6 registry probes OK |
| `docker pull …` (real pulls) | Tests image-layer CDNs, which `/v2/` probes cannot see | First run: Docker Hub layers 403 from `production.cloudfront.docker.com` and `*.r2.cloudflarestorage.com` (user allowlisted both); later 429 from the shared anonymous quota; `gcr.io` Forbidden |
| `kind create cluster --config deploy/kind/cluster.yaml` | Creates the node | Attempts 1–2 failed (see below). Attempt 3: **up in 12 s**, node Ready on v1.36.4, containerd 2.3.4 |
| `go mod tidy && go build` | Resolves and builds orders | Go 1.24.7; OTel pinned to v1.41.0 (D-06); 19 MB static binary, 6.9 MB image |
| `bash app/build-images.sh 0.1.3` | Builds both images and side-loads them | `loaded freightline/orders:0.1.3`, `loaded freightline/inventory:0.1.3` (CPython 3.14.2) |
| `bash scripts/kind-load-images.sh m0` | Side-loads Postgres and Mailpit | `OK` × 2 |
| `helm lint` + `helm template … \| kubectl apply --dry-run=server -f -` | Validates against the real API server and PSA | 15 objects `created (server dry run)`, no PSA warnings |
| `helm install freightline … --wait` | Deploys | `Install complete` in **15 s**; now at revision 4 after the fixes below |
| `bash tests/m0-smoke.sh` | The M0 gate | **13 passed, 0 failed** |
| `k6 run -e RATE=20 -e DURATION=30s load/steady.js` | Driver smoke test | 601 requests at **20.0 req/s**, 0.00% failed, p99 **29.4 ms**; Postgres has 596 CONFIRMED + 7 REJECTED (601 from k6 + 2 from the gate) |

**Verification:** the Done-when gate says the app answers `POST /v1/orders` and `/readyz` is green on every service. `bash tests/m0-smoke.sh` with port-forwards to orders, inventory and mailpit gives **13/13 PASS**. It covers readiness of all four workloads, 202 + `Location`, CONFIRMED, idempotent replay, GET, 400 without a key, REJECTED for `SKU-000`, and one `trace_id` in both services' logs. Evidence: `docs/evidence/p04/m0-gate.txt`, `m0-cluster.txt`, `m0-k6-smoke.txt`.

**What broke and how we fixed it:**
1. *Docker Hub layers 403.* Hypothesis: the CDN host is not allowlisted. Evidence: proxy status `connect_rejected` for `production.cloudfront.docker.com` and `docker-images-prod…r2.cloudflarestorage.com`. Fix: the user added both hosts. The VM restarted and dockerd did not come back, so I started it (PID 507) and taught `cloud-setup.sh` to do the same.
2. *Docker Hub 429.* Evidence: `ratelimit-remaining: 0;w=3600` for source IP `160.79.106.129`, a quota shared with other sessions. Fix: base images from ghcr.io, and orders from `scratch` (D-05).
3. *kind: control plane never came up.* The kubelet ran (so the cgroup v1 patch worked), but every sandbox failed: `runc … failed to update /proc/self/oom_score_adj: Permission denied`. Hypothesis: a missing capability. Test: `CapBnd = 000001fffeffffff` has bit 24 (CAP_SYS_RESOURCE) cleared, and even host root cannot write -500. Root cause: the VM sandbox. Fix: containerd `restrict_oom_score_adj = true` (D-04). The debugging node, kept with `--retain`, was then deleted and recreated.
4. *Go toolchain download 403* (`storage.googleapis.com`). Fix: pin OTel Go versions that support Go 1.24 (D-06).
5. *`docker build` for inventory: `invalid peer certificate: UnknownIssuer`.* The session proxy inspects TLS. Fix: pass its CA as a BuildKit secret, never a layer (D-08).
6. *kind node cannot pull* (`proxyconnect tcp: dial tcp 127.0.0.1:…: connection refused`): the host's loopback proxy address was copied into the node. *`kind load docker-image` → `content digest not found`*: multi-platform index. Fix: single-platform `docker save` + `kind load image-archive` (D-05).
7. *orders restarted twice on first install.* It exited when its one-shot migration hit `connection refused` while Postgres ran `initdb`; inventory's pool retried and survived. Fix, round 1: retry. The reproduction (delete postgres-0 and orders together) then showed two deeper issues:
   - Postgres took **30 s** to stop. SIGTERM is a *smart* shutdown that waits for pooled clients forever, and meanwhile rejects new connections (`57P03`). Fix: `preStop: pg_ctl stop -m fast`. Postgres now stops in **1 s**.
   - orders' first connect attempt **hung ~2 minutes** (kernel SYN timeout, no endpoints behind the Service), and inventory's `pool.open(wait=True)` failed startup after 30 s. Fix in both services: the HTTP server starts first, the migration retries in the background with a **3 s per-attempt deadline**, and `/readyz` stays 503 until the schema exists.
   - Result: the same cold-start test gives **0 restarts**, and both services report `database ready` within about 1 s of Postgres returning.
8. *Open item: pod deletion takes 30 s.* The 10 s preStop is expected. The other 20 s is the OTel SDK trying to flush to the absent gateway until its shutdown deadline. **Re-measure in M4**, when the gateway exists. Telemetry should never hold shutdown hostage, so we may also give the flush its own short budget.

**Lab vs customer environment:** at Cobalt, images come from the customer's registry mirror (the same side-load problem, solved by their Harbor/Artifactory), their TLS-inspecting proxy needs its CA at build time (the D-08 mechanism) and at run time (M7), and nodes run cgroup v2, so D-03/D-04 disappear. Northstar is the same, minus the TLS inspection.

**Check yourself:**
1. Why does orders keep `/healthz` green while the database is down, but fail `/readyz`?
2. Why did Postgres take 30 s to stop, and what does `pg_ctl stop -m fast` change?
3. The OTel exporters cannot reach any gateway today. Why is that not an application failure, and what does it cost at shutdown?

<details><summary>answers</summary>

1. Liveness answers "is the process healthy?"; readiness answers "should this pod get traffic?" If liveness checked the DB, a Postgres blip would restart every pod at once, turning a dependency outage into a fleet-wide restart storm and wiping in-memory state. Readiness instead takes the pod out of the Service endpoints until the DB is back.
2. Kubernetes sends SIGTERM, which Postgres treats as a *smart* shutdown: refuse new sessions and wait for existing ones to end. Connection pools never end their sessions, so Postgres waited the whole 30 s grace period and was SIGKILLed, rejecting new connections the whole time. `-m fast` rolls back open transactions, disconnects clients and checkpoints, so the pod stops in about 1 s and clients reconnect to the new pod.
3. The SDK exports asynchronously on a background batcher and drops data after retries, so request handling never waits on telemetry. The cost shows at shutdown: the final flush waits up to its deadline (20 s here) for a gateway that doesn't exist. That's why the gateway becomes tier 1 in M4 (replicas, PDB), and why the flush deadline must fit inside `terminationGracePeriodSeconds`.
</details>

## M1 — Instrumentation hygiene   (2026-09-27, session 1, tier A)

**Goal / requirement served:** spec §5 M1, and the first row of §12 (no `service.instance.id` → counters "reset", `rate()` spikes). It prepares FR-2 (`freightline.pod_template_hash` for P03), FR-4 (exemplars) and M6's SLO arithmetic (no free probe traffic, a 0.25 s bucket).

**What we built:**
- `app/deploy/helm/freightline-service/templates/_helpers.tpl`: `POD_UID` and `POD_TEMPLATE_HASH` from the downward API, **declared first** because Kubernetes expands `$(VAR)` only from earlier entries. `OTEL_RESOURCE_ATTRIBUTES` gains `service.instance.id=$(POD_UID),freightline.pod_template_hash=$(POD_TEMPLATE_HASH)`. Also `OTEL_METRICS_EXEMPLAR_FILTER=trace_based` and `OTEL_PYTHON_FASTAPI_EXCLUDED_URLS=healthz,readyz`.
- `app/services/orders/cmd/orders/main.go`: `otelhttp.WithFilter(notProbe)` (the spec's snippet), `WithSpanNameFormatter` returning `r.Pattern`, and a `routeLabel` middleware that adds `http.route` to the span and the duration histogram.
- `app/services/inventory/src/inventory/main.py`: `suppress_instrumentation()` around the readiness query, and `FastAPIInstrumentor.instrument_app(app, exclude_spans=["receive","send"])`. `Dockerfile`: `OTEL_PYTHON_DISABLED_INSTRUMENTATIONS=fastapi`, so FastAPI isn't instrumented twice.
- `app/deploy/helm/freightline/`: `services` is now a map keyed by name (DEVIATIONS D-11). Images are `0.2.3`.
- `tests/fixtures/otel-debug-gateway.yaml` (temporary; deleted after use) and `tests/m1-debug-analyse.py`: the runtime check. `load/k6-job.yaml`: in-cluster k6, so traffic goes through the Service to every replica.
- `scripts/kind-load-images.sh`: M1 list (`otel/opentelemetry-collector-contrib:0.161.0`, `grafana/k6:2.3.0`).

**How the data flows (what changed on the way through):**
- The kubelet starts a pod and writes its UID and `pod-template-hash` label into env vars. The SDK reads `OTEL_RESOURCE_ATTRIBUTES` once at start-up, so **every span and metric point from that pod carries its own `service.instance.id`**. In M2 Prometheus turns it into the `instance` label, so two replicas become two series instead of one flip-flopping series.
- A kubelet probe hits `/readyz`. In Go, `otelhttp`'s filter returns false, so there's no span and no histogram sample. In Python the URL is excluded by env, and the DB query inside the handler runs under `suppress_instrumentation()`, so no psycopg span either.
- A real `POST /v1/orders` starts a server span. After ServeMux routes it, otelhttp renames the span from `r.Pattern` (`POST /v1/orders`), and `routeLabel` adds `http.route=/v1/orders` to the histogram labels.
- The request's duration lands in a bucket (the boundaries include **0.25 s**, which M6 needs), and since the span is sampled, the bucket keeps an **exemplar** with that span's trace and span IDs. In M5, that's the click from a latency spike to its trace.
- orders calls inventory with `traceparent`, so both services' spans share one trace ID, and inventory emits 3 spans per request instead of 6.

**Commands run, in order:**

| Command | What it does | Key output |
|---|---|---|
| `helm template freightline deploy/helm/freightline -f deploy/envs/kind/values.yaml \| grep -c 'service.instance.id=$(POD_UID)'` (from `app/`) | The spec's gate | **`2`** (P04-lite; the spec expects 4 for full Freightline) |
| `helm upgrade … --wait` | Rolls out the new env and images | Revisions 5–12 (see "What broke") |
| `kubectl apply -f tests/fixtures/otel-debug-gateway.yaml` | A Collector at the contract address that prints everything | 0.161.0 starts with no deprecation warnings |
| `kubectl apply -f load/k6-job.yaml` | 10 req/s × 60 s through the Service, orders × 2 | 601 requests, 0.00% failed, p99 **15.4 ms** (final run) |
| `python3 tests/m1-debug-analyse.py --since …` | Reads the Collector's logs from the node and checks every property | See Verification |
| `kubectl delete -f tests/fixtures/otel-debug-gateway.yaml` | Removes the fixture so M4's Helm release starts clean | deleted |
| `bash tests/m0-smoke.sh` | M0 regression | 13 passed, 0 failed |

**Verification:**
- *Spec gate (render):* `2`. Evidence: `docs/evidence/p04/m1-gate.txt`.
- *Runtime check (an addition, labelled as such):* `docs/evidence/p04/m1-runtime.txt`, orders × 2 plus inventory, final images.
  - 3 distinct `service.instance.id`s, each **equal to its pod UID**; `freightline.pod_template_hash` equals the ReplicaSet hash.
  - Under load: **601 traces for 601 requests, 601/601 containing spans from both services**; **0 probe spans**.
  - Idle on final images: **0 spans in about 77 s** with probes running on all 3 pods.
  - Exemplars on `http.server.request.duration`: 10 (orders) and 7 (inventory) in one export window. `http.route` values: `/v1/orders`, `/v1/reservations`.
  - Bucket boundaries: 0.005 … **0.25** … 10 s.

**What broke and how we fixed it:**
1. *Probe exclusion looked done but wasn't.* In a 75 s idle window: 40 spans, 0 of them HTTP. Grouping by scope showed 39 `SELECT` spans from psycopg: inventory's `/readyz` runs `SELECT 1`, and with the HTTP span excluded, each query became its own root span. The spec's gate (and M4's idle-rate gate) can't see this, because it doesn't affect the HTTP histogram. Fix: `suppress_instrumentation()`. Result: 0 spans idle.
2. *"0 spans under load"* contradicted 601 requests and the trace IDs in the exemplars. Hypothesis: data lost somewhere between the SDK and the log. Evidence: the Collector's log started at 18:26, after the load; `detailed` output crossed the kubelet's **10 MiB rotation** and `kubectl logs` shows only the current file. The rotated file held 36 trace batches from 18:25. Fix: the analyser reads every rotation from the node, and **gunzips** older ones (the next failure: `UnicodeDecodeError … 0x8b`, the gzip magic number). M4's agent faces the same rotation.
3. *Span names were all `orders`.* My first fix (`span.SetName` after routing) did nothing. otelhttp's own source (`handler.go:180`) re-applies its span-name formatter after the handler returns whenever `r.Pattern` is set, and the default formatter returns the operation name. Fix: `otelhttp.WithSpanNameFormatter`, which otelhttp calls both before and after routing.
4. *inventory's 3 ASGI `http send/receive` spans per request* were half of its span volume. `exclude_spans` exists only as a code parameter, so FastAPI is instrumented in code and disabled in the auto-instrumentor.
5. *`--set services[0].replicas=2` broke the render.* Helm **replaces lists**: the override became the whole list `[{replicas: 2}]`, with no name and no image. Fix: `services` becomes a map (D-11), so `--set services.orders.replicas=2` merges.
6. *Helm 4 refused the upgrade: `conflict with "kubectl" with subresource "scale": .spec.replicas`.* Helm 4 uses **server-side apply**, and my earlier `kubectl scale` had made kubectl a field owner. `--force-conflicts` at the *same* value (2) only made the field **co-owned**, so the conflict returned when the value changed to 1. Forcing at a different value made Helm the sole owner, verified with `kubectl get … --show-managed-fields` (which `-o json` hides by default): `spec.replicas owned by: helm (Apply)`. Rule: never `kubectl scale` a Helm-managed workload; use values.
7. *A failed `helm upgrade` still changed the cluster.* Revision 6 is `failed`, but it had already rolled inventory. Helm 4 applies objects one by one, so "failed" doesn't mean "nothing changed". Check `helm history` and the pods.
8. *postgres-0 restarted during the map conversion.* Sorted map keys reordered the bootstrap script, which changed the StatefulSet's pod template. It was harmless (`initdb` skipped; fast stop), but review the rendered diff before changing a database chart.

**Lab vs customer environment:** at Cobalt, pod UIDs work the same, but the customer's SOC sees `service.instance.id` in every Splunk event, so confirm it's acceptable to them (it's a random UID with no personal data). Probe paths may differ per platform, for example a service mesh adding its own health endpoints, so review the filter list during onboarding. Cobalt's CAB approves configuration, not code: the span-name and exclusion fixes are code, so they ship in the one image everyone runs, never per customer.

**Check yourself:**
1. What exactly goes wrong in Prometheus if two replicas push `http_server_request_duration_seconds_count` without `service.instance.id`?
2. We excluded `/readyz` from HTTP instrumentation, yet it still produced spans. Why, and why couldn't the spec's gate or M4's idle-rate gate catch it?
3. Why did `--set services[0].replicas=2` break the chart, and what does the same rule mean for M7's customer overlay?

<details><summary>answers</summary>

1. Both replicas produce the same label set (`job="freightline/orders"`, same `instance`), so they write to *one* series. Their cumulative counters interleave (replica A at 5000, B at 3100, A at 5010, …), and Prometheus reads every drop as a counter reset. `rate()` then adds the "reset" jumps and spikes, and samples arriving out of order are rejected. With `service.instance.id`, each replica is its own `instance` series, and `sum by (job)` adds them correctly.
2. The exclusion removes only the HTTP **server span**. The handler still runs `SELECT 1`, and psycopg's instrumentation traces it. With no parent span in context, it becomes a **root span** on every probe. The spec's gate checks only the rendered chart, and M4's gate checks the HTTP request-rate metric, which really is 0; neither looks at trace volume. Only looking at what a Collector actually receives shows it, which is why we inspect before trusting.
3. Helm merges **maps** key by key but **replaces lists** whole, so `services[0].replicas=2` produced a new list with a single element that has no name or image. For M7, the Cobalt overlay has to restate any list it touches in full, for example `service.pipelines.logs.processors` and `exporters`. If it names only the new exporter, the Loki exporter silently disappears. That's why the spec's overlay lists both `otlp_http/loki` and `splunk_hec/cobalt`.
</details>

## M2 — Prometheus with the OTLP receiver   (2026-09-27, session 1, tier A)

**Goal / requirement served:** FR-2 (metrics reach Prometheus's OTLP receiver with promoted resource attributes, including `freightline_pod_template_hash` for P03), ADR-P04-3 (OTLP push, not scrape), FR-6 groundwork (page/ticket routes), NFR cardinality and freshness.

**What we built:**
- `deploy/observability/kps-values.yaml`: kube-prometheus-stack **91.5.1**, `fullnameOverride: kps`. The spec's block as written (every key checked against the chart's `values.yaml` first), plus commented lab additions (DEVIATIONS D-12, D-15): 12 h retention, sizing, a random Grafana password, no phone-home, kind's localhost-only control-plane scrapers off, `defaultDatasourceScrapeInterval: 15s`, and apiserver cardinality drops.
- `app/deploy/helm/freightline/templates/networkpolicy.yaml`: `allow-alertmanager-to-mailpit` (monitoring/alertmanager → mailpit:1025).
- Library chart: `OTEL_METRIC_EXPORT_INTERVAL=15000`. orders: a metric View that drops `server.address`/`server.port`. Images are `0.2.4`.
- `app/deploy.sh`: always `helm dependency build` before `helm upgrade --install`.
- `scripts/kind-load-images.sh`: the M2 list (9 images, including the operator-injected `prometheus-config-reloader`, which never appears as an `image:` line).
- `tests/fixtures/otel-bridge-gateway.yaml` (temporary, deleted after the gate): `otlp` → `otlp_http/prometheus` with `sending_queue: { batch: {} }`, the spec's M4 exporter block. It ran on Collector 0.161.0 with 0 errors and 0 deprecation warnings.
- k6: `--no-usage-report` / `K6_NO_USAGE_REPORT=true`.

**How the data flows:**
- The SDK aggregates `http.server.request.duration` in the pod and pushes a cumulative snapshot **every 15 s** over OTLP/gRPC to `otel-gateway.observability:4317` (the bridge today, the real gateway in M4).
- The Collector forwards it to `http://kps-prometheus.monitoring:9090/api/v1/otlp`, batching in the exporter's `sending_queue`.
- Prometheus translates the names (`UnderscoreEscapingWithSuffixes`): the metric becomes `http_server_request_duration_seconds_{bucket,count,sum}`, and dots in attribute names become underscores.
- Resource → labels: `job` = `service.namespace/service.name` (`freightline/orders`), `instance` = `service.instance.id` (the pod UID, from M1). The five **promoted** attributes become labels on every series. All other resource attributes (`telemetry.sdk.*`, …) go on **one `target_info` series per instance**, to be joined only when needed.
- The histogram's exemplars (trace ID + span ID, M1) are stored in exemplar storage (100k) and returned by `/api/v1/query_exemplars`. Grafana's Prometheus datasource links `trace_id` to the `tempo` datasource uid, which lands in M3.
- There is no scrape, so **there is no `up` metric** for the apps: absence has to be detected with `absent_over_time()` (§8's `OrdersMetricsAbsent`, M4).
- Alerts: rule → Alertmanager → route on `severity` → Mailpit (`page@` or `ticket@`); `Watchdog` → `null`.

**Commands run, in order:**

| Command | What it does | Key output |
|---|---|---|
| `helm pull prometheus-community/kube-prometheus-stack --version 91.5.1 --untar` + `grep` for each spec key | Checks the spec against the real chart before running it | All keys exist. The chart is v0.94.1 operator; 91.7.1 is newer, kept the pin |
| `helm template … \| grep image:` | Lists what the node must have | 8 images + config-reloader; Prometheus 3.14.0, Grafana 13.2.2 (match the digest) |
| `bash scripts/kind-load-images.sh m2` | Side-loads | 8/9 OK; kube-state-metrics FAIL (`cdn.registry.k8s.io` Forbidden) |
| `helm install kps … --set kubeStateMetrics.enabled=false --wait` | Installs | **28 s**; RAM used about 1 → 2 GB (13 GB available) |
| The spec's `kubectl … jsonpath='{…args}'` | Gate half 1 | both flags present (`docs/evidence/p04/m2-gate-args.txt`) |
| `curl …/api/v1/status/runtimeinfo`, `/status/config` | Where settings really live | retention 12h, OOO 30m, exemplars 100k and promotion are all **config-file** settings, not flags |
| Bridge + in-cluster k6 (10 req/s × 60 s) + PromQL | Gate half 2 | both jobs, promoted labels, `target_info`, 5 exemplars (`docs/evidence/p04/m2-gate-otlp.txt`) |
| `POST /api/v2/alerts` (page + ticket) + Mailpit API | Routing test | `page@` got the page, `ticket@` got the ticket, Watchdog → `null` (`m2-alert-routing.txt`) |
| `curl …/api/v1/status/tsdb`, `count by (job)` | Cardinality | 43,860 → **24,031** active series after the drops (`m2-fixes.txt`) |

**Verification:**
- *Spec gate:* the Prometheus container args include `--web.enable-otlp-receiver` and `--enable-feature=exemplar-storage`. **PASS.**
- *Build prompt's gate addition:* an OTLP metric is queryable with the promoted labels. **PASS**: `http_server_request_duration_seconds_count{job="freightline/orders", instance="99881ea2-…", service_version="0.2.3", deployment_environment_name="kind", freightline_pod_template_hash="5774fd6997", http_route="/v1/orders", …}`, and the same for inventory. `k8s_namespace_name`/`k8s_pod_name` are absent until the M4 gateway's `k8s_attributes` sets them (expected).
- Also verified: the 15 s sample spacing on both services, 0 series with `server_address`, alert routing, and exemplars carrying `trace_id`/`span_id`.

**What broke and how we fixed it:**
1. *kube-state-metrics wouldn't pull.* `registry.k8s.io` redirected layers to `cdn.registry.k8s.io` (proxy 403). It was still denied after the host was added, because this container didn't pick up the change (no VM restart this time). Installed temporarily without it (D-14).
2. *orders' metrics were missing while inventory's arrived.* Go's gRPC exporter kept failing with `name resolver error: produced zero addresses` for about 2–3 minutes after the `otel-gateway` Service reappeared (it was deleted at the end of M1). The Service had endpoints; Python reconnected at once. grpc-go re-resolves DNS with backoff after failures. It **recovered on its own** (0 failures in the next 110 s). Lesson for M4: the gateway Service must never disappear, which is another reason for replicas plus a PDB.
3. *`rate(...[2m])` returned 0 for inventory right after load.* The raw samples showed the counter jumping 597 → 1188 between two samples **60 s apart**, so a 2-minute window at the wrong moment held two equal values. Root cause: the SDK's default 60 s export interval, which also breaks the < 30 s freshness NFR. Fix: `OTEL_METRIC_EXPORT_INTERVAL=15000`, and Grafana's `$__rate_interval` set for 15 s.
4. *The 15 s interval didn't apply.* The pods had no such env var: the umbrella chart renders the **packaged** library chart (`charts/*.tgz`), and I hadn't re-run `helm dependency build`. Fix: rebuilt, and added `app/deploy.sh`, which always rebuilds first. (M1 was unaffected: its gate ran after a rebuild.)
5. *`server_address`/`server_port` labels from the `Host` header* on orders' histogram (the port-forward's `localhost:18080` vs k6's `orders.freightline:8080`). Untrusted input was creating series. Fix: an SDK View deny-list (D-15b).
6. *43,860 active series on first install*, 88% of the budget before the app did anything. 25,268 came from the apiserver job; the 8 largest histograms have no consumers in kps's rules or dashboards. Fix: drop them at scrape time. The chart's default relabel list had to be **restated**, because lists replace (the M1 lesson again). The first re-measure still showed 25,302 because a reload recreates the scrape loop without staleness markers, so dropped series stay visible for the 5-minute lookback. Re-measured after it: **24,031** total, apiserver 10,842.
7. *NetworkPolicy isn't enforced in this lab* (D-13). The §12 failure couldn't be reproduced: the email arrived *without* the allow rule. kindnet's policy engine fails every nftables sync on this kernel.
8. *Phone-home.* The proxy log showed a blocked `stats.grafana.org` from the M0 k6 run. k6 usage reports and Grafana analytics/update checks are now off.

**Lab vs customer environment:** at Cobalt, Prometheus usually isn't ours: we'd push to *their* OTLP-capable backend, or keep this in-cluster for Beacon's on-call and export only logs to Splunk (M7). Their network team will ask which ports accept pushes: the OTLP receiver has no auth of its own, so only the gateway should reach it (a NetworkPolicy, on a CNI that enforces it; test enforcement, don't assume it). Their proxy blocks phone-home by default, which is why analytics is off here rather than failing noisily there. Northstar: Datadog ingests the same OTLP metrics, but its label rules differ; the promotion list becomes a Datadog tag allow-list.

**Check yourself:**
1. Why is there no `up` metric for orders, and what replaces it?
2. What does promoting `freightline.pod_template_hash` cost, and why is promoting `k8s.pod.uid` a bad idea when `service.instance.id` is already the pod UID?
3. A dashboard shows `rate(...[1m])` = 0 during a load test while the logs show traffic. List two causes we saw in this milestone.

<details><summary>answers</summary>

1. `up` is produced by the *scraper* for each target it scrapes. With OTLP push, Prometheus scrapes nothing for the apps, so "the app stopped sending" looks exactly like "no data". Alert on absence instead: `absent_over_time(http_server_request_duration_seconds_count{job="freightline/orders"}[10m])` (§8), plus the gateway's own `otelcol_*` metrics (M4). ADR-P04-3 accepts that trade.
2. It adds one label to every app series. Its values change only per rollout (one hash per ReplicaSet), so it multiplies series by the number of live ReplicaSets (1–2 during a canary), and P03 needs it to compare canary vs stable. `k8s.pod.uid` would duplicate `instance` (already the pod UID) without adding information, and every label costs index memory. Promote only what queries need, and leave the rest on `target_info`.
3. (a) The sample interval vs the range: with 60 s pushes, a `[1m]`/`[2m]` window can hold fewer than two different samples (fix: 15 s pushes and `$__rate_interval`). (b) The exporter wasn't connected: orders' gRPC client sat in DNS backoff for minutes after the gateway Service reappeared. The first shows as zero-rate data; the second as missing series. Check `timestamp()` of `target_info` to tell them apart.
</details>

## M3 — Tempo and Loki (monolithic)   (2026-09-27, session 1, tier A)

**Goal / requirement served:** FR-3 (traces reach Tempo, with span metrics and exemplars; logs reach Loki with `trace_id`/`span_id` as structured metadata), groundwork for FR-4 (exemplar → trace → logs). Ground-truth trap handled: the OSS Tempo and Loki charts now come from **`grafana-community`** (OCI on ghcr.io).

**What we built:**
- `deploy/observability/tempo-values.yaml`: Tempo **3.0.3** (chart 3.0.0), a single binary. The metrics-generator runs `service-graphs` and `span-metrics` and remote-writes to `kps-prometheus` with `send_exemplars: true`. 12 h retention, no usage reports.
- `deploy/observability/loki-values.yaml`: Loki **3.7.8** (chart 18.13.5), `Monolithic`, filesystem, `allow_structured_metadata`, 12 h retention through the compactor, no analytics, and **`read`/`write`/`backend` replicas 0** (a spec error, D-16). The sidecar comes from quay.io.
- `scripts/kind-load-images.sh`: M3 list, plus a loader rewritten around `ctr import --platform linux/amd64`, with a fresh-pull fallback (D-18).
- `tests/fixtures/otel-bridge-gateway.yaml`: now carries the spec's three exporters and OTLP/HTTP (temporary; deleted after the gate).
- `tests/m3-correlation.sh`: the correlation gate, reusable in M4.

**How the data flows:**
- **Trace:** orders' server span → OTLP/gRPC → gateway (`otlp_grpc/tempo`, batching in its `sending_queue`) → Tempo's distributor → ingester → blocks on the local filesystem. Queryable at `:3200/api/v2/traces/<id>`.
- **Span metrics:** Tempo's metrics-generator also sees every span. It counts calls, sizes and latency per `(service, span name, kind, status)` and builds the service graph from client/server span pairs (`orders → inventory`). It remote-writes these to Prometheus as `traces_spanmetrics_*` / `traces_service_graph_*`, attaching exemplars that point back at real traces.
- **Log:** a JSON line → (M4: the agent's `file_log` + `json_parser` lift `trace_id`/`span_id` into the OTLP record's traceId/spanId) → gateway `otlp_http/loki` → Loki `/otlp`.
- In Loki, **resource** attributes on its default list become index labels (`service_name`, `service_namespace`, `service_instance_id`, `k8s_pod_name`, …). The record's `trace_id`/`span_id`, plus `severity_*`, `scope_name` and `observed_timestamp`, become **structured metadata**, stored with the line and filterable (`| trace_id="…"`) but never indexed.
- Grafana (provisioned in M2) already has `tempo` and `loki` datasources: Tempo → Loki via `tracesToLogsV2` (`filterByTraceID`, `service.name → service_name`), and Loki → Tempo via the `trace_id` derived field. M5 clicks through them.

**Commands run, in order:**

| Command | What it does | Key output |
|---|---|---|
| `helm pull oci://ghcr.io/grafana-community/helm-charts/{tempo,loki} --untar` + `grep` | Checks the spec's keys against the real charts | Tempo's keys map 1:1 (`overrides` rendered via `toYaml`); Loki's keys exist, `limits_config` is a map (merges with chart defaults) |
| `helm template loki … -f loki-values.yaml` | Renders | **Fails** on validate.yaml (D-16). With the fix: 1 StatefulSet |
| `bash scripts/kind-load-images.sh m3` | Side-loads | Tempo OK; Loki blocked by a broken local blob, then 4 s with the reworked loader; kiwigrid 429 → switched to quay.io |
| `helm install tempo …` ‖ `helm install loki …` (parallel, `--wait`) | Installs | both in **46 s** |
| `kubectl -n monitoring get pods` | The spec's gate | `tempo-0` 1/1, `loki-0` 2/2 Ready (`docs/evidence/p04/m3-gate-pods.txt`) |
| `curl :3100/config`, `:3200/status/config` | Effective config | Loki: structured metadata on, 12h, 18 default OTLP index labels; Tempo: both processors |
| In-cluster k6 (10 req/s × 60 s) + `bash tests/m3-correlation.sh` | The correlation gate | **9 passed, 0 failed** (`m3-correlation.txt`) |
| PromQL `count(...)` | Cardinality and memory | 25,185 active series (+321 from `traces_*`); Prometheus 291 MiB, Loki 118 MiB, Tempo 100 MiB (`m3-series.txt`) |

**Verification:**
- *Spec gate:* `tempo-0` and `loki-0` Ready. **PASS.**
- *Build prompt's gate:* one trace and one log line found by trace_id. **PASS** for `trace_id=909e13cb843b7b562876e780d5c98c92`:
  - Tempo returns 9 spans across `orders` and `inventory`.
  - Loki returns the orders line for `{service_name="orders"} | trace_id="909e13cb…"`, and `trace_id` is absent from `/loki/api/v1/labels`.
  - The log line entered through the bridge's OTLP/HTTP endpoint as a stand-in for the M4 agent, **labelled as such**. It's the exact JSON line orders printed, with its real trace and span IDs.
- *Also:* span-metric series for orders, the `orders → inventory` service-graph edge, and 52 span-metric exemplars in Prometheus.

**What broke and how we fixed it:**
1. *The spec's Loki values fail to render* on chart 18.13.5 (D-16). Evidence: the validate.yaml error. Root cause: the SimpleScalable targets default to 3 replicas each. Fix: set them to 0. This is a spec correction, recorded rather than applied silently.
2. *`grafana/loki:3.7.8` couldn't be loaded into kind,* for two independent reasons (D-18):
   - Docker's store had the amd64 manifest but an unreadable 162-byte shared layer, so every `docker save` failed, even after a successful re-pull.
   - `kind load` insists on all platforms.
   - Fix: pull with `ctr` into a separate namespace (Docker's own images untouched), export amd64, and import into the node with `--platform linux/amd64`. That's now the script's default path.
3. *Docker Hub 429 for `docker.io/kiwigrid/k8s-sidecar`.* Fix: the identical image from quay.io, already on the node.
4. *orders' exporter reconnect lag again* after the bridge Service reappeared: about 40 s this time, 2–3 minutes in M2. Consistent with grpc-go's DNS re-resolution backoff; noted for M4's "never delete the gateway Service".

**Lab vs customer environment:** at Cobalt, traces usually stay in Beacon's Tempo, because the SOC wants logs (M7). If the customer runs its own Tempo or Jaeger v2, it's another `otlp_grpc` exporter, never Jaeger v1 (EOL). Storage becomes object storage (S3/GCS/MinIO) with real retention: the SOC contract says 60 s to Splunk, not how long Beacon keeps traces. Loki's default index labels include `k8s.pod.name` and `service.instance.id`, which churn per rollout; at scale, pin `otlp_config` to a short, reviewed list. Northstar's Datadog ingests the same OTLP traces, and APM stats need the `datadog/connector` (M7).

**Check yourself:**
1. Why is `trace_id` structured metadata in Loki and not a label, and what would happen at 100 req/s if it were a label?
2. The service graph showed an `orders → inventory` edge. Which spans did Tempo pair to build it, and why does the edge disappear if inventory's traces are sampled differently from orders'?
3. The spec's Loki file failed to render. Why is it better that the chart *failed* than rendered something?

<details><summary>answers</summary>

1. Every distinct label set is a separate Loki stream, with its own chunks and index entries. A trace ID per request means one new stream per request: 100 req/s is 360,000 tiny streams an hour, crushing the ingester and index (Loki's classic cardinality failure). As structured metadata the ID is stored next to each line inside the few streams per pod, and `| trace_id="…"` filters within the streams selected by the indexed `service_name`.
2. It pairs orders' **client** span (`HTTP POST`, kind client) with inventory's **server** span (`POST /v1/reservations`, kind server) that has the client span as its parent. If inventory drops traces orders keeps, or vice versa, one half of each pair never reaches Tempo, and the edge vanishes or its counts become wrong. That's why sampling is parent-based (the child follows the parent's decision) and why tail sampling needs span metrics computed *before* sampling (§10).
3. A render that silently kept `read`/`write`/`backend` at 3 replicas each would have created a SimpleScalable deployment beside the monolith on shared storage it doesn't support: 10 pods, far more RAM, and confusing write paths, discovered at runtime. A validation failure costs one minute at render time, with an explicit message.
</details>

## M4 — Gateway and agent Collectors   (2026-09-27, session 1, tier A)

**Goal / requirement served:** FR-1 (apps send OTLP only to `otel-gateway.observability:4317`; a node agent collects stdout JSON logs), FR-3 end to end, FR-8 (the pipeline alerts on itself), ADR-P04-1 (one gateway owns destinations), ADR-P04-2 (logs via a node agent, not the logs SDK), NFR durability (gateway ×2 + PDB), NFR freshness (measured).

**What we built:**
- `deploy/observability/otel-gateway-values.yaml`: Collector contrib **0.161.0** (chart 0.173.1, whose appVersion is 0.160.0). Deployment ×2, PDB `minAvailable: 1`, 1 GiB limit with the chart's `memory_limiter` (80% limit, 25% spike), `k8s_attributes` (pod UID first, then connection IP), `resource` (`k8s.cluster.name`), and three exporters, each with `sending_queue: { batch: {} }` (no `batch` processor). ServiceMonitor on :8888. Only OTLP and metrics ports exposed.
- `deploy/observability/otel-agent-values.yaml`: DaemonSet. `file_log` on `/var/log/pods/freightline_*/app/*.log` → `container` parser → `json_parser` (severity from `level`, trace/span IDs into the log record) → `memory_limiter` → `k8s_attributes` (pod UID association; pod label `app.kubernetes.io/name` → `service.name`) → `otlp_grpc` to the gateway.
- `deploy/observability/pipeline-alerts.yaml`: PrometheusRule `telemetry-pipeline`. §8's four alerts with **corrected** expressions (D-20, D-21). `tests/pipeline-alerts.test.yaml` + `tests/promtool-rules.sh`: 7 promtool cases.
- `tests/m4-pipeline.sh`: the spec's two gate queries, plus freshness, enrichment and self-metric checks.

**How the data flows:**
- **Metrics/traces:** SDK → gateway pod (Service load-balances per gRPC connection) → `memory_limiter` (refuses with `RESOURCE_EXHAUSTED` above ~819 MiB, and the SDK retries) → `k8s_attributes` (looks up the *source IP* in its pod cache, adds `k8s.namespace.name`, `k8s.pod.name`, `k8s.deployment.name`, …) → `resource` → exporter queue → Prometheus / Tempo.
- **Logs:** the container runtime writes `<ts> stdout F {"level":"info",...,"trace_id":"…"}` under `/var/log/pods/freightline_<pod>_<uid>/app/0.log`.
  1. The agent's `container` parser strips the CRI prefix and takes namespace, pod name and **pod UID** from the path.
  2. `json_parser` turns the JSON into attributes, sets severity from `level`, and **moves `trace_id`/`span_id` into the log record's own TraceId/SpanId fields**.
  3. `k8s_attributes` finds the pod *by UID*, not by IP: every log reaches the gateway from the agent's IP. It copies the pod label `app.kubernetes.io/name` into `service.name`.
  4. OTLP → gateway (its `k8s_attributes` matches on the same UID) → `otlp_http/loki`.
  5. Loki indexes `service_name` and keeps `trace_id`/`span_id` as structured metadata.
- **Self-metrics:** each gateway serves `otelcol_*` on :8888 → ServiceMonitor → Prometheus → the `telemetry-pipeline` rules → Alertmanager (M2 routes).

**Commands run, in order:**

| Command | What it does | Key output |
|---|---|---|
| `helm pull open-telemetry/opentelemetry-collector --version 0.173.1` + read `_config.tpl` | How presets name components | `rewriteDeprecatedComponentNames: true` (default) → presets inject `k8s_attributes`, `file_log`, matching the spec |
| `helm template` both + `otelcol-contrib validate` (0.161.0 image) | §7 config test on the *rendered* configs | both exit 0, no warnings |
| `helm install otel-gateway …` then `otel-agent …` | Installs | **14 s**; 3 pods, 0 warn/error log lines |
| `helm upgrade otel-gateway …` (ports) | Closes Jaeger/Zipkin Service ports | Service now `metrics:8888 otlp:4317 otlp-http:4318` |
| `bash tests/m4-pipeline.sh` ×3 | End-to-end | **16/16 each run** (`docs/evidence/p04/m4-pipeline.txt`) |
| `bash tests/promtool-rules.sh` | Rule check + unit tests | `SUCCESS: 4 rules found`, tests `SUCCESS` (`m4-alert-tests.txt`) |
| `kubectl apply -f deploy/observability/pipeline-alerts.yaml` | Loads the alerts | 4 rules `inactive`, health `ok` |
| `kubectl delete pod <orders>` (timed) | M0 open item | **10.8 s** (was 30 s without a gateway) (`m4-shutdown.txt`) |
| `bash tests/m4-pipeline.sh idle-gate` after 5 idle minutes | The spec's gate | **orders 0, inventory 0** (`m4-gate-idle.txt`) |
| Grafana port-forward + `/api/datasources/uid/*/health` | §6 verification | prometheus, tempo, loki all OK |

**Verification:**
- *Spec gate (probe filter):* `sum by (job) (rate(http_server_request_duration_seconds_count{job=~"freightline/.*"}[5m]))` → `freightline/orders 0`, `freightline/inventory 0` after more than 5 idle minutes, while kubelet counters show 3,118 readiness probes on inventory and 348 on orders. **PASS.**
- *Spec gate (logs):* `{service_name="orders"} | trace_id != ""` → **1 stream** (`service_name=orders`, `k8s_namespace_name=freightline`, `k8s_pod_name=orders-…`, `trace_id`, `span_id`, `severity_text=info`). **PASS.**
- *Beyond the gate (all measured, n=3):* for one uniquely identifiable order:
  - the log line's structured-metadata `trace_id` equals the one inside its JSON body, and severity is parsed;
  - its trace in Tempo contains both services;
  - the gateway adds `k8s_namespace_name`/`k8s_pod_name` to metrics;
  - both gateway replicas are scraped, the three exporters have sent 5,301 spans, 1,204 log records and 208 metric points, with 0 send failures and 0 refusals.
  - **Freshness:** Loki **1.1 s** (NFR < 15 s); complete trace **4.8–5.3 s**; newest metric sample **1.4–10.9 s** old (NFR < 30 s).

**What broke and how we fixed it:**
1. *Chart default ports.* The gateway Service exposed Jaeger/Zipkin ports although those receivers were disabled. Closed them (D-19; §9 spoofing).
2. *My freshness test reported "0.0 s".* The orders port-forward had died with the replaced pod, the POST returned nothing, and `|= ""` matched every line. **A test that can't fail isn't a test.** Fix: stop when there's no order ID. The numbers above come from runs after the fix.
3. *The spec's self-metric names match nothing.* Collector 0.161 counters have no `_total` suffix, and `send_failed_*` series appear only after a first failure. The spec's §8 alerts would never fire. Fix: real names, plus a promtool case that proves the `_total` form stays silent (D-20).
4. *Trace "freshness" stopped too early.* orders alone produces 6 spans, and inventory's arrive up to 5 s later (the Python `BatchSpanProcessor` schedule delay). Fix: wait for both services.
5. *The idle gate first returned no orders series at all.* The orders pod had been replaced for the shutdown test and never served a request, and OTel histograms are exported only after their first measurement. Absence isn't zero. That also exposed a false-page bug in the spec's `OrdersMetricsAbsent` (a quiet-hours restart would page). Fix: alert on `target_info`, exported every 15 s regardless of traffic (D-21), with a promtool case for the restarted-idle-pod scenario. Gate re-run after one seed request and 5 idle minutes: 0/0.
6. *Go exporter reconnect lag after the gateway appeared.* 2 failed exports right after install, then none. This is the M2/M3 DNS-backoff pattern; the gateway now has 2 replicas and a PDB, and its Service is never recreated.

**Lab vs customer environment:** at Cobalt, the gateway is tier 1 on *their* nodes. They'll ask for the RBAC scope (read-only pods/namespaces/replicasets via a ClusterRole), the listening ports (4317/4318/8888 only), and what happens when the gateway is full: `memory_limiter` refuses, the SDKs retry and then drop, and `TelemetryRefused` tickets. The agent needs a hostPath read of `/var/log/pods`, which some platforms' PSA `restricted` forbids; it runs in `observability`, not `freightline`. At scale the agent should checkpoint file offsets (`file_storage`) so a restart neither loses nor re-sends logs, and the gateway needs HPA and a `load_balancing` tier if tail sampling (§10) arrives. Northstar is the same, with the Datadog exporter in M7.

**Check yourself:**
1. Why does the agent associate logs with pods by `k8s.pod.uid`, while the gateway uses UID *then* connection IP?
2. `memory_limiter` is at 80% of 1 GiB. What happens to a span arriving when the gateway is at 850 MiB, and who notices?
3. Why is "no series" not the same as "rate 0", and which two things in this milestone depended on that difference?

<details><summary>answers</summary>

1. Every log record reaches the gateway over the agent's connection, so the source IP identifies the *agent*, not the pod that wrote the line. The agent knows the real pod from the log file path, which the container parser turns into `k8s.pod.uid`, so association by UID is exact. Traces and metrics come straight from the app pods, whose source IP *is* the pod: the gateway first tries the UID (present on agent logs), then falls back to the connection IP (SDK traffic).
2. The receiver refuses it (`RESOURCE_EXHAUSTED`), so nothing is accepted that the gateway can't hold. The SDK retries with backoff and eventually drops. `otelcol_receiver_refused_spans` increases, and `TelemetryRefused` raises a ticket. Memory falls as queues drain and GC runs, and the pod is never OOM-killed. That's backpressure instead of a crash that would lose everything in memory.
3. `rate()` over a series with equal samples is 0: the thing exists and is idle. With no series, the query returns nothing: the thing never reported. The idle gate needed a pod that had served requests to show 0, and `OrdersMetricsAbsent` must watch a series that exists even with no traffic (`target_info`), or it pages on every quiet restart.
</details>

## M5 — RED, USE and Flow dashboards as code   (2026-09-28, session 1, tier A)

**Goal / requirement served:** FR-5 (dashboards are JSON in Git), FR-4 (exemplar → trace → logs, walked through), success criterion 2 (RED for every service and USE for every pod and the node, from one template). Deploy annotations stand in for P03's.

**What we built:**
- `deploy/observability/dashboards/generate.py`: one Python definition produces `json/{red,use,flow}.json` (reviewable) and `{red,use,flow}.yaml` (ConfigMaps labelled `grafana_dashboard: "1"`). RED is one template, with `$service` = Prometheus `job`.
- **RED** (7 panels), **USE** (13), **Flow** (7, adapted for P04-lite, D-01a). All carry **rollout annotations** computed from `target_info`: a `(job, freightline_pod_template_hash)` pair that didn't exist 2 minutes ago is a new ReplicaSet.
- `tests/m5-dashboard-queries.py`: fetches each dashboard *back from Grafana* and runs every panel query through `/api/ds/query`.
- `tests/m5-walkthrough.mjs`: exemplar → trace → logs through the APIs, plus Grafana screenshots (headless Chromium).
- Fixes found by those tests: the library chart's `replicas` (`default` turns 0 into 1), orders' DB span attributes, and Tempo's service-graph `peer_attributes` (D-24).

**How the data flows (what a panel does to it):**
- *RED rate/errors:* `sum by (job) (rate(http_server_request_duration_seconds_count{job=~"$service"}[$__rate_interval]))`. `$__rate_interval` is at least 4× the datasource step, which we told Grafana is 15 s (M2). Errors divide the 5xx subset by all. The `or … * 0` term makes "no errors" read **0%**; without it the division returns nothing and the panel says "No data".
- *RED duration:* `histogram_quantile(0.99, sum by (job, le) (rate(…_bucket[…])))` interpolates inside buckets. With `exemplar: true`, Grafana also fetches `/api/v1/query_exemplars` and draws a dot per exemplar; its `trace_id` label links to the `tempo` datasource (M2's `exemplarTraceIdDestinations`).
- *Latency SLI:* `…_bucket{le="0.25"} / …_count` is **exact** because 0.25 is a real bucket boundary (M1 evidence), so M6 uses 250 ms and not 300.
- *Trace → logs:* Grafana's Tempo datasource (`tracesToLogsV2`) maps `service.name` → `service_name` and adds `| trace_id="…"`. Loki finds the lines by structured metadata inside the per-pod stream (M3).
- *Flow:* LogQL metrics over the JSON body (`| json | msg="order accepted"`) count orders by status. Tempo's span metrics give p99 per span including SQL, and the service graph is drawn **in the browser** from `traces_service_graph_*` series.
- *USE:* cAdvisor (kubelet) gives CPU seconds, working set and OOM events per container; node-exporter gives the node. kube-state-metrics would add requests, limits, restarts and termination reasons (D-14).

**Commands run, in order:**

| Command | What it does | Key output |
|---|---|---|
| PromQL `count(<metric>)` for each USE input | What exists today | cAdvisor CPU/working set/OOM events and node-exporter: yes. `container_spec_*` (dropped by kps), CFS (no CPU limits), `kube_*` (D-14): no |
| `python3 deploy/observability/dashboards/generate.py` | Builds the dashboards | red 7, use 13, flow 7 panels |
| `kubectl apply --dry-run=server -f deploy/observability/dashboards/` | Validates | 3 ConfigMaps; `generate.py` and `json/` ignored |
| `kubectl apply -f …/dashboards/` + Grafana `/api/search?tag=freightline` | Loads | 3 dashboards in about 10 s, no import step |
| The spec's gate | | **3** (`docs/evidence/p04/m5-gate.txt`) |
| `python3 tests/m5-dashboard-queries.py` (during k6 load) | Every panel through Grafana | first run: 1 error, 6 empty; final: **0 errors**, all EMPTY explained (`m5-dashboard-queries.txt`) |
| `bash app/deploy.sh --set services.inventory.replicas=0`, 3 orders, `bash app/deploy.sh` | Produces the degraded-precheck event | 3 × PENDING; the precheck, warn/error and PENDING panels light up |
| `node tests/m5-walkthrough.mjs` | exemplar → trace → logs + screenshots | 58–73 exemplars/15 min; slowest 50.6 ms → 9-span trace (43.4 ms in inventory's `UPDATE`) → 2 log lines (`m5-walkthrough.txt`, `m5-{red,trace,logs,flow,use}.png`) |

**Verification:**
- *Spec gate:* `kubectl -n monitoring get configmap -l grafana_dashboard=1 --no-headers | grep -c freightline` → **3**. **PASS.**
- *Walk-through (build prompt):* from the RED p99 panel's slowest exemplar (`fddccd24…`, 50.6 ms), the Tempo trace shows `POST /v1/orders` → `HTTP POST` → inventory `POST /v1/reservations` → `UPDATE` (43.35 ms, the bottleneck), and Loki returns orders' `order accepted` and inventory's `stock reserved` for that `trace_id`. **PASS**, with screenshots.
- *Panel queries:* 27 panels, 0 errors. Expected EMPTY: 4 kube-state-metrics panels (D-14), CFS throttling (no CPU limits), DB pool exhausted (M8's event).

**What broke and how we fixed it:**
1. *Error ratio showed "No data" when healthy.* With no 5xx, the numerator has no series and `a / b` returns nothing: absent is not zero (M4's lesson again). Fix: `(errors or total * 0) / total`. The axis then read "0–10000%" on all-zero data; fixed with a 1% soft maximum.
2. *The service graph panel returned `unsupported query type: 'serviceMap'`* through `/api/ds/query`. Not a dashboard bug: Grafana builds the map in the browser from Prometheus queries. The linter checks those series instead, and the browser screenshot shows the panel.
3. *`--set services.inventory.replicas=0` didn't take inventory down.* The library chart used `{{ .svc.replicas | default 1 }}`, and sprig's `default` treats 0 as empty. Fix: `hasKey`. A scale-to-zero that silently doesn't happen would have broken M8's game day.
4. *One Postgres drawn as two nodes* (`postgresql`, `postgres`): cross-language semconv drift (D-24). The first fix (`server.address`) renamed the uninstrumented caller `orders.freightline`, so the final choice is `db.system.name`, which both languages now emit.
5. *Every screenshot was "Grafana has failed to load its application files"*, five files of identical size. I checked one instead of trusting it. The console showed `RangeError: Invalid language tag: en-US@posix`: headless Chromium inherits the VM's POSIX locale. Fix: `locale: "en-US"`.
6. *ES modules ignore `NODE_PATH`*, so the global Playwright was invisible. Fix: `createRequire` from `npm root -g`.

**Lab vs customer environment:** at Cobalt, dashboards go through the same CAB as other configuration. Generated JSON plus a Git diff *is* the change record, and `editable: false` stops drift in the UI. Their SOC watches Splunk, not Grafana, so the dashboards serve Beacon's on-call; the SOC's equivalent is a saved Splunk search over the exported logs (M7). The USE ratios need kube-state-metrics, which customers usually already run; reuse theirs rather than deploying a second one. Northstar would get Datadog dashboards from the same OTLP data; the dashboards themselves aren't portable, and that's fine, because the telemetry is.

**Check yourself:**
1. Why does the error-ratio query need `or sum(...) * 0`, and what would an on-call engineer have concluded without it?
2. The p99 panel and the "within 250 ms" stat both come from the same histogram. Which one is exact, and why?
3. The walk-through's slowest request spent 43 of 50 ms in inventory's `UPDATE`. Which dashboard panel would have shown you that *without* opening a trace, and why is the trace still necessary?

<details><summary>answers</summary>

1. With no 5xx responses, the numerator selects no series and PromQL's division has nothing to match, so the query returns no result and the panel says "No data". During an incident, "No data" on the error panel reads like a broken pipeline, the opposite of "0% errors". `or total * 0` adds a zero-valued series with the same labels when the numerator is missing.
2. The 250 ms stat is exact: `le="0.25"` is a real bucket boundary, so "requests ≤ 0.25 s" is a counted fact. p99 comes from `histogram_quantile`, which assumes an even distribution inside the bucket that holds the 99th percentile and interpolates, so it can be off by up to the bucket width (0.1–0.25 s here). That's why the SLO is 250 ms, not 300 ms.
3. Flow's "p99 by span" (Tempo span metrics) shows `UPDATE` latency per span name across all requests. It tells you *which operation* is slow in aggregate. The trace shows *this* request's chain (orders waiting on inventory waiting on Postgres) and leads to its logs, and aggregates can't show causality inside one request. Exemplars connect the two views.
</details>

## M6 — SLOs and burn-rate alerts   (2026-09-28, session 1, tier A)

**Goal / requirement served:** FR-6 (SLO specs in Git generate multi-window multi-burn-rate rules with separate page and ticket routes), ADR-P04-4 (Sloth in CI, no controller in the cluster), success criterion 3 (a 50% burst pages within 5 minutes; a steady 0.1% never pages in 2 hours).

**What we built:**
- `deploy/observability/slo/orders.yaml`: Sloth `PrometheusServiceLevel` with **availability 99.9%** and **latency 99% within 250 ms** for `freightline/orders`. Availability's `errorQuery` has `or vector(0)` (D-25).
- `deploy/observability/slo/generated/orders.rules.yaml`: the generated PrometheusRule **`freightline-orders`** (34 rules: 8 SLI recordings + 7 meta recordings + 2 alerts per SLO), committed.
- `tests/slo-burn.test.yaml`: promtool cases for the burn maths; `tests/promtool-rules.sh` runs them with the FR-8 cases.
- `tests/burn-tests.sh`: the live slow, fast and latency burns, faults set through Helm values, alert and email timing.
- orders **0.2.6**: `FAULT_LATENCY_RATE` / `FAULT_LATENCY_MS` (the latency counterpart of P03's `FAULT_5XX_RATE`).
- `docs/runbooks/slo-burn.md`, `docs/runbooks/queue-filling.md`: the targets of every alert's `runbook_url` (§8).

**How the data flows:**
- `http_server_request_duration_seconds_{count,bucket}` (OTLP, every 15 s) → Sloth's **SLI recording rules** compute the error ratio over 5m, 30m, 1h, 2h, 6h, 1d, 3d (`slo:sli_error:ratio_rateX`). Availability: 5xx / all. Latency: (all − `le="0.25"`) / all, exact because 0.25 is a bucket boundary.
- **Meta rules** turn ratios into budget: `slo:objective:ratio`, `slo:error_budget:ratio` (0.001 / 0.01), `slo:current_burn_rate:ratio`, `slo:period_error_budget_remaining:ratio` (30 d).
- **Alerts:** page = (5m > 14.4·b AND 1h > 14.4·b) OR (30m > 6·b AND 6h > 6·b); ticket = (2h > 3·b AND 1d > 3·b) OR (6h > b AND 3d > b). The long window says how much budget is gone; the short window says it's *still* burning, so a fixed problem stops paging.
- Alertmanager (M2) routes on `severity`: page → `page@lab.local`, ticket → `ticket@lab.local`, each on its own route (own group, own `group_wait` 30 s).

**Commands run, in order:**

| Command | What it does | Key output |
|---|---|---|
| `sloth generate -i …/orders.yaml -o …/generated/orders.rules.yaml` | Generates rules | PrometheusRule `freightline-orders`, 34 rules; `(errors or vector(0)) / (total)`, correctly parenthesised |
| `bash tests/promtool-rules.sh` | `check rules` + unit tests | 4 + 34 rules OK; pipeline and SLO tests `SUCCESS` (`docs/evidence/p04/m6-rule-tests.txt`) |
| `kubectl apply -f deploy/observability/slo/generated/` + the spec's gate | Loads the rules | `freightline-orders` listed (`m6-gate.txt`); alert groups `inactive/ok` |
| `bash tests/burn-tests.sh` (background, 04:14–04:54) | Live burns at 10 req/s in-cluster | see Verification (`m6-burn-tests.txt`) |
| poll `ALERTS` until 05:09 | Verifies the resolve explanation | page resolved at 05:09:16 |

**Verification:**
- *Spec gate:* `kubectl -n monitoring get prometheusrule freightline-orders` lists the rule. **PASS.**
- *§7 burn tests, live (10 req/s):*

| Test | Fault | Result | Criterion |
|---|---|---|---|
| Slow burn (shortened, D-26) | `FAULT_5XX_RATE=0.001` for 20 min | **0 pages in 80 checks**; 5m and 1h ratios 0.001 (1×); no page email | no page ✔ |
| Fast burn | `FAULT_5XX_RATE=0.5` | page **firing after 60 s** (1h ratio 0.015 > 0.0144); **email after 90 s** (`group_wait`); ticket too | < 5 min ✔ |
| Fast burn, resolve | fix at 04:38:53 | 5m ratio 0 within minutes; page **resolved at 05:09:16 (30 m 23 s)**, held by the 6×/6 h/30 m pair until the burst left the 30 m window | explained, measured |
| Latency burn | every request +300 ms | page **firing after 211 s** via the 6×/30 m/6 h pair (30m 0.101, 6h 0.065 > 0.06); **email after 236 s** | page ✔ (earlier than the 8.6-min formula, see below) |

- *§7 burn tests, promtool (full length):* 50% pages within 5 min; 2% doesn't page at 30 min but pages by 50 (formula 43); latency pages after about 8.6 min, not at 5; **steady 0.1% never pages over 9 h of simulated time**; a healthy SLO reads 0.

**What broke and how we fixed it:**
1. *A healthy SLO would have read "absent".* With no 5xx, Sloth's error query has no series. Added `or vector(0)`; verified Sloth wraps the error query in parentheses, so `/` doesn't bind first; unit-tested.
2. *The spec's detection maths assumes full windows.* My first promtool run (1 h of clean history) paged 2% errors before 30 minutes, and the latency burn at 5 minutes. The 6×/6 h/30 m pair fires when the 6 h window holds little history. With 6 h of clean history the formula holds. The live run showed the same effect: the lab's history is sparse (bursts of k6), so the latency page came at 211 s rather than about 9 minutes, and the availability page held for 30 minutes after the fix. **Burn-rate alerting assumes steady traffic; in quiet periods short bursts dominate the long windows.**
3. *Steady 0.1% opens a ticket.* Exactly 1× burn against the 1× threshold `1 × (1 − 0.999)` = 0.00099999999999994. The spec only forbids a page, and a 1× ticket is the designed response ("you'll spend the whole budget this month"). Documented, not asserted.
4. *The burn script's email check stopped at the ticket email,* which arrives first, and reverted the fault before the page email's `group_wait`. The page email was confirmed by hand (04:54:55); the script now waits for `page@`.
5. *promtool rejected `promql_exp_test`.* The key is `promql_expr_test`. Unknown keys fail loudly, which is what you want from a test runner.

**Lab vs customer environment:** at Cobalt, the SLO spec is the artefact the CAB reviews, and the generated rule diff is the evidence. They'll want the page route to go to *their* incident tool (not Opsgenie, which shuts down 2027-04-05) and the ticket route to their ITSM queue. Real traffic is steadier than a lab's, so the burn maths behaves as designed, but low-traffic services (nights, weekends) show the same quiet-period effect we measured. Common mitigations are a minimum-request guard on the page (e.g. `and sum(rate(…_count[1h])) > 1`) or a longer latency SLO window. Northstar would use Datadog SLOs over the same metrics; the Sloth spec documents the intent either way.

**Check yourself:**
1. After the fix, the 5 m ratio was 0 within minutes, but the page stayed firing for 30 minutes. Which pair held it, and what would have made it clear sooner?
2. Why does a steady 0.1% error rate never page but can open a ticket, and why is that the *right* behaviour?
3. The latency page fired after 3.5 minutes instead of the formula's 8.6. Is the formula wrong?

<details><summary>answers</summary>

1. The second page pair: 30m > 6·b AND 6h > 6·b. The 30 m window still held the 1.6-minute 50% burst (ratio about 0.03 > 0.006), and the 6 h window held so little lab traffic that the burst dominated it too (0.019). It cleared when the burst left the 30 m window (30 m 23 s). With steady traffic filling the 6 h window, the burst would have been about 0.2% of it, below 0.6%, and the page would have cleared with the 5 m window.
2. 0.1% errors against a 99.9% objective is exactly 1× burn: you'll spend exactly the whole monthly budget. That's not an emergency (nothing about the next hour is worse than planned), so no page. It *is* worth a ticket, because there's no headroom left for anything else this month. Paging on it would teach on-call to ignore pages.
3. No. The formula `60 × 14.4 / B` describes the *first* pair (1 h and 5 m) starting from a clean, **full** history. Here the *second* pair (6 h and 30 m at 6×) fired first, because the 6 h window held only sparse lab traffic. With 6 hours of steady history (the promtool case), the latency page fires between 5 and 12 minutes, as the formula predicts.
</details>

## M7 — Customer export mode   (2026-09-28, session 1, tier A)

**Goal / requirement served:** FR-7 (an overlay adds Splunk HEC or Datadog exporters with PII removal, a persistent queue and proxy/CA support), ADR-P04-1 (a customer backend is a values overlay), success criterion 4 (values change only; counts within 0.1%; no log loss across a 10-minute sink outage), §9 (information disclosure, credential exposure).

**What we built:**
- `deploy/observability/customer-sim-values.yaml`: the Splunk stand-in. A Collector with `splunk_hec` receivers (:8088 plain; :8089 TLS as `hec.cobalt.example`), a file exporter, an inspector sidecar, and a ServiceMonitor.
- `deploy/observability/export-splunk-values.yaml`: the Cobalt profile. The spec's overlay plus two gap fixes: `transform/pii` (body redaction, D-27) and the queue sized in records (200k, D-29).
- `deploy/observability/export-splunk-proxy-values.yaml`: Cobalt at-site additions, as a third values file. `HTTPS_PROXY`, a widened `NO_PROXY` (D-31), the inspection CA via `tls.ca_file`, the TLS endpoint. It restates the lists it replaces (token env, queue volume).
- `deploy/observability/proxy-sim/`: mitmproxy 12.2.3 as Cobalt's TLS-inspecting proxy. `install.sh` generates the CAs and the server certificate into Secrets (never committed); the gateway gets only the CA certificate.
- `deploy/observability/export-datadog-values.yaml`: the Northstar profile, `datadog/connector` + `datadog/northstar`, render + validate only.
- `tests/sink-outage.sh`: §7's parity and outage test. `load/steady.js` seeds a canary consignee name (`SEEDED_CONSIGNEE`).

**How the data flows (export mode):**
1. The agent ships each JSON log line; `json_parser` has copied its fields into attributes and **left the original line in the body**.
2. The gateway's logs pipeline: `memory_limiter` → `k8s_attributes` → `resource` → **`attributes/pii`** (deletes the `ship_to`/`consignee_name` attributes) → **`transform/pii`** (redacts both values inside the body) → fan-out.
3. Fan-out: `otlp_http/loki` (in-cluster) **and** `splunk_hec/cobalt`. Both receive the same redacted record, which is why parity is exact and the canary is gone from both.
4. `splunk_hec/cobalt` puts records in a **file-backed queue** (`file_storage` on an emptyDir, sized in records). Consumers batch and POST to HEC; on failure they retry forever (`max_elapsed_time: 0`) while the queue holds the backlog. If the queue fills, new records are **dropped** (`block_on_overflow: false`), deliberately, so a customer sink can never stall the Loki path.
5. At the site: the POST goes to `HTTPS_PROXY` as a CONNECT to `hec.cobalt.example:8089`. The proxy terminates TLS with a certificate signed by the **Cobalt TLS Inspection CA** (trusted via `tls.ca_file`), inspects it, and opens its own TLS to the real HEC (which it verifies against the Splunk server CA). Everything in-cluster bypasses the proxy through `NO_PROXY`.
6. Helm layering: base values ← Cobalt profile ← site additions. **Maps merge** (the exporter keeps its queue and token when the site file changes its endpoint and TLS). **Lists replace** (`extraEnvs`, `extraVolumes`, the pipeline's processors and exporters are restated each time).

**Commands run, in order:**

| Command | What it does | Key output |
|---|---|---|
| `helm template … -f gateway -f export-splunk` + `otelcol-contrib validate` | Checks the merge | Only the logs pipeline changed; receivers inherited; validate exit 0 (with the queue dir present) |
| §6 sequence: snapshot → Secret → `helm install customer-sim` → `helm upgrade otel-gateway … -f export-splunk-values.yaml` → `diff` | The spec's gate | **empty diff** (exit 0) (`docs/evidence/p04/m7-gate-diff.txt`) |
| k6 with `SEEDED_CONSIGNEE`, search sink and Loki | §7 PII test on the spec's overlay | **leak: 53/178 sink batches, 63 Loki lines** |
| Local Collector 0.161 with the rendered `transform/pii` | Offline test of the fix | body redacted, 0 fragments of a quoted canary |
| Upgrade, fresh sink, new quoted canary | §7 PII test after the fix | **0 fragments** in sink (181 batches) and Loki; 601 lines `[REDACTED]` (`m7-pii.txt`) |
| 3-min outage probe | Sizing check | +184 batches/min vs capacity 1000 → overflow at ~5.4 min |
| `bash tests/sink-outage.sh` (30 min, 10-min outage) | §7 parity and outage | see Verification (`m7-sink-outage.txt`) |
| `bash deploy/observability/proxy-sim/install.sh`; overlay without, then with, the CA | Proxy/CA | x509 reproduced; then 171 POST 200/min via the proxy (`m7-proxy.txt`) |
| `helm rollback otel-gateway 2` + `diff` | §6 rollback | Beacon-only exporters; apps untouched (`m7-rollback.txt`) |

**Verification:**
- *Spec gate 1:* `diff before.txt -` is **empty** after the overlay, after the PII fix, and after 5 export revisions plus the rollback. **PASS.**
- *Spec gate 2 / §7 parity (30-min k6, 10 req/s, customer-sim at 0 for 10 min):* sent to Loki **36,034**, to Splunk **36,034** (received 36,027 in the window; counter extrapolation). The spec's query with corrected names: 33,193 = 33,193 over the last 30 min. **PASS (< 0.1%).**
- *§7 outage:* 0 send failures, **0 enqueue failures**, 0 gateway restarts; the queue peaked at **11,776** records and **drained in 50 s**. **PASS (< 5 min).**
- *§7 PII:* seeded canary: **0** fragments in the sink and in Loki with `transform/pii`. **PASS** after fixing a real leak in the spec's overlay.
- *Proxy/CA:* without the CA, `x509: certificate signed by unknown authority` (the §12 failure) with the matching proxy-side log; with it, exports flow through the proxy (audit trail) and nothing in-cluster does.
- *Northstar:* renders and validates on 0.161.0 (no Datadog account; labelled render-only).

**What broke and how we fixed it:**
1. *The spec's PII control leaked.* `attributes/pii` removes attributes, but the JSON body still carried both values: 53 of 178 sink batches held the canary. **The config looked right; only a seeded canary proved it wrong.** Fix: `transform/pii` with an escaped-quote-safe regex, tested offline first, then end to end (D-27).
2. *The spec's queue would lose data in the outage it's meant to survive.* The default is 1000 *batches*; the probe measured 184/min at 10 req/s, so it's full after about 5.4 minutes. Fix: size in records (200k) for the 100 req/s target; keep `block_on_overflow: false` so Loki never stalls (D-29).
3. *`--set replicaCount=0` doesn't scale the upstream chart to 0* (`if … (.Values.replicaCount)`: 0 is falsy). Same trap as our M5 library-chart bug; used `kubectl scale` 0 → 1 on the simulator (D-28).
4. *The inspector sidecar's image wasn't on the node* (`ErrImagePull`): side-loaded, and added to the M7 list.
5. *The spec's `NO_PROXY` silently routed traces through the proxy* (`tempo.monitoring` matches neither `.svc` nor `.cluster.local`, and gRPC honours `HTTPS_PROXY`). Visible **only** in the proxy's log. Fix: namespace suffixes + CIDRs (D-31).
6. *mitmproxy logged nothing*: Python buffers stdout without a TTY. `PYTHONUNBUFFERED=1` produced the audit trail.
7. *The export retry is logged at INFO*, so my warn/error filter missed the x509 cause. The runbook now greps `Exporting failed`.
8. *Fixing the CA lost the queued data.* The rollout replaced the pods, and the emptyDir queue (3,866 records) went with them. Measured and recorded; **recommendation: StatefulSet + PVC before any customer go-live** (D-32).
9. *The Datadog exporter probed EC2 IMDS during `validate`.* An explicit `hostname` removed one of two probes; one remains (likely the connector). Open item for Northstar's network team.

**Lab vs customer environment:** at Cobalt the only things that change are values: the real HEC endpoint and index, the token in their secret store (External Secrets, P05), their proxy address, their CA bundle, and their `NO_PROXY` (ask for the service and pod CIDRs up front). The CAB reviews `export-splunk-values.yaml` + `export-splunk-proxy-values.yaml` and the rendered diff, never code. Their SOC will ask for: the PII canary evidence (not the config), the ingest volume per day (Splunk bills per GB; our lab rate is ~20 records/s ≈ 1.7M records/day before any filtering), what happens during their maintenance windows (the queue: 200k records ≈ 2.8 h at 20/s, ≈ 17 min at the 100 req/s target), and the proxy audit trail. Northstar is the same shape with `export-datadog-values.yaml`, a real key in their secret store, and a decision on the remaining IMDS probe.

**Check yourself:**
1. The spec's overlay has an `attributes/pii` processor that deletes `consignee_name`. Why did the canary still reach Splunk, and why wouldn't a config review have caught it?
2. The persistent queue survived a 10-minute outage with zero loss, yet lost 3,866 records later that hour. What was different, and what's the production fix?
3. Why is `block_on_overflow: false` the right choice here, even though it means dropping data when the queue is full?

<details><summary>answers</summary>

1. The agent's `json_parser` copies each JSON field into an attribute but leaves the **original line in the body**. `attributes/pii` deleted the attribute copies while the body, the part Splunk actually indexes and displays, still held `"consignee_name":"…"`. A reviewer sees a processor that "deletes consignee_name" and approves it. Only sending a known canary through the real pipeline and searching the sink shows what leaves the cluster, which is why §7 specifies a seeded search, not a config check.
2. During the outage no pod was replaced, so the file-backed queue on the pod's emptyDir kept everything and drained when the sink returned. Fixing the CA needed a **config change, i.e. a rollout**: new gateway pods got new, empty emptyDirs, and the old pods' queues went with them. Production fix: run the gateway as a StatefulSet with a PVC per replica (stable identity, same volume after a rollout); operationally, let the queue drain before rolling out whenever the cause allows.
3. The logs pipeline fans out to Loki *and* Splunk from one consumer. If the Splunk exporter blocked when full, it would push back through the pipeline, stall the Loki export and then the receivers: a customer's sink outage would take down Beacon's own observability. Non-blocking keeps the in-cluster path healthy; the queue is sized so a 10-minute outage fits, and `TelemetryQueueFilling` pages well before it's full.
</details>
