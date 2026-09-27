# P04 — Observability-in-a-Box (Cobalt Bank and Northstar Retail, composite scenarios)

A learning build from the FDE Onboarding Handbook: Beacon's standard observability pack for the Freightline microservices ([P02](https://github.com/anandtopu/02-freightline-microservices)). It covers:
- OTLP-only services, with gateway and agent OpenTelemetry Collectors;
- Prometheus (OTLP receiver and exemplars), Tempo, Loki and Grafana, with correlation between them;
- dashboards and SLO burn-rate alerts as code;
- a customer-export overlay for Splunk or Datadog behind a TLS-inspecting proxy.

**Status:** M0 done (Tier A kind, P04-lite app deployed, gate 13/13). Progress: [`docs/BUILD_LOG.md`](docs/BUILD_LOG.md); departures from the spec: [`docs/DEVIATIONS.md`](docs/DEVIATIONS.md). The build is done in **Claude Code cloud sessions**, following [`docs/CLOUD_BUILD_PROMPT.md`](docs/CLOUD_BUILD_PROMPT.md).

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
bash app/build-images.sh 0.2.3
```

Create the PSA-restricted namespace:

```bash
kubectl apply -f app/deploy/namespaces.yaml
```

Fetch the library chart into the umbrella chart:

```bash
helm dependency build app/deploy/helm/freightline
```

Install the app:

```bash
helm install freightline app/deploy/helm/freightline -n freightline -f app/deploy/envs/kind/values.yaml --wait
```

Port-forward orders (and, in two more terminals, `svc/inventory 18081:8080` and `svc/mailpit 18025:8025`):

```bash
kubectl -n freightline port-forward svc/orders 18080:8080
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
