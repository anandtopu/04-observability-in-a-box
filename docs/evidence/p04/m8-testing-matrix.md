# P04 testing matrix (spec §7 + NFRs), measured

Tier A: kind, 1 node, cloud VM with 4 vCPU / 15 GB. App: P04-lite (orders in Go, inventory in Python,
one Postgres). Load: an in-cluster k6 Job through the orders Service. The spec's 100 req/s was reached
(99.9–100.0 req/s achieved). Every value below was measured on 2026-09-28; the evidence file is named per
row. "Adapted" marks a test run differently from the spec, with the reason.

## §7 testing matrix

| Test | How (as run) | Pass threshold | Measured | Result |
|---|---|---|---|---|
| Config | `otelcol validate` (contrib 0.161.0) on rendered gateway/agent/Cobalt/Northstar configs; `promtool check rules` + 2 `promtool test rules` suites on the Sloth output and pipeline alerts | Zero errors; no deprecated component names | 0 errors; snake_case names only (`otlp_grpc`, `otlp_http`, `file_log`, `k8s_attributes`); exporter `sending_queue.batch`, no `batch` processor. **Not in CI**: run locally (no CI in this repo) | **PASS** (local, not CI) — `m4-alert-tests.txt`, `m6-rule-tests.txt`, `m7-*` |
| Correlation | `tests/m8-correlation.py`: 20 slowest exemplars of the orders latency histogram → Tempo trace → Loki by `trace_id` | 20/20 resolve to a trace with ≥ 1 log line | **20/20**; every trace 7–9 spans across both services, 2–3 log lines each | **PASS** — `m8-correlation.txt` |
| Fast burn | `FAULT_5XX_RATE=0.5` | Page in < 5 min | Page firing after **60 s**, email after **90 s** | **PASS** — `m6-burn-tests.txt` |
| Slow burn | `FAULT_5XX_RATE=0.001`; spec: for 2 h | No page | Live: **0 pages in 80 checks over 20 min**; promtool: **no page over 9 h** of simulated 0.1% (adapted, D-26: a 2 h live run would have blocked every other load test) | **PASS** (adapted) — `m6-burn-tests.txt`, `m6-rule-tests.txt` |
| Export parity and outage | `tests/sink-outage.sh`: 30-min k6 (10 req/s), customer-sim scaled to 0 for 10 min | Counts within 0.1%; queue drains in < 5 min | Loki exporter **36,034** = Splunk exporter **36,034**; 0 enqueue failures; peak **11,776** records queued, drained in **50 s** | **PASS** (at 10 req/s, not 100) — `m7-sink-outage.txt` |
| Gateway chaos | `tests/m8-matrix.sh chaos 100 20`: delete the oldest gateway pod every 2 min for 20 min at 100 req/s | k6 `http_req_failed` unchanged; trace gaps < 1% | Run 2: **9 pods deleted**, `http_req_failed` **0.00%** (baseline 0.00%), **119,971 spans for 119,971 requests (0.000% gap)**, p99 47 ms. Run 1 was invalid: Tempo, not the gateway, was killed mid-run (D-35), 5.94% gap | **PASS** (run 2) — `m8-chaos.txt` |
| Cardinality | Active series at 100 req/s | < 50,000 | **22,393 live** series (sample in last 5 min); TSDB head **47,321** after the chaos run (churn: 18 gateway pods, many rollouts, each minting new series until head compaction) | **PASS**, but churn uses 94% of the budget in the head — `m8-chaos.txt` |
| PII | Seeded consignee name (`SEEDED_CONSIGNEE`) searched in Loki and in the sink | Zero hits | **0** fragments in the sink after the `transform/pii` fix (the spec's overlay alone leaked it in **53 of 178** records, D-27) | **PASS** after a spec fix — `m7-pii.txt` |
| Game day (spec M8) | Inventory fault at 100 req/s; time alert → exemplar → trace → logs; two people who didn't build the stack, each < 2 min | Page 332 s after `DB_POOL_MAX=2` (+30 ms hold, D-36); blind run: page 110 s after a random fault. Participant 2 (a fresh agent, not a human): logs in **52 s** but from a pre-incident exemplar, wrong diagnosis. Participant 1 (the owner, remote, relayed): right path in 4 steps, one scroll from the answer, **did not finish**; 3 VM reclaims during the run | **NOT MET** (adapted; see `m8-gameday.txt`). Step 4 friction fixed afterwards: "Logs for this span" on the failing span now returns the one failure line (D-38, `m8-step4-fix.txt`) |

## NFRs (spec §2)

| NFR | Target | Measured | Result |
|---|---|---|---|
| SDK CPU overhead at 100 req/s, sample ratio **1.0** (the chart's lab default) | < 5% | orders (Go) **+16.1%**, inventory (Python) **+37.8%** (on vs `OTEL_SDK_DISABLED=true`, 10 min each, cAdvisor) | **FAIL** |
| SDK CPU overhead at 100 req/s, sample ratio **0.1** (the chart's documented setting for 100 req/s) | < 5% | orders (Go) **+4.2%**, inventory (Python) **+16.7%** | Go **PASS**, Python **FAIL** |
| Gateway `memory_limiter` | 80% of a 1 Gi limit | `limit_percentage: 80`, `spike_limit_percentage: 25`, limit 1Gi (rendered config) | **PASS** (config) |
| Freshness: metrics | < 30 s | **4.4 s** at 100 req/s (10.2 s in a second sample; M4 idle 1.4–10.9 s) | **PASS** — `m8-freshness.txt` |
| Freshness: Loki | < 15 s | **0.9 s** at 100 req/s (0.7 s; M4 idle 1.1 s) | **PASS** |
| Freshness: traces (no NFR) | — | complete two-service trace **1.0 s** at 100 req/s (M4 idle 4.8–5.3 s: Python's span batcher waits 5 s when idle, fills in < 1 s under load) | — |
| Freshness: customer sink | < 60 s | **1.0 / 0.8 / 0.8 s** (Cobalt overlay applied, 3 orders timed from POST to the record in customer-sim's file, then rolled back to Beacon-only, verified) | **PASS** — `m8-sink-freshness.txt` |
| Durability | No log loss across a 10-min sink outage; gateway ×2 + PDB | 0 lost (above); 2 replicas + PDB `minAvailable: 1`; but a **rollout** during a sink problem lost 3,866 queued records (emptyDir, D-32) | **PASS** (outage) with a known gap (rollout) |
| Cardinality | < 50,000; no order/customer/trace IDs as labels | 22,393 live / 47,321 head; label audit clean (IDs only in exemplars, log bodies and structured metadata) | **PASS** |
| Retention | 72 h per signal | **12 h** in the lab (declared in M0: disk and RAM) | adapted |

## Why the Python SDK fails the overhead budget (and what I'd propose)

At ratio 0.1, 90% of requests produce no recorded span, yet inventory still costs +16.7% CPU. What remains
doesn't depend on sampling. For every request the metrics SDK records `http.server.request.duration` and
the psycopg/ASGI instrumentation histograms (with attribute sets and exemplar reservoirs). The
instrumentors still create non-recording spans and context objects. The log formatter looks up the
current span for `trace_id`. In CPython all of this runs on the request's own event loop. Go pays for the
same work in compiled code.

Options, cheapest first: drop metric instruments nobody queries (a View, as orders does for
`server.address`); raise the export interval back towards 60 s for low-value metrics; measure on
production CPUs (a shared-VM lab exaggerates small differences, n = 1 run per arm); or agree the budget
per runtime (≤ 5% Go, ≤ 15% Python) with the customer. Not done here: it's a product decision, and the
number should be known before anyone makes it.
