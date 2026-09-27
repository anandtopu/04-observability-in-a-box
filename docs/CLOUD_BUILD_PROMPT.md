# P04 Cloud Build Prompt (Claude Code on the web)

> Paste the fenced block below as the first message of a **Claude Code cloud session** (claude.ai/code) opened on this repository. Everything the session needs is in this repo: the P04 spec, the P02 spec for the app, the version digest, rules (`CLAUDE.md`) and a setup script. Nothing depends on your laptop.

## Prerequisites (do these once, before the first session)

| # | Prerequisite | How | Check |
|---|---|---|---|
| 1 | This repo is on GitHub | `github.com/anandtopu/04-observability-in-a-box`, with `spec/`, `CLAUDE.md`, `scripts/`, `docs/` | Files visible on GitHub |
| 2 | Claude Code on the web can reach it | claude.ai/code → connect GitHub (install the Claude GitHub App on this repo), or `/web-setup` from the CLI | The repo appears in the picker |
| 3 | **Network access: Custom = default list + P04 hosts** | Environment settings → Network access → **Custom**, tick "Also include default list", then add: `quay.io`, `registry.k8s.io`, `ghcr.io`, `pkg-containers.githubusercontent.com`, `prometheus-community.github.io`, `open-telemetry.github.io`, `get.helm.sh`, `dl.k8s.io` | The setup script's registry check shows OK for every host |
| 4 | Setup script (recommended) | Environment settings → setup script: `bash scripts/cloud-setup.sh` (cached, so later sessions start fast) | First output ends `==> Done.` |
| 5 | P02 (Freightline) available, or accept P04-lite | P02 lives at `github.com/anandtopu/02-freightline-microservices` (public). P04 imports it in M0; if it isn't built yet, the prompt offers P04-lite | P02 has `services/` and `deploy/charts/` |
| 6 | No secrets needed | Splunk/Datadog are simulated in-cluster. An optional real Datadog trial key goes only in an environment secret, revoked the same day | none |

What the cloud VM gives you, per Anthropic's docs as of September 2026:
- a fresh Ubuntu 24.04 VM per session with Docker, Go, Node 22, Python and uv;
- about 30 GB of disk; memory-heavy jobs may be stopped;
- roughly 2-minute foreground command timeouts, with background processes allowed;
- a VM that is reclaimed when idle, so only pushed commits persist.

Because P04 adds about 5 GB of RAM on top of Freightline, the prompt measures the VM first. It then picks **Tier A (kind)**, **Tier B (Docker Compose)** or **Tier C (render-only)**; see `CLAUDE.md`.

**Session pattern:** one cloud session per 1–2 milestones. Each session ends with a push. To continue, paste the **resume prompt** at the bottom.

---

````text
You are my pairing partner and instructor, running in a Claude Code CLOUD session on this repository. We are building project P04, "Observability-in-a-Box", from my FDE learning handbook. It is Beacon's standard observability pack for the Freightline microservices:
- OTLP-only services, gateway and agent OpenTelemetry Collectors;
- Prometheus with the OTLP receiver and exemplars, Tempo, Loki and Grafana, with exemplar → trace → logs correlation;
- RED, USE and Flow dashboards as code; SLOs with multi-window multi-burn-rate alerts;
- a "customer export" overlay that ships the same telemetry to a customer-mandated Splunk or Datadog through a TLS-inspecting proxy, with PII removed and a persistent queue.
Your job is not just to make it work. You must teach me how it is set up, built, deployed and tested, step by step, so I can rebuild it alone and defend it to a customer's SOC team and in an interview.

## Read first (all in this repo)
1. CLAUDE.md: cloud facts, the extra network hosts, the runtime tiers (A kind / B compose / C render-only), where the app comes from, and safety rules. Obey it.
2. spec/P04-observability-in-a-box.md: the full P04 spec (problem, FR-1..FR-8, NFRs incl. overhead, freshness, durability and cardinality, architecture and ADRs, the tools table, M1–M8 with config and "Done when" gates, deployment with port-forwards, the testing matrix, security, extensions, interview demo, failure points).
3. spec/P02-freightline-polyglot-microservices.md: the app and its library chart.
4. spec/ground-truth-digest.md: versions and traps (Collector snake_case names and sending_queue.batch, grafana-community charts, Alloy not Grafana Agent, Jaeger v1 EOL, Opsgenie shutdown).
If the spec or digest proves wrong when you actually run something (a chart key, a Collector component name, a flag), show me the evidence, propose the fix, and record it in docs/DEVIATIONS.md. Never change it silently.

## Cloud-session realities you must design around
- Start every session with `bash scripts/cloud-setup.sh`, read its WARN lines and the registry-reachability block, and report CPU/RAM/disk. If a required host is BLOCKED, STOP and tell me exactly which to add.
- Shell commands time out after about 2 minutes. Run these in the background and poll: `kind create cluster`, `helm install --wait`, port-forwards, compose stacks, k6, the 10-minute sink-outage test and any watch.
- The VM is reclaimed when idle. Commit AND push at the end of every milestone and before every checkpoint. Treat unpushed work as lost, and recreate the runtime (cluster or compose) from the repo at the start of each session.
- Decide the runtime tier in M0 from measured free RAM and whether kind actually works. Tell me your reasoning, and record it. Keep the footprint lean: 1 replica, P02's low-RAM profile, retention reduced to 12 h (and say so).
- Report measured numbers only (SDK overhead, freshness, series count, recovery after the outage). If the VM can't reach a target such as 100 req/s, scale down and record both target and measured. Never present spec targets as results.

## Teaching protocol (every milestone, no skipping)
1. **Brief first:** 5–10 lines covering what we build, why (FR/NFR/ADR), which files, which observability concept it teaches (resource identity, OTLP receiver and promoted attributes, exemplars, structured metadata, tail vs head sampling, cardinality, burn rates, persistent queues and backpressure), and what a customer's SOC or platform team would ask.
2. **Build one file or concern at a time.** For every Collector pipeline, Helm values file, PromQL/LogQL query and dashboard, walk through what each block does to the data on its way through. Stay faithful to the spec; where it only describes something, write it and say so.
3. **Before running any command**, say what it does, why now, and the expected output. Afterwards, compare actual with expected and explain any difference.
4. **Run the milestone's "Done when" gate from the spec exactly** (or the documented Tier B/C adaptation, clearly labelled). On failure, debug out loud: hypothesis, test, observe, narrow. Use the Collector's own metrics (`otelcol_exporter_send_failed_*`, `otelcol_exporter_queue_size`, `otelcol_receiver_refused_*`), `kubectl logs`, the Prometheus targets and TSDB status pages, and Grafana Explore. Reproduce first, fix the root cause, re-run.
5. **Append to docs/BUILD_LOG.md** (template below), save evidence to docs/evidence/p04/ (query outputs, screenshots or exported panel JSON, timings), then `git add -A && git commit -m "<conventional message>" && git push`, and confirm the push.
6. **Checkpoint:** give me 3 comprehension questions (answers in `<details>`) and "what would break in production" (tied to spec section 12). Then STOP and wait for `next`. Never start the next milestone on your own.
If debugging passes ~20 minutes, pause, summarize, and ask whether to continue or simplify.

## Milestones (M0 is setup; M1–M8 follow the spec exactly)
- **M0 — Environment, tier decision, app import, base platform.**
  - Run the setup script. Report its results and the tier decision.
  - Import Freightline from P02 as a subtree under app/, or build P04-lite; ask me which.
  - Tier A: create a kind cluster from deploy/kind/cluster.yaml (node 1.36.4) and deploy Freightline in low-RAM mode. Tier B: write compose.yaml with the app services.
  Gate: the app answers `POST /v1/orders` (or the P04-lite equivalent) and `/readyz` is green on every service.
- **M1 — Instrumentation hygiene.** service.instance.id from POD_UID via the downward API (Tier B: from the container hostname), probe exclusion in Go, Python and Node, and `OTEL_METRICS_EXEMPLAR_FILTER=trace_based`. Gate: the spec's check that the rendered chart carries the instance ID for all four services (expected 4). In Tier B, also show distinct instance IDs in the Collector debug output.
- **M2 — Prometheus with the OTLP receiver.** Use kube-prometheus-stack 91.5.x with fullnameOverride kps, `--web.enable-otlp-receiver`, exemplar storage, and promoted resource attributes including freightline_pod_template_hash (needed by P03). Gate: the container args include both flags, and an OTLP metric is queryable with the promoted labels.
- **M3 — Tempo and Loki (monolithic).** Use the grafana-community charts (OCI on ghcr.io). Loki's OTLP endpoint stores trace_id and span_id as structured metadata, and service_name is indexed. Gate: tempo-0 and loki-0 are Ready (Tier B: containers healthy), and one trace and one log line are found by trace_id.
- **M4 — Gateway and agent Collectors.** The gateway is a Deployment ×2 with a PDB, memory_limiter at 80% of 1 Gi, exporter sending_queue.batch and span metrics. The agent is a DaemonSet running file_log on node logs plus k8s_attributes; in Tier B it tails compose logs. Include self-observability metrics and alerts for queue depth, send failures and refused data (FR-8). Gate: the spec's check that idle traffic reads 0 for all four jobs (the probe filter works), with the port-forwards from section 6 running in the background.
- **M5 — RED, USE and Flow dashboards as code.** Three JSON dashboards in deploy/observability/dashboards/, shipped as ConfigMaps labelled `grafana_dashboard: "1"` (Tier B: file provisioning). Flow covers P02's outbox backlog age, consumer lag, DLQ depth and the Tempo service graph. Gate: 3 dashboards loaded. Then walk me through clicking exemplar → trace → logs.
- **M6 — SLOs and burn-rate alerts.** Two 30-day SLOs for orders: availability 99.9% and latency 99% within 250 ms. Explain why 250 ms and not 300 ms (the histogram bucket boundary). Generate multi-window multi-burn-rate rules with Sloth (the spec's placeholder note: Helm must not render the Sloth file), and route page vs ticket separately in Alertmanager. Gate: the rule exists and the section 7 burn tests pass. Inject errors and latency and show which alert fires, when and why.
- **M7 — Customer export mode.** A Cobalt profile overlays the gateway release. It adds a Splunk HEC exporter (or Datadog, Northstar profile) sending to the in-cluster customer-sim Collector, removes PII with the transform/attributes processors, adds a file_storage persistent queue, and trusts a simulated TLS-inspecting proxy through a custom CA bundle. Explain how Helm merges maps and replaces lists. Gate: the spec's `diff` is empty and both log exporters report the same count. Also prove no log loss across a 10-minute customer-sim outage (NFR durability) with measured recovery time.
- **M8 — Profiles (optional) and the game day.** Profiles are optional: Alloy pyroscope.ebpf needs host PID and root, so it's lab-only and may be impossible in the cloud VM; explain, and skip if so. Game day: shrink inventory's DB pool to 2, drive load with k6, and time alert → exemplar → trace → logs. Gate: two people who didn't build the stack (I'll play one; you guide me cold) each reach the failing span's logs in under 2 minutes, with timings in docs/evidence/p04/.

Then run the spec's section 7 testing matrix as a pass/fail table with measured values, including SDK overhead, freshness per signal, active series (< 50k) and the cardinality guard. Write the runbooks from section 8, and docs/INTERVIEW_NOTES.md from section 11 (2-minute pitch, 10-minute demo flow, 5 questions, my measured numbers, what I'd do differently). Final push.

## Target layout (record any change in docs/DEVIATIONS.md)
```
app/                                   (Freightline via subtree, or P04-lite)
deploy/kind/cluster.yaml               compose.yaml (Tier B)
deploy/observability/{prometheus-values.yaml,tempo-values.yaml,loki-values.yaml,grafana-values.yaml}
deploy/observability/collector/{gateway-values.yaml,agent-values.yaml,profiles/{cobalt-splunk.yaml,northstar-datadog.yaml}}
deploy/observability/customer-sim/     deploy/observability/proxy-sim/ (TLS-inspecting proxy + CA)
deploy/observability/dashboards/{red.json,use.json,flow.json}
slo/{orders-availability.yaml,orders-latency.yaml}   (Sloth specs; generated rules committed)
alerting/alertmanager-routes.yaml
load/{steady.js,burn.js}
tests/{burn-tests.sh,sink-outage.sh,cardinality-check.sh}
docs/{BUILD_LOG.md,DEVIATIONS.md,ARCHITECTURE.md,adr/,runbooks/,evidence/p04/,INTERVIEW_NOTES.md}
```

## docs/BUILD_LOG.md template (one section per milestone)
```
## M<n> — <title>   (<date>, session <k>, tier A/B/C)
**Goal / requirement served:** FR-x, NFR-y, ADR-z
**What we built:** files + one line each
**How the data flows:** 5-10 bullets tracing a span/metric/log from service to backend through this milestone's components
**Commands run, in order:** command, what it does, key output
**Verification:** Done-when gate (or labelled adaptation), the exact command and the actual result (evidence path)
**What broke and how we fixed it:** symptom -> hypothesis -> evidence -> root cause -> fix
**Lab vs customer environment:** what changes at Cobalt (Splunk mandate, TLS inspection, no egress) or Northstar (Datadog)
**Check yourself:** 3 questions <details><summary>answers</summary>...</details>
```
Also maintain docs/ARCHITECTURE.md (the spec's ASCII diagram updated to what we built, with the signal-routing table), docs/adr/ in MADR format, and README.md (a from-zero quick start per tier, one command per code block).

## Start now
1. Read CLAUDE.md and the three spec files.
2. Run `bash scripts/cloud-setup.sh`. Report CPU/RAM/disk, tool versions and registry reachability, and list any hosts I must add.
3. Check whether P02 is usable (`git ls-remote https://github.com/anandtopu/02-freightline-microservices.git`, then look for services/ and deploy/charts/ via a shallow clone to /tmp) and recommend subtree import or P04-lite.
4. Give me a one-screen overview: the signal flow in your own words (service → OTLP → gateway → Prometheus/Tempo/Loki → Grafana; agent → Loki; overlay → customer-sim), your tier recommendation with reasons, the milestone plan with estimated sessions, and the 5 riskiest parts in a cloud VM.
Then STOP and wait for my "next".
````

---

## Resume prompt (each new cloud session)

````text
We are continuing the P04 build in this repo. Read CLAUDE.md, docs/CLOUD_BUILD_PROMPT.md (the full task and teaching protocol), docs/BUILD_LOG.md and docs/DEVIATIONS.md. Run `bash scripts/cloud-setup.sh`, then rebuild the runtime for the recorded tier from the repo: recreate the kind cluster (or compose stack) in the background, reinstall the releases in the spec's section 6 order, redeploy the app, and restart the port-forwards. Then tell me which milestone we're on, its gate, and anything inconsistent. STOP and wait for "next".
````

## Useful follow-ups

| Situation | Say |
|---|---|
| More depth | `go deeper on <thing>: show me what breaks if we remove it` |
| Trace a signal | `follow one span / one log line / one metric from the service to Grafana and show me each hop` |
| SOC practice | `play Cobalt Bank's SOC lead reviewing the Splunk export and question me` |
| A gate fails | `debug it out loud; reproduce before fixing` |
| Interview practice | `ask me the spec section 11 questions one at a time and grade me` |
| Break it on purpose | `inject the section 12 failure "<row>" and let me diagnose it` |
