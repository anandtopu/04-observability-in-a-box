# P04 — Observability-in-a-Box (Cobalt Bank and Northstar Retail, composite scenarios)

A learning build from the FDE Onboarding Handbook: Beacon's standard observability pack for the Freightline microservices ([P02](https://github.com/anandtopu/02-freightline-microservices)). It covers:
- OTLP-only services, with gateway and agent OpenTelemetry Collectors;
- Prometheus (OTLP receiver and exemplars), Tempo, Loki and Grafana, with correlation between them;
- dashboards and SLO burn-rate alerts as code;
- a customer-export overlay for Splunk or Datadog behind a TLS-inspecting proxy.

**Status:** not built yet. The build is done in **Claude Code cloud sessions**, following [`docs/CLOUD_BUILD_PROMPT.md`](docs/CLOUD_BUILD_PROMPT.md).

| Path | What it is |
|---|---|
| [`spec/P04-observability-in-a-box.md`](spec/P04-observability-in-a-box.md) | The P04 spec: source of truth |
| [`spec/P02-freightline-polyglot-microservices.md`](spec/P02-freightline-polyglot-microservices.md) | The app being observed |
| [`spec/ground-truth-digest.md`](spec/ground-truth-digest.md) | Verified versions and dates (Sept 2026) |
| [`spec/sources.md`](spec/sources.md) | References cited by the spec |
| [`CLAUDE.md`](CLAUDE.md) | Cloud facts, extra network hosts, runtime tiers, safety rules |
| [`scripts/cloud-setup.sh`](scripts/cloud-setup.sh) | Idempotent setup with resource and registry-reachability checks |
| [`docs/CLOUD_BUILD_PROMPT.md`](docs/CLOUD_BUILD_PROMPT.md) | Prerequisites, the kickoff prompt and the resume prompt |
