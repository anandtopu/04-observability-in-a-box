# P04 Observability-in-a-Box: interview notes

From spec §11, rewritten around what this build actually measured (kind, 1 node, 4 vCPU / 15 GB cloud VM,
P04-lite: orders in Go, inventory in Python, one Postgres). Every number below is from `docs/evidence/p04/`;
where the lab differs from the spec's story, the difference is said out loud: that is the interview.

## 2-minute pitch

"Every customer mandates a different backend, so I made the destination configuration. Two services in two
languages (the lab stand-in for Freightline's four in three) send only OTLP to a Collector gateway, and a
node agent lifts trace IDs out of stdout JSON. By default everything lands in-cluster, in Prometheus with
exemplars, Tempo and Loki, so one click goes from a latency spike to the trace to its logs: 20 of 20
exemplars resolved to a trace with its log lines. SLOs are Sloth specs generating multi-window burn-rate
alerts; a 50% error burst paged in 60 seconds, a steady 0.1% never paged. For a composite bank whose SOC
mandated Splunk, export mode was a Helm overlay: a HEC exporter behind a persistent queue, PII stripped.
No application pod restarted, both exporters counted 36,034 records, and a 10-minute sink outage lost
nothing: 11,776 records queued and drained in 50 seconds. The load test also found where it didn't hold:
the Python SDK costs 17% CPU at 100 req/s, over our 5% budget, and I can tell you why."

## 10-minute demo flow

| Min | Show | Where |
|---|---|---|
| 1 | Diagram and ADR-P04-1: one OTLP gateway owns every destination | `docs/ARCHITECTURE.md`, spec §3 |
| 2 | RED p99 panel → exemplar → trace → "Logs for this span", live | Grafana *Freightline / RED*; `docs/evidence/p04/m5-*.png` |
| 1 | `kps-values.yaml`: OTLP receiver, promoted attributes incl. `freightline_pod_template_hash` (why P03 needs it) | `deploy/observability/kps-values.yaml` |
| 1.5 | Sloth spec → 34 generated rules; detection time ≈ 60 × 14.4 / burn minutes | `deploy/observability/slo/`, `tests/slo-burn.test.yaml` |
| 1.5 | Fast-burn injection (`FAULT_5XX_RATE=0.5`): page lands in Mailpit | `tests/burn-tests.sh`, `m6-burn-tests.txt` |
| 2 | Export overlay: the empty `diff` of app pods, the parity query | `export-splunk-values.yaml`, `m7-gate-diff.txt`, `m7-sink-outage.txt` |
| 1 | Sink outage and queue drain; the game day; trade-offs | `m7-sink-outage.txt`, `m8-gameday.txt` |

## Likely questions (strong-answer outlines, with this build's evidence)

1. **"Why a gateway, not the vendor's agent?"** One build, one place for PII rules, queues and cardinality;
   a customer backend becomes a values overlay (M7: `diff` of app pods empty across 5 export revisions).
   Concede the cost: the gateway is now tier 1. We run 2 replicas with a PDB and alert on its queues; M8
   deleted a gateway pod every 2 minutes for 20 minutes at 100 req/s with 0 failed requests and 0 of
   119,971 spans lost, because the Collector drains its queues on SIGTERM and the SDKs retry onto the
   other replica. (A PDB doesn't cover `kubectl delete` or a node crash; replicas do.)
2. **"How do you stop cardinality blow-ups?"** Named promoted attributes only, no order/customer/trace IDs
   as labels, an SDK View dropping `server.address` (clients could mint series with the Host header), and
   series counted under load: 22,393 live series at 100 req/s, budget 50k. The honest part: the TSDB head
   reached 47,321, because every new pod mints new series (the instance ID is the pod UID) and 18 gateway
   pods came and went in the chaos test. Churn, not traffic, is what eats the budget.
3. **"Why 250 ms when the requirement said 300?"** The histogram's bucket boundaries: 250 ms is a boundary,
   300 ms isn't, so "within 300 ms" would be interpolated inside the 250–500 bucket and could be off by
   most of that bucket. Native histograms (stable in Prometheus 3) fix it; they're an extension here.
4. **"The customer's proxy breaks TLS?"** Mount their CA as `tls.ca_file`, set `NO_PROXY`, never skip
   verification. M7 reproduced `x509: certificate signed by unknown authority` through a real
   TLS-inspecting proxy and fixed it with the CA. Two lessons from doing it: the spec's
   `NO_PROXY=.svc,.cluster.local` silently sent our own Tempo traffic through the proxy (short names
   match neither suffix; gRPC honours `HTTPS_PROXY`), and the rollout that applied the CA fix lost 3,866
   queued records because the queue was on an emptyDir: StatefulSet + PVC before go-live.
5. **"Splunk for traces too?"** Whoever operates it decides; the gateway keeps the choice reversible.
   Logs are what their SOC needs; traces into Splunk cost licence volume for a tool their engineers won't
   use for latency work.

## Numbers to quote (measured)

| What | Measured | Target | Evidence |
|---|---|---|---|
| Fault → page (game day, 100 req/s) | 332 s (pool 2 + 30 ms hold); 110 s (blind fault, 120 ms slow query) | page < 5 min | `m8-gameday.txt` |
| Alert → exemplar → trace → logs (game day) | run 1: fresh agent 52 s but the wrong incident; owner right path in 4 steps, not finished. Rerun after the span-log fix: fresh agent **~42 s, right cause**; owner stopped at step 2. Rerun 2 (+ 5xx panel): agent **~56 s, right cause** via the failing span's own log line | < 2 min per person | `m8-gameday.txt` (**not met** as written: two humans) |
| Freshness, customer sink | 0.8–1.0 s | < 60 s | `m8-sink-freshness.txt` |
| Active series at 100 req/s | 22,393 live (head 47,321 with churn) | < 50,000 | `m8-chaos.txt` |
| Export parity (Loki vs Splunk exporter) | 36,034 = 36,034 | within 0.1% | `m7-sink-outage.txt` |
| Queue drain after a 10-min sink outage | 50 s, 0 lost (11,776 queued) | < 5 min | `m7-sink-outage.txt` |
| SDK CPU overhead, 100 req/s, sample ratio 0.1 | Go +4.2%, Python +16.7% | < 5% | `m8-overhead.txt` |
| SDK CPU overhead, sample ratio 1.0 | Go +16.1%, Python +37.8% | < 5% | `m8-overhead.txt` |
| Freshness at 100 req/s | Loki 0.9 s, trace 1.0 s, metrics 4.4 s | 15 s / – / 30 s | `m8-freshness.txt` |
| Fast burn (50% errors) → page | 60 s (email 90 s) | < 5 min | `m6-burn-tests.txt` |
| Exemplar → trace → logs | 20/20 | 20/20 | `m8-correlation.txt` |

## What I'd do differently

- **Fix probe filtering and instance IDs before the first dashboard**, as the spec says: every early rate
  and SLO number was wrong until `service.instance.id` came from the pod UID and probes were filtered.
- **Load-test at the real rate before sizing anything.** Tempo's 1 GiB limit (my M3 sizing) held at
  10 req/s and was killed at 100 req/s during compaction; the SDK overhead NFR passed for Go and failed
  for Python only once measured at 100 req/s. Both would have surfaced in week one.
- **Put a canary through the real export path before reviewing config.** The spec's PII processor looked
  right and leaked the consignee name in the log body (53 of 178 records): only a seeded search showed it.
- **Book the customer's network team early**: proxy, CA and `NO_PROXY` were the long pole, and the
  persistent queue must be on a PVC before anyone touches config during an incident.
- **Run the game day with people in the room, on a stable host.** The lab's cloud VM was reclaimed 3 times
  during the blind run, a restart lost Tempo's last minutes of traces, and a chat relay can't time a
  2-minute gate. What it did show: the *path* works (the owner reached the right logs in 4 steps), and the
  traps are real. Pick exemplars inside the burn window (the agent took the slowest of 30 minutes, which
  predated the incident). An unresolved page swallows the next incident's email (Alertmanager dedup,
  12 h repeat). Right after a Prometheus restart, "no alerts" doesn't mean clean SLO windows.
- **Log a failure in the span that failed.** The game day's owner reached the right span and clicked its logs, but the
  failure had been logged in the parent's context, so only trace-level logs existed and the answer was one scroll
  away. Logging inside the client span plus `filterBySpanID` turned it into a one-line result (D-38).
- **Make the game-day fault realistic up front**: a pool of 2 alone didn't hurt P04-lite (its query holds
  a connection for a few ms); exhaustion needs a small pool *and* a slow query (D-36).
