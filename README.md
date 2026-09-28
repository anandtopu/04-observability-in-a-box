# P04 — Observability-in-a-Box (Cobalt Bank and Northstar Retail, composite scenarios)

A learning build from the FDE Onboarding Handbook: Beacon's standard observability pack for the Freightline microservices ([P02](https://github.com/anandtopu/02-freightline-microservices)). It covers:
- OTLP-only services, with gateway and agent OpenTelemetry Collectors;
- Prometheus (OTLP receiver and exemplars), Tempo, Loki and Grafana, with correlation between them;
- dashboards and SLO burn-rate alerts as code;
- a customer-export overlay for Splunk or Datadog behind a TLS-inspecting proxy.

**Status:** M0–M5 done (Tier A kind, P04-lite app, instrumentation hygiene, Prometheus with the OTLP receiver, Tempo and Loki, gateway and agent Collectors, RED/USE/Flow dashboards). Progress: [`docs/BUILD_LOG.md`](docs/BUILD_LOG.md); departures from the spec: [`docs/DEVIATIONS.md`](docs/DEVIATIONS.md). The build is done in **Claude Code cloud sessions**, following [`docs/CLOUD_BUILD_PROMPT.md`](docs/CLOUD_BUILD_PROMPT.md).

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

Build and side-load the app images:

```bash
bash app/build-images.sh 0.2.6
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

Load the dashboards (regenerate first if you edited `generate.py`):

```bash
python3 deploy/observability/dashboards/generate.py
```

```bash
kubectl apply -f deploy/observability/dashboards/
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
