# CLAUDE.md: rules for building P04 (Observability-in-a-Box) in this repo

This repo is where **P04, Observability-in-a-Box** from the FDE Onboarding Handbook gets built, in **Claude Code cloud sessions** (claude.ai/code). The build is meant to teach, not only to produce code. Follow `docs/CLOUD_BUILD_PROMPT.md` exactly; it is the task.

## Source of truth
- `spec/P04-observability-in-a-box.md` is the P04 spec (sections 1–12, milestones M1–M8 with "Done when" gates). The spec wins over memory.
- `spec/P02-freightline-polyglot-microservices.md` describes the app being observed (Freightline) and its library chart.
- `spec/ground-truth-digest.md` lists verified versions and dates as of September 2026, plus stale-knowledge traps. For P04 these include: Grafana Agent reached EOL (use Alloy); Jaeger v1 reached EOL; the OTel Collector uses snake_case component names and `sending_queue.batch`; the Loki, Tempo and Grafana OSS charts moved to `grafana-community`; Prometheus native histograms are stable (no feature flag); OTel GenAI semconv is still experimental; Opsgenie shuts down 2027-04-05.
- `spec/sources.md` holds the external references cited by the spec.
- Relative links inside `spec/` point into the handbook repo. Ignore them.
- If a version, chart key or flag fails when you actually run it, show the evidence, propose a fix, and record it in `docs/DEVIATIONS.md`. Never change it silently.

## Where the app comes from
P04 observes Freightline, built in P02: https://github.com/anandtopu/02-freightline-microservices (public; github.com is on the default allowlist).
- Preferred: import it in M0 with `git subtree add --prefix=app https://github.com/anandtopu/02-freightline-microservices.git main --squash`, after asking me.
- If P02 isn't finished (no services or charts yet), ask me before building **P04-lite**. P04-lite is a small instrumented stand-in inside this repo: `orders` (Go) and `inventory` (Python) with the same OTLP env contract, one Postgres, and a k6 driver. Every P04 gate still applies to the services that exist. Record this in DEVIATIONS.

## Cloud environment facts (Anthropic docs, as of September 2026)
- A fresh Ubuntu 24.04 x86_64 VM per session with Python + uv, Node 22, Go, Docker, and Postgres/Redis (not running). About 30 GB disk. Memory-heavy jobs may be stopped.
- Foreground shell commands time out after about 2 minutes. Run cluster creation, `helm install --wait`, port-forwards, compose stacks, k6 and any watch in the background, and poll their logs or status.
- The VM is reclaimed when idle, and **only pushed commits survive**. Commit and push at the end of every milestone and before every checkpoint.
- The network is the **Trusted** allowlist (PyPI, npm, GitHub, Docker Hub, and cloud SDKs by default). P04 also needs the hosts below. If `scripts/cloud-setup.sh` reports one as BLOCKED, STOP and ask me to add it (Environment settings → Network access → Custom, with "include default list" ticked):
  `quay.io` (Prometheus and operator images) · `registry.k8s.io` (kube-state-metrics and kind helpers) · `ghcr.io` + `pkg-containers.githubusercontent.com` (grafana-community OCI charts) · `prometheus-community.github.io` and `open-telemetry.github.io` (chart repos) · `get.helm.sh` (Helm binary) · `dl.k8s.io` (kubectl).
- Run `bash scripts/cloud-setup.sh` at the start of every session. It is idempotent and reports CPU/RAM/disk and registry reachability.

## Runtime tiers (decide in M0, record in BUILD_LOG and DEVIATIONS)
- **Tier A — kind (preferred, matches the spec).** Docker works and `kind create cluster` succeeds. Use a single node (or 2 if RAM allows), P02's low-RAM profile, 1 replica each, and 72 h retention reduced to 12 h. The full spec topology applies: gateway plus agent Collectors, Prometheus with the OTLP receiver, Tempo, Loki, Grafana, Sloth rules and Alertmanager.
- **Tier B — Docker Compose (fallback if kind fails or RAM is under ~8 GB available).** The same components as containers, with the same Collector pipelines and configs. Freightline services, or P04-lite, run as compose services with the same OTLP env. The agent Collector tails the compose containers' JSON logs instead of the node logs. Kubernetes-only pieces (downward API, DaemonSet, the Helm library-chart change, PDBs) are still written. They are validated with `helm template` + `kubeconform`, and their gates are adapted and marked "adapted" in BUILD_LOG.
- **Tier C — render-only (last resort, no containers at all).** Everything is written and validated statically (`helm template`, `kubeconform`, `promtool check rules`, `otelcol validate` via the binary, dashboard JSON lint), and the runtime gates are recorded as "not run". Never claim a runtime gate passed in Tier C.

## Safety rules (non-negotiable)
- Never kill processes by name. Stop only processes or containers you started, by PID or name.
- Never run `docker system prune` or `volume prune`. Delete only this project's kind cluster or compose project, and only when I say so.
- No real customer or vendor credentials. Splunk and Datadog are simulated by the in-cluster `customer-sim` Collector. If I choose to try a real Datadog trial, the key goes only in a cloud-environment secret, never in the repo, and I revoke it the same day.
- No order, customer or trace IDs as metric labels (the cardinality budget is < 50k series), and no PII in logs sent to the customer overlay.
- No force-push, no history rewrite, no PRs or repo-settings changes unless I ask.

## Working style
- Teaching protocol: brief → build one file at a time and explain it → explain each command and its expected output → run the "Done when" gate → log in `docs/BUILD_LOG.md` → commit + push → checkpoint quiz → STOP and wait for "next".
- Conventional commits: `feat(m2): prometheus otlp receiver with promoted attributes`, `feat(m6): sloth SLOs and burn-rate alerts`.
