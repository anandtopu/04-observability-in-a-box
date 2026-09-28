# P04 — Observability-in-a-Box (Cobalt Bank and Northstar Retail, composite scenarios)

A learning build from the FDE Onboarding Handbook: Beacon's standard observability pack for the Freightline microservices ([P02](https://github.com/anandtopu/02-freightline-microservices)). It covers:
- OTLP-only services, with gateway and agent OpenTelemetry Collectors;
- Prometheus (OTLP receiver and exemplars), Tempo, Loki and Grafana, with correlation between them;
- dashboards and SLO burn-rate alerts as code;
- a customer-export overlay for Splunk or Datadog behind a TLS-inspecting proxy.

**Status:** M0–M8 done (Tier A kind, P04-lite app, instrumentation hygiene, Prometheus with the OTLP receiver, Tempo and Loki, gateway and agent Collectors, RED/USE/Flow dashboards, Sloth SLOs with burn-rate alerts, customer export mode, load matrix, game day and its rerun, per-span trace-to-logs). Measured results: [`docs/evidence/p04/m8-testing-matrix.md`](docs/evidence/p04/m8-testing-matrix.md); interview prep: [`docs/INTERVIEW_NOTES.md`](docs/INTERVIEW_NOTES.md); runbooks: [`docs/runbooks/`](docs/runbooks/). Open items: the game-day gate as written (two humans, < 2 min) is not met (D-37, D-39); the Python SDK misses the 5% overhead budget; profiles are written but not deployed (D-33); kube-state-metrics waits on `cdn.registry.k8s.io` (D-14). Progress: [`docs/BUILD_LOG.md`](docs/BUILD_LOG.md); departures from the spec: [`docs/DEVIATIONS.md`](docs/DEVIATIONS.md). The build is done in **Claude Code cloud sessions**, following [`docs/CLOUD_BUILD_PROMPT.md`](docs/CLOUD_BUILD_PROMPT.md).

| Path | What it is |
|---|---|
| [`spec/P04-observability-in-a-box.md`](spec/P04-observability-in-a-box.md) | The P04 spec: source of truth |
| [`spec/P02-freightline-polyglot-microservices.md`](spec/P02-freightline-polyglot-microservices.md) | The app being observed |
| [`spec/ground-truth-digest.md`](spec/ground-truth-digest.md) | Verified versions and dates (Sept 2026) |
| [`spec/sources.md`](spec/sources.md) | References cited by the spec |
| [`CLAUDE.md`](CLAUDE.md) | Cloud facts, extra network hosts, runtime tiers, safety rules |
| [`scripts/cloud-setup.sh`](scripts/cloud-setup.sh) | Idempotent setup with resource and registry-reachability checks |
| [`docs/CLOUD_BUILD_PROMPT.md`](docs/CLOUD_BUILD_PROMPT.md) | Prerequisites, the kickoff prompt and the resume prompt |
| [`app/`](app/) | P04-lite: `orders` (Go), `inventory` (Python), library + umbrella chart (stand-in for P02) |
| [`deploy/kind/cluster.yaml`](deploy/kind/cluster.yaml) | The kind cluster (Tier A) |
| [`tests/`](tests/) | Milestone gates as scripts |
| [`load/`](load/) | k6 drivers |

## Quick start, Tier A (kind), from zero

Set up tools, start dockerd, and check registries:

```bash
bash scripts/cloud-setup.sh
```

Create the cluster (about 15 s; run it in the background in a cloud session):

```bash
kind create cluster --config deploy/kind/cluster.yaml
```

Side-load third-party images (the kind node cannot pull through the cloud session's proxy):

```bash
bash scripts/kind-load-images.sh
```

Build and side-load the app images (the tag must match `image.tag` in `app/deploy/helm/freightline/values.yaml`, currently 0.2.9):

```bash
bash app/build-images.sh 0.2.9
```

Create the PSA-restricted namespace:

```bash
kubectl apply -f app/deploy/namespaces.yaml
```

Install or upgrade the app (always rebuilds the library-chart dependency first):

```bash
bash app/deploy.sh
```

Port-forward orders (and, in two more terminals, `svc/inventory 18081:8080` and `svc/mailpit 18025:8025`):

```bash
kubectl -n freightline port-forward svc/orders 18080:8080
```

Install Prometheus, Alertmanager and Grafana (kube-prometheus-stack; about 30 s). Add `--set kubeStateMetrics.enabled=false` only while `cdn.registry.k8s.io` is blocked (DEVIATIONS D-14):

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
```

```bash
helm install kps prometheus-community/kube-prometheus-stack --version 91.5.1 -n monitoring --create-namespace -f deploy/observability/kps-values.yaml --wait
```

Install Tempo and Loki (grafana-community OCI charts on ghcr.io):

```bash
helm install tempo oci://ghcr.io/grafana-community/helm-charts/tempo --version 3.0.0 -n monitoring -f deploy/observability/tempo-values.yaml --wait
```

```bash
helm install loki oci://ghcr.io/grafana-community/helm-charts/loki --version 18.13.5 -n monitoring -f deploy/observability/loki-values.yaml --wait
```

Install the gateway and agent Collectors, then the pipeline alerts:

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
```

```bash
helm install otel-gateway open-telemetry/opentelemetry-collector --version 0.173.1 -n observability --create-namespace -f deploy/observability/otel-gateway-values.yaml --wait
```

```bash
helm install otel-agent open-telemetry/opentelemetry-collector --version 0.173.1 -n observability -f deploy/observability/otel-agent-values.yaml --wait
```

```bash
kubectl apply -f deploy/observability/pipeline-alerts.yaml
```

Generate and load the SLO rules (Sloth), then run the rule unit tests:

```bash
sloth generate -i deploy/observability/slo/orders.yaml -o deploy/observability/slo/generated/orders.rules.yaml
```

```bash
kubectl apply -f deploy/observability/slo/generated/
```

```bash
bash tests/promtool-rules.sh
```

Load the dashboards (regenerate first if you edited `generate.py`):

```bash
python3 deploy/observability/dashboards/generate.py
```

```bash
kubectl apply -f deploy/observability/dashboards/
```

Customer export mode (Cobalt/Splunk; see docs/BUILD_LOG.md M7): the token Secret, the stand-in sink, the overlay.

```bash
kubectl -n observability create secret generic customer-splunk-hec --from-literal=token=lab-only-token
```

```bash
helm install customer-sim open-telemetry/opentelemetry-collector --version 0.173.1 -n customer-sim --create-namespace -f deploy/observability/customer-sim-values.yaml --wait
```

```bash
helm upgrade otel-gateway open-telemetry/opentelemetry-collector --version 0.173.1 -n observability -f deploy/observability/otel-gateway-values.yaml -f deploy/observability/export-splunk-values.yaml --wait
```

Port-forward Prometheus:

```bash
kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090
```

Run the M0 gate:

```bash
bash tests/m0-smoke.sh
```

Drive steady traffic:

```bash
k6 run --no-usage-report -e RATE=20 -e DURATION=1m load/steady.js
```

Tier B (Compose) and Tier C (render-only) quick starts will be added if we ever fall back to them; this VM runs Tier A.

M8 load matrix, game day and recovery (see docs/BUILD_LOG.md M8). After the cloud VM is reclaimed, bring the lab back (dockerd, kind node, pods, port-forwards, k6) without touching Helm values:

```bash
bash scripts/recover.sh 120
```

```bash
bash tests/m8-matrix.sh overhead 100 10
```

```bash
bash tests/m8-matrix.sh chaos 100 20
```

```bash
python3 tests/m8-correlation.py 20
```

```bash
bash tests/m8-gameday.sh start 100 60
```

```bash
bash tests/m8-gameday.sh restore
```

## Tests

Unit tests (no cluster needed). orders: failed inventory calls are logged inside the `HTTP POST` client span.

```bash
cd app/services/orders && GOTOOLCHAIN=local go test ./...
```

inventory: the JSON log formatter (span IDs, levels, extra fields).

```bash
cd app/services/inventory && uv run python -m unittest discover -s tests -v
```

Alert and SLO rules (promtool in a container: 3 suites, 34 Sloth rules):

```bash
bash tests/promtool-rules.sh
```

Generated artefacts must match what is committed (both commands leave `git status` clean):

```bash
python3 deploy/observability/dashboards/generate.py
```

```bash
sloth generate -i deploy/observability/slo/orders.yaml -o deploy/observability/slo/generated/orders.rules.yaml
```

Runtime checks against the lab (port-forwards from section 6): `tests/m0-smoke.sh`, `tests/m3-correlation.sh`, `tests/m4-pipeline.sh`, `tests/burn-tests.sh`, `tests/sink-outage.sh`, `tests/m8-correlation.py`, `tests/m8-matrix.sh`, `tests/m8-sink-freshness.sh`.
