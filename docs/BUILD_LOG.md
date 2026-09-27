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
