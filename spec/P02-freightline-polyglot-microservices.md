## P02 — Freightline Polyglot Microservices

| Field | Value |
|---|---|
| ID | P02 |
| Tier | **T1 Beginner** (P02 lite: M1-M2, about 11 h, no Kafka; see the [T1 on-ramp](README.md#4-dependency-graph-and-build-orders)) → **T2 Intermediate** (M3-M9) → **T3 Advanced** |
| Time estimate | 50-70 hours |
| Industry framing | Meridian Freight (fictional) order-to-cash, packaged as the reference application Beacon's FDE team deploys into every later environment |
| Required categories covered | Production-grade microservices |
| Languages | Go 1.27 (orders), Python 3.14 (inventory), TypeScript 7.0 on Node.js 24 LTS (billing, notifications), SQL, Protobuf |
| Cloud(s) | None. It runs on kind. P05-P08 move it to AWS, Azure and GCP |
| Estimated cost / keeping it near $0 | $0. Budget about 10 GB of RAM (kind, Kafka, four Postgres, four services, gateway). To cut it, run one replica per service and Redpanda in dev mode; `docker stop freightline-control-plane` when idle |
| Prerequisites | [C01](../02-curriculum/C01-python-mastery.md) T2, [C02](../02-curriculum/C02-go-mastery.md) T2, [C03](../02-curriculum/C03-typescript-mastery.md) T2, [C04](../02-curriculum/C04-systems-design-and-distributed-systems.md) T2, [C06](../02-curriculum/C06-databases-and-storage.md) T2, [C07](../02-curriculum/C07-api-design-and-integration.md) T2, [C09](../02-curriculum/C09-containers-and-kubernetes.md) T2; P01 recommended |

### 1. Problem statement

**Business context (composite scenario).** Meridian Freight invoices from a nightly batch: the AS/400 hands orders to a 2011 .NET billing application that issues invoices the next morning, so credit holds are a day stale. Twice last quarter a customer over its limit received a full truckload, and a month-end billing report once locked the shared orders table for 40 minutes during peak picking. Meridian wants an event-driven order-to-cash slice proven before funding wider modernization (P11).

**Constraints.**
- **Team ownership.** The data team owns inventory (Python), finance systems owns billing and notifications (TypeScript), and the platform team prefers Go. Each service owns its database and no service reads another's tables; the month-end lock is why.
- **Deployment reality.** It must install on a customer cluster with no runtime internet access (P16, P19): no remote config fetches or plugin downloads at start-up.
- **Operations.** Warehouses run 24x7, so dependency failures must degrade, not cascade.
- **Telemetry.** OpenTelemetry-native, because each customer mandates a different backend (P04).

**Stakeholders.** Meridian's VP Finance (invoice timeliness), the warehouse operations director (stock accuracy), Meridian's platform team (runs the cluster), Beacon's FDE lead and Beacon product management (wants the app reusable).

**Measurable success criteria.**
1. From order placed to invoice issued, p95 < 5 s. Today it takes until the next morning.
2. Across 1,000 orders placed while a random pod is killed every 30 s, zero orders are lost and zero invoices are duplicated.
3. `POST /v1/orders` p99 < 300 ms at 100 req/s.
4. If inventory, billing or Kafka is down for 60 s, reads return no 5xx, and writes either succeed or return `503` with `Retry-After` within 1 s.
5. `helm install` on a fresh kind cluster reaches all-ready in under 10 minutes.

### 2. Requirements

**Functional requirements**
- **FR-1** `POST /v1/orders` requires an `Idempotency-Key` (the P01 pattern), creates a `PENDING` order and returns `202` with `Location`.
- **FR-2** `GET /v1/orders/{id}` returns the order. Transitions: `PENDING → CONFIRMED | REJECTED`, `CONFIRMED → INVOICED | CANCELLED`.
- **FR-3** On `orders.order-placed.v1`, inventory reserves every line or none and emits `stock-reserved` or `stock-rejected`. It serves `GET /v1/stock/{sku}`.
- **FR-4** Orders runs a soft pre-check, `InventoryService.CheckAvailability`, with a 300 ms deadline; on timeout it accepts and the saga decides.
- **FR-5** On `orders.order-confirmed.v1`, billing issues an invoice and emits `billing.invoice-issued.v1`. It serves `GET /v1/invoices/{id}` and the `BillingService.GetInvoice` RPC.
- **FR-6** Notifications sends an email (Mailpit in the lab) and a signed webhook (the P01 signer) for confirmed, rejected and invoiced orders, calling `GetInvoice` to render the email.
- **FR-7** Every state change and its event commit atomically through a transactional outbox; every consumer dedupes through an inbox keyed on event ID.
- **FR-8** After 5 failed attempts a poison message goes to `dlq.<service>.v1`, with the error and original topic, partition and offset in headers.
- **FR-9** Every service exposes `/healthz` (liveness) and `/readyz` (readiness) and shuts down within 25 s of `SIGTERM`.
- **FR-10** W3C trace context flows across HTTP, RPC and Kafka.

**Non-functional requirements**

| Attribute | Target |
|---|---|
| Latency | `POST /v1/orders` p99 < 300 ms; `GET` p99 < 100 ms at 100 req/s |
| Throughput | 100 orders/s sustained for 30 min on a laptop kind cluster |
| Event lag | Outbox commit to consumer handled, p99 < 2 s |
| Availability | Order API 99.9% monthly (the SLO in P04) |
| RPO / RTO | RPO 0 for committed orders (synchronous commit; in the lab this depends on one PVC, so say so); RTO 5 min for pod or node loss |
| Shutdown | Zero failed requests during a rolling restart under load (proved in P03) |
| Cost | $0 locally; each service fits in 256 Mi requests |

**Constraints.** No shared database. Images are non-root with a read-only root filesystem. All configuration comes from env vars or mounted files. No runtime internet egress.

**Out of scope.** Payments, end-user authentication (P23 adds it at the edge), multi-region (P08), a schema registry (an extension), and any UI beyond Mailpit.

### 3. Architecture

```text
                    CLIENTS (Meridian apps, k6)          ZONE: edge (namespace envoy-gateway-system)
                              |  HTTPS / REST                  +-------------------------------------+
                              v                                | Envoy Gateway 1.9 (Gateway API 1.6) |
                    +--------------------+                     | Gateway "freightline" :80/:443      |
                    |  HTTPRoutes        |<--------------------+ timeouts, retries (GET only), CB    |
                    +--+--------+-----+--+                     +-------------------------------------+
   /v1/orders*  -------+        |     +------- /v1/invoices*
                       |  /v1/stock*  |
 ===== TRUST BOUNDARY: namespace freightline (default-deny NetworkPolicy, PSA "restricted") =========
                       v        v     v
  +----------------+  gRPC  +------------------+     +------------------+ Connect +-----------------+
  | orders  (Go)   |------->| inventory (Py)   |     | billing (TS)     |<--------| notifications   |
  | :8080 REST     | pre-   | :8080 REST       |     | :8080 REST       | GetInv. | (TS) :8080      |
  | :50051 RPC     | check  | :50051 gRPC      |     | :50051 RPC       |         | SMTP -> Mailpit |
  | outbox relay   | 300 ms | outbox relay     |     | outbox relay     |         | webhook signer  |
  +---+--------^---+        +---+---------^----+     +---+----------^---+         +---+---------^---+
  +---v----+   |            +---v------+  |          +---v-----+    |             +---v-----+   |
  |orders- |   |            |inventory-|  |          |billing- |    |             |notif-db |   |
  |db PG18 |   |            |db PG18   |  |          |db PG18  |    |             |PG18     |   |
  +---+----+   |            +---+------+  |          +---+-----+    |             +---------+   |
      | outbox |                | outbox  |              | outbox   |  (inbox tables everywhere) |
      v        |                v         |              v          |                            |
 ===== ZONE: data plane (namespace freightline-data) ===============================================
  +---------------------------------------------------------------------------------------------+
  | Apache Kafka 4.3.1 (KRaft, single node in lab; 3 brokers + RF3 in prod)  :9092              |
  |  orders.order-placed.v1  orders.order-confirmed.v1  orders.order-rejected.v1                |
  |  orders.order-cancelled.v1  inventory.stock-reserved.v1  inventory.stock-rejected.v1        |
  |  billing.invoice-issued.v1   dlq.{orders,inventory,billing,notifications}.v1                |
  +---------------------------------------------------------------------------------------------+
  All services --OTLP gRPC :4317--> otel-gateway.observability (P04)   stdout JSON logs --> agent
```

**Reference contract.** Later projects depend on these names; change them only with a version bump.

| Service | Language | REST + health | RPC (h2c) | Database | Publishes | Consumes (group ID = service name) |
|---|---|---|---|---|---|---|
| `orders` | Go 1.27 | 8080 | 50051 `OrderService` (Connect + gRPC); pprof on `127.0.0.1:6060` | `orders-db` / `orders` | `orders.order-placed.v1`, `orders.order-confirmed.v1`, `orders.order-rejected.v1`, `orders.order-cancelled.v1` | `inventory.stock-reserved.v1`, `inventory.stock-rejected.v1`, `billing.invoice-issued.v1` |
| `inventory` | Python 3.14 | 8080 | 50051 `InventoryService` (gRPC); headless Service `inventory-headless` for client-side balancing | `inventory-db` / `inventory` | `inventory.stock-reserved.v1`, `inventory.stock-rejected.v1` | `orders.order-placed.v1`, `orders.order-cancelled.v1` |
| `billing` | TS 7 / Node 24 | 8080 | 50051 `BillingService` (Connect + gRPC) | `billing-db` / `billing` | `billing.invoice-issued.v1` | `orders.order-confirmed.v1` |
| `notifications` | TS 7 / Node 24 | 8080 | none | `notifications-db` / `notifications` | none | `orders.order-confirmed.v1`, `orders.order-rejected.v1`, `billing.invoice-issued.v1` |
| `kafka` | Apache Kafka 4.3.1 | 9092 client, 9093 controller | | | | |
| `mailpit` | Mailpit 1.31 | 1025 SMTP, 8025 UI | | | | |

**Topics.** Every event is keyed by `order_id`, so all events for one order land on one partition in order. Lab: 6 partitions, RF 1. Production: 12 partitions, RF 3, `min.insync.replicas=2`. Retention is 7 days, except 30 days for `billing.invoice-issued.v1` and the DLQs. Each value is a CloudEvents 1.0 structured JSON envelope, with `traceparent` carried as a Kafka header:

```json
{
  "specversion": "1.0",
  "id": "01926f3e-8b1a-7c3d-9e2f-4a5b6c7d8e9f",
  "source": "freightline/orders",
  "type": "freightline.orders.order-placed.v1",
  "subject": "ord_01926f3e8b1a",
  "time": "2026-09-24T14:03:11.412Z",
  "datacontenttype": "application/json",
  "data": { "order_id": "ord_01926f3e8b1a", "customer_id": "C-100", "lines": [{ "sku": "SKU-7", "quantity": 2 }], "total_cents": 18400 }
}
```

The `id` is the outbox row's `uuidv7()`. Consumers deduplicate on it.

**Repository layout.**

```text
freightline/
├── proto/freightline/{orders,inventory,billing}/v1/*.proto   # buf-managed, generated code committed
├── buf.yaml  buf.gen.yaml
├── contracts/openapi/{orders,inventory,billing}.yaml         # external REST, OpenAPI 3.1
├── contracts/events/*.schema.json                            # JSON Schema per event type
├── services/orders/          # Go: cmd/orders, internal/{api,rpc,store,outbox,consumer}, db/migrations
├── services/inventory/       # Python: src/inventory/{api,rpc,consumer,outbox}, db/migrations, pyproject.toml, uv.lock
├── services/billing/         # TS: src/{main.ts,invoices.ts,gen/}, db/migrations, package.json, pnpm-lock.yaml
├── services/notifications/   # TS: same shape as billing
├── deploy/helm/freightline-service/   # library chart: Deployment/Rollout, Services, PDB, NetworkPolicy
├── deploy/helm/freightline/           # umbrella chart: four services, Kafka, Postgres, Mailpit, topic Job
├── deploy/kind/kind-config.yaml
├── deploy/envs/{kind,customer-*}/values*.yaml   # P03 GitOps promotes digests here
├── tests/{contract,e2e,chaos,load}/
└── docs/{adr,runbooks}/
```

| Component | Responsibility | Technology | Why | Alternative considered |
|---|---|---|---|---|
| Edge gateway | TLS, routing, timeouts, GET retries | Envoy Gateway 1.9 | Ingress-NGINX was retired 2026-03-24; Gateway API is the default | Istio or Cilium gateway |
| `orders` | Order aggregate, saga owner | Go, pgx v5, connect-go, franz-go | Hot path; lowest latency and memory | Python |
| `inventory` | Stock and reservations | Python, FastAPI, psycopg 3, aiokafka, grpcio | The data team's language | Go (takes ownership away) |
| `billing`, `notifications` | Invoices, communications | TS, Fastify 5, connect-es 2, `@confluentinc/kafka-javascript` | Finance team's language; KafkaJS has had no release since 2023 | NestJS (heavier) |
| Event bus | Durable ordered events | Apache Kafka 4.3.1, KRaft | The Kafka API is what customers run (MSK, Event Hubs, Confluent) | Redpanda 26.2 (dev profile) |
| Databases | One per service | PostgreSQL 18.6 | `uuidv7()` time-ordered event IDs | One shared cluster (month-end coupling) |
| Outbox relays | Publish committed events | In-process poller + advisory lock | No extra infrastructure | Debezium 3.6 CDC (P10) |

**Mini-ADRs**

| # | Decision | Options | Choice | Consequences |
|---|---|---|---|---|
| ADR-P02-1 | How state changes and events stay consistent | Dual write (DB then Kafka); Kafka transactions; transactional outbox | Outbox table in each service's database, relayed by a poller | Nothing is lost on a crash. Delivery is at-least-once, so every consumer needs an inbox. Adds 5-50 ms of publish latency |
| ADR-P02-2 | Outbox relay topology | Many relays with `SKIP LOCKED`; one relay per service via `pg_try_advisory_xact_lock`; Debezium | One active relay per service (advisory lock), `SKIP LOCKED` as a guard | Per-key ordering holds; throughput is bounded by one relay (about 2k events/s in the lab), which is enough |
| ADR-P02-3 | Internal protocol | REST/JSON; gRPC; Connect | Protobuf over Connect and gRPC on port 50051 (h2c) | One schema, generated clients in three languages, `buf breaking` in CI. HTTP/2 pinning needs `max_connection_age` |
| ADR-P02-4 | Saga style | Orchestrated; choreographed | Choreography, with orders owning order status | No workflow engine; the state machine lives in one table and every event is documented in `contracts/events/` |

### 4. Tools & technologies

| Tool | Version / status (as of September 2026) | Notes |
|---|---|---|
| Go | 1.27.1 (1.26 supported; older unsupported) | Container-aware GOMAXPROCS since 1.25: drop `automaxprocs` |
| TypeScript / Node.js | TS 7.0 (Go-native `tsc`) / Node 24 LTS | No compiler API until TS 7.1 (keep TS 6 for typescript-eslint); Node 26 becomes LTS 2026-10-28 |
| pnpm | 11.x | 1-day `minimumReleaseAge` default; list the Kafka client's native build in `allowBuilds` |
| connect-go / connect-es / grpcio / buf | 1.21.x / 2.2.x / 1.84.x / 1.73.x | connect-es 2 needs only `protoc-gen-es` |
| franz-go / aiokafka / `@confluentinc/kafka-javascript` | 1.22.x / 0.14.x / 1.10.x | One producing service per topic (partitioners differ) |
| Apache Kafka | 4.3.1 (KRaft only; share groups production-ready since 4.2) | Confluent is IBM-owned (closed 2026-03-17) |
| PostgreSQL / dbmate | 18.6 / 2.36.0 | PG 19 is still beta. dbmate: plain-SQL migrations for three languages |
| Envoy Gateway | 1.9.1 (Gateway API v1.6.1; tested on Kubernetes 1.33-1.36) | Why the kind node is pinned to 1.36, not 1.37 |
| kind / Helm | 0.33.0 (default node v1.37.0) / 4.3.x | Pin node images by digest. Helm 4 uses server-side apply; Helm 3 security fixes end 2027-02-10 (extended from 2026-11-11) |

### 5. Step-by-step implementation plan

**M1 — Contracts first (5 h).** Write the protos, the three OpenAPI files and one JSON Schema per event before any service code. Commit the generated code, because air-gapped builds (P16, P19) cannot reach the Buf Schema Registry.

```proto
// proto/freightline/inventory/v1/inventory.proto
syntax = "proto3";

package freightline.inventory.v1;

option go_package = "example.com/freightline/gen/go/freightline/inventory/v1;inventoryv1";

service InventoryService {
  // Soft pre-check. Never reserves; the saga decides.
  rpc CheckAvailability(CheckAvailabilityRequest) returns (CheckAvailabilityResponse);
}

message Line {
  string sku = 1;
  int32 quantity = 2;
}

message CheckAvailabilityRequest {
  repeated Line lines = 1;
}

message CheckAvailabilityResponse {
  bool all_available = 1;
  repeated string short_skus = 2;
}
```

*Done when* lint passes and there are no breaking changes against `main`:

```bash
buf lint
```

```bash
buf breaking --against '.git#branch=main'
```

**M2 — `orders` skeleton with real shutdown semantics (6 h).** Get readiness, graceful shutdown and h2c right before business logic; every later project relies on them.

```go
// services/orders/cmd/orders/main.go (lifecycle only)
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	pool, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		log.Error("db pool", "err", err)
		os.Exit(1)
	}
	var ready atomic.Bool
	mux := http.NewServeMux()
	registerAPI(mux, pool) // POST /v1/orders, GET /v1/orders/{id}
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		if !ready.Load() || pool.Ping(r.Context()) != nil {
			http.Error(w, "not ready", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})

	var h2c http.Protocols
	h2c.SetHTTP1(true)
	h2c.SetUnencryptedHTTP2(true) // net/http h2c (API since Go 1.24): gRPC/Connect over cleartext HTTP/2
	servers := []*http.Server{
		{Addr: ":8080", Handler: otelhttp.NewHandler(mux, "orders"), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 60 * time.Second},
		{Addr: ":50051", Handler: rpcHandler(pool), Protocols: &h2c, ReadHeaderTimeout: 5 * time.Second},
	}
	for _, s := range servers {
		go func() {
			if err := s.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
				log.Error("listen", "addr", s.Addr, "err", err)
				stop()
			}
		}()
	}
	ready.Store(true)

	<-ctx.Done() // SIGTERM arrives after the preStop sleep (M8)
	ready.Store(false)
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	for _, s := range servers {
		_ = s.Shutdown(shutdownCtx) // stop accepting, finish in-flight, GOAWAY on HTTP/2
	}
	pool.Close()
	log.Info("shutdown complete")
}
```

*Done when* `kubectl delete pod` during a 50 req/s loop logs `shutdown complete` in under 25 s with no failed requests (P03 turns this into a formal k6 gate).

**M3 — Transactional outbox in `orders` (6 h).** The order row and its event commit in one transaction; the relay publishes afterwards.

```sql
-- services/orders/db/migrations/20260901000002_outbox.sql
-- migrate:up
CREATE TABLE outbox (
  id           uuid        PRIMARY KEY DEFAULT uuidv7(),
  topic        text        NOT NULL,
  msg_key      text        NOT NULL,
  payload      jsonb       NOT NULL,
  traceparent  text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  published_at timestamptz
);
CREATE INDEX outbox_unpublished ON outbox (id) WHERE published_at IS NULL;

-- migrate:down
DROP TABLE outbox;
```

```go
// services/orders/internal/outbox/relay.go (one publish cycle)
func (r *Relay) publishBatch(ctx context.Context) (int, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op after Commit

	var leader bool // one active relay per service keeps per-key order (ADR-P02-2)
	if err := tx.QueryRow(ctx, `SELECT pg_try_advisory_xact_lock(hashtext('orders-outbox'))`).Scan(&leader); err != nil || !leader {
		return 0, err
	}
	rows, err := tx.Query(ctx, `SELECT id::text, topic, msg_key, payload, coalesce(traceparent, '')
		FROM outbox WHERE published_at IS NULL ORDER BY id LIMIT 200 FOR UPDATE SKIP LOCKED`)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	var ids []string
	var recs []*kgo.Record
	for rows.Next() {
		var id, topic, key, tp string
		var payload []byte
		if err := rows.Scan(&id, &topic, &key, &payload, &tp); err != nil {
			return 0, err
		}
		rec := &kgo.Record{Topic: topic, Key: []byte(key), Value: payload,
			Headers: []kgo.RecordHeader{{Key: "content-type", Value: []byte("application/cloudevents+json")}}}
		if tp != "" { // context captured at write time, not relay time (M7)
			rec.Headers = append(rec.Headers, kgo.RecordHeader{Key: "traceparent", Value: []byte(tp)})
		}
		ids, recs = append(ids, id), append(recs, rec)
	}
	if err := rows.Err(); err != nil || len(recs) == 0 {
		return 0, err
	}
	if err := r.kafka.ProduceSync(ctx, recs...).FirstErr(); err != nil {
		return 0, err // rollback: rows stay unpublished and are retried (at-least-once)
	}
	if _, err := tx.Exec(ctx, `UPDATE outbox SET published_at = now() WHERE id = ANY($1::text[]::uuid[])`, ids); err != nil {
		return 0, err
	}
	return len(ids), tx.Commit(ctx)
}
```

franz-go's producer is idempotent with `acks=all` by default. A crash between produce and commit re-publishes the batch (inboxes absorb it); a nightly job deletes published rows older than 3 days.

*Done when* killing the orders pod mid-load leaves the unpublished count draining to 0 within 5 s of restart (expected: `0`):

```bash
kubectl -n freightline exec orders-db-0 -- psql -U orders -d orders -tAc "SELECT count(*) FROM outbox WHERE published_at IS NULL"
```

**M4 — `inventory` consumer with an inbox and all-or-nothing reservations (6 h).**

```python
# services/inventory/src/inventory/consumer.py
import json

from aiokafka import AIOKafkaConsumer
from opentelemetry import propagate, trace
from psycopg.types.json import Jsonb

from inventory.events import build_event  # CloudEvents envelope helper

tracer = trace.get_tracer("inventory.consumer")


class OutOfStock(Exception): ...


async def run(pool, bootstrap: str) -> None:
    consumer = AIOKafkaConsumer(
        "orders.order-placed.v1", "orders.order-cancelled.v1",
        bootstrap_servers=bootstrap, group_id="inventory",
        enable_auto_commit=False, auto_offset_reset="earliest",
    )
    await consumer.start()
    try:
        async for msg in consumer:
            carrier = {k: v.decode() for k, v in (msg.headers or [])}
            with tracer.start_as_current_span(
                f"process {msg.topic}", context=propagate.extract(carrier), kind=trace.SpanKind.CONSUMER
            ):
                await handle(pool, json.loads(msg.value))
            await consumer.commit()  # only after the DB transaction committed
    finally:
        await consumer.stop()


async def handle(pool, event: dict) -> None:
    async with pool.connection() as conn, conn.transaction():
        cur = await conn.execute("INSERT INTO inbox (event_id) VALUES (%s) ON CONFLICT DO NOTHING", (event["id"],))
        if cur.rowcount == 0:
            return  # duplicate delivery, already handled
        order = event["data"]
        ok = await reserve_all(conn, order["order_id"], order["lines"])
        topic = "inventory.stock-reserved.v1" if ok else "inventory.stock-rejected.v1"
        headers: dict[str, str] = {}
        propagate.inject(headers)
        await conn.execute(
            "INSERT INTO outbox (topic, msg_key, payload, traceparent) VALUES (%s, %s, %s, %s)",
            (topic, order["order_id"], Jsonb(build_event(topic, order)), headers.get("traceparent")),
        )


async def reserve_all(conn, order_id: str, lines: list[dict]) -> bool:
    try:
        async with conn.transaction():  # SAVEPOINT: all lines or none
            for line in lines:
                cur = await conn.execute(
                    """UPDATE stock SET reserved = reserved + %(q)s
                       WHERE sku = %(sku)s AND on_hand - reserved >= %(q)s""",
                    {"q": line["quantity"], "sku": line["sku"]},
                )
                if cur.rowcount != 1:
                    raise OutOfStock(line["sku"])
                await conn.execute(
                    "INSERT INTO reservations (order_id, sku, quantity) VALUES (%s, %s, %s)",
                    (order_id, line["sku"], line["quantity"]),
                )
        return True
    except OutOfStock:
        return False
```

The conditional `UPDATE ... WHERE on_hand - reserved >= q` is the oversell guard: an atomic single-row check, no `SERIALIZABLE` needed. On the fifth failure of a `(partition, offset)`, produce the raw message to `dlq.inventory.v1` with `x-error` and `x-original-*` headers, then commit. Serve the pre-check from `grpc.aio.server(options=[("grpc.max_connection_age_ms", 30000), ("grpc.max_connection_age_grace_ms", 5000)])` so HTTP/2 clients reconnect and spread across pods.

*Done when* replaying the same `order-placed` event 10 times yields one reservation, and an order for 3 units of a SKU with 2 on hand yields `stock-rejected` with no partial reservation. Both cases are integration tests against real Postgres and Kafka (expected: `2 passed`):

```bash
uv run --directory services/inventory pytest tests/integration -q -k "duplicate_replay or partial_reservation"
```

**M5 — `billing` and `notifications` in TypeScript (7 h).** Both run as compiled ESM on Node 24. `tsconfig.json` uses `"module": "nodenext"`, `"target": "es2025"`, `"strict": true`, `"verbatimModuleSyntax": true` and `"erasableSyntaxOnly": true`. `baseUrl` and `moduleResolution: node` are errors in TS 7.

```ts
// services/billing/src/main.ts
import http2 from "node:http2";
import Fastify from "fastify";
import pg from "pg";
import kafka from "@confluentinc/kafka-javascript";
import { Code, ConnectError } from "@connectrpc/connect";
import { connectNodeAdapter } from "@connectrpc/connect-node";
import { BillingService } from "./gen/freightline/billing/v1/billing_pb.js";
import { handleOrderConfirmed, loadInvoice } from "./invoices.js";

const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 10 });
const app = Fastify({ logger: true });
let ready = false;

app.get("/healthz", async () => ({ status: "ok" }));
app.get("/readyz", async (_req, reply) => {
  if (!ready) return reply.code(503).send({ status: "draining" });
  await pool.query("SELECT 1");
  return { status: "ready" };
});
// GET /v1/invoices/:id is registered the same way, returning Problem Details on 404

const rpc = http2.createServer(
  connectNodeAdapter({
    routes: (router) =>
      router.service(BillingService, {
        async getInvoice(req) {
          const invoice = await loadInvoice(pool, req.invoiceId);
          if (!invoice) throw new ConnectError("invoice not found", Code.NotFound);
          return invoice;
        },
      }),
  }),
);

const broker = process.env.KAFKA_BOOTSTRAP ?? "kafka.freightline-data:9092";
const consumer = new kafka.KafkaJS.Kafka({ kafkaJS: { brokers: [broker] } }).consumer({
  kafkaJS: { groupId: "billing", fromBeginning: true },
});

await app.listen({ host: "0.0.0.0", port: 8080 });
rpc.listen(50051);
await consumer.connect();
await consumer.subscribe({ topics: ["orders.order-confirmed.v1"] });
await consumer.run({ eachMessage: async ({ message }) => handleOrderConfirmed(pool, message) });
ready = true;

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.once(signal, async () => {
    ready = false;
    await consumer.disconnect(); // leave the group after in-flight eachMessage completes
    await app.close(); // stop accepting, drain in-flight HTTP
    rpc.close(); // GOAWAY to HTTP/2 clients
    await pool.end();
    process.exit(0);
  });
}
```

`handleOrderConfirmed` runs the same inbox, write and outbox transaction as M4, with `UNIQUE (order_id)` on `invoices` as a second duplicate guard. Notifications has the same shape; it calls `GetInvoice` with a 500 ms deadline and, if billing is slow, sends the email without the invoice link and records an enrichment retry.

*Done when* one order produces exactly one invoice row, one Mailpit email and one signed webhook, and the email lists the invoice number.

**M6 — Timeouts, retries and bulkheads on every edge (4 h).** Write this table into `docs/adr/` and enforce it in code and gateway policy:

| Edge | Timeout | Retries | Bulkhead | Fallback |
|---|---|---|---|---|
| Gateway → `GET` routes | 1 s | 2 on connect-failure/reset, 50-500 ms backoff | Envoy circuit breaker defaults | `503` |
| Gateway → `POST /v1/orders` | 2 s | 0 at the gateway (the client retries with the same `Idempotency-Key`) | same | `503` with `Retry-After: 1` |
| orders → inventory pre-check | 300 ms | 0 | 32 in-flight | Accept the order; the saga decides |
| notifications → billing `GetInvoice` | 500 ms | 2, full jitter, retry budget 10% | 16 in-flight | Email without invoice link, enrich later |
| Service → Postgres | `statement_timeout=2s`, pool acquire 500 ms | 0 | Pool of 10 | `503` |
| Relay → Kafka | 30 s delivery timeout | Client-internal, idempotent | One relay | Rows stay in the outbox |
| Consumer handler | 10 s | 5 attempts with backoff | One message per partition at a time | DLQ |

In Go the bulkhead is a buffered channel of 32: a non-blocking `select` send either takes a slot or increments `precheck_skipped` and accepts the order; the call runs under `context.WithTimeout(ctx, 300*time.Millisecond)`, and errors count as `precheck_degraded`. The client is `inventoryv1connect.NewInventoryServiceClient(&http.Client{Transport: &http.Transport{Protocols: h2cOnly}}, "http://inventory:50051", connect.WithGRPC())`, where `h2cOnly` is a `*http.Protocols` with only `SetUnencryptedHTTP2(true)`.

*Done when* scaling inventory to zero keeps `POST /v1/orders` p99 under 400 ms and `precheck_degraded` climbing, with no 5xx.

**M7 — OpenTelemetry end to end (4 h).** Every service gets the same environment, set by the chart:

| Variable | Value |
|---|---|
| `OTEL_SERVICE_NAME` | `orders`, `inventory`, `billing` or `notifications` |
| `OTEL_RESOURCE_ATTRIBUTES` | `service.namespace=freightline,deployment.environment.name=kind,service.version=<image tag>` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-gateway.observability:4317` (until P04 exists, a `grafana/otel-lgtm` pod) |
| `OTEL_SEMCONV_STABILITY_OPT_IN` | `http,database`, so Python and Node emit the same stable metric names as Go |
| `OTEL_TRACES_SAMPLER` / `_ARG` | `parentbased_traceidratio` / `1.0` in the lab, `0.1` at 100 req/s sustained |

Go uses the SDK with `otelhttp`, `otelconnect` and `otelpgx`; Python uses `opentelemetry-instrument`; Node starts with `node --import @opentelemetry/auto-instrumentations-node/register dist/main.js`. The subtle part is Kafka: the relay publishes later, in another goroutine, so capture `traceparent` when you insert the outbox row (M3) and extract it from record headers in consumers (M4); in Go, implement `propagation.TextMapCarrier` over `kgo.Record.Headers` or use franz-go's `plugin/kotel`. Log JSON to stdout with `trace_id` and `span_id` on every line.

*Done when* one trace shows `POST /v1/orders` → outbox relay publish → inventory consume → orders consume → billing consume → notifications `GetInvoice`, with no broken parent links.

**M8 — Helm library chart and umbrella chart on kind (8 h).** One library chart renders every service identically; P03 depends on these lifecycle settings.

```yaml
# deploy/helm/freightline-service/templates/_deployment.tpl (excerpt)
{{- define "freightline-service.podSpec" -}}
terminationGracePeriodSeconds: 40
securityContext:
  runAsNonRoot: true
  seccompProfile: { type: RuntimeDefault }
containers:
  - name: app
    image: "{{ .Values.image.repository }}{{ if .Values.image.digest }}@{{ .Values.image.digest }}{{ else }}:{{ .Values.image.tag }}{{ end }}"
    ports:
      - { name: http, containerPort: 8080 }
      - { name: rpc, containerPort: 50051 }
    envFrom:
      - secretRef: { name: {{ .Values.name }}-db }
    startupProbe:
      httpGet: { path: /healthz, port: http }
      periodSeconds: 2
      failureThreshold: 30
    readinessProbe:
      httpGet: { path: /readyz, port: http }
      periodSeconds: 2
      failureThreshold: 2
    livenessProbe:
      httpGet: { path: /healthz, port: http }
      periodSeconds: 10
      failureThreshold: 3
    lifecycle:
      preStop:
        sleep: { seconds: 10 }   # native sleep action: works in distroless images with no /bin/sleep
    resources:
      requests: { cpu: {{ .Values.resources.cpu }}, memory: {{ .Values.resources.memory }} }
      limits: { memory: {{ .Values.resources.memory }} }
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: { drop: [ALL] }
    volumeMounts:
      - { name: tmp, mountPath: /tmp }
volumes:
  - name: tmp
    emptyDir: {}
{{- end }}
```

Liveness checks only the process, never the database, or a Postgres blip restarts every pod. The umbrella chart also renders a PDB (`maxUnavailable: 1`) per service, a default-deny NetworkPolicy with explicit allows, `app.kubernetes.io/name` and `app.kubernetes.io/part-of: freightline` labels, and a post-install Job running `kafka-topics.sh --create --if-not-exists` for every contract topic, with broker `auto.create.topics.enable=false` so a typo never creates a 1-partition topic. Skip Bitnami's Kafka and PostgreSQL charts (the free images moved to unmaintained `bitnamilegacy`): render StatefulSets on digest-pinned `apache/kafka:4.3.1` and `postgres:18.6`, or use CloudNativePG if the customer runs it.

*Done when* `helm lint` passes and the rendered output passes a server-side dry run once the `freightline` and `freightline-data` namespaces exist (expected: every object ends in `(server dry run)`):

```bash
helm template freightline deploy/helm/freightline -n freightline -f deploy/envs/kind/values.yaml | kubectl apply --dry-run=server -f -
```

**M9 — End-to-end and failure-injection proof (4 h).** Place 1,000 orders with k6 while `tests/chaos/kill-loop.sh` deletes one random pod labeled `app.kubernetes.io/part-of=freightline` every 30 s for 10 minutes (`kubectl delete --wait=false`), then reconcile: the first query must return 1,000 and the second zero rows:

```sql
-- run against billing-db
SELECT count(*) FROM invoices;
SELECT order_id, count(*) FROM invoices GROUP BY order_id HAVING count(*) > 1;
```

*Done when* all five success criteria in section 1 are met, with evidence saved in `docs/evidence/p02/`.

### 6. Deployment instructions

Save the cluster config. The node is pinned to Kubernetes 1.36.4 by digest because Envoy Gateway 1.9 is tested on 1.33-1.36:

```yaml
# deploy/kind/kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: freightline
nodes:
  - role: control-plane
    image: kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed
```

Create the cluster:

```bash
kind create cluster --config deploy/kind/kind-config.yaml
```

Install Envoy Gateway, which also installs the Gateway API CRDs:

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.1 -n envoy-gateway-system --create-namespace
```

```bash
kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
```

Build the four images (`freightline-orders:dev` and the rest) and load them into the node:

```bash
make images TAG=dev
```

```bash
kind load docker-image freightline-orders:dev freightline-inventory:dev freightline-billing:dev freightline-notifications:dev --name freightline
```

Install the umbrella chart (namespaces, Postgres, Kafka, the topics Job, services, Gateway and HTTPRoutes):

```bash
helm dependency build deploy/helm/freightline
```

```bash
helm install freightline deploy/helm/freightline -n freightline --create-namespace -f deploy/envs/kind/values.yaml --wait --timeout 10m
```

Verify every pod is ready and the Gateway is `Programmed`:

```bash
kubectl get pods -A -l app.kubernetes.io/part-of=freightline
```

```bash
kubectl get gateway,httproute -n freightline
```

Reach the gateway from your laptop:

```bash
export ENVOY_SERVICE=$(kubectl get svc -n envoy-gateway-system --selector=gateway.envoyproxy.io/owning-gateway-namespace=freightline,gateway.envoyproxy.io/owning-gateway-name=freightline -o jsonpath='{.items[0].metadata.name}')
```

```bash
kubectl -n envoy-gateway-system port-forward service/${ENVOY_SERVICE} 8088:80
```

In a second terminal, place an order; expect `202` and a `Location` to poll until `status` is `INVOICED`, usually within 2 s:

```bash
curl -si -X POST localhost:8088/v1/orders -H "Content-Type: application/json" -H "Idempotency-Key: first-order-000001" -d '{"customer_id":"C-100","lines":[{"sku":"SKU-7","quantity":2}]}'
```

**Rollback** one Helm revision, then confirm with `helm history`:

```bash
helm rollback freightline -n freightline
```

**Teardown.**

```bash
kind delete cluster --name freightline
```

### 7. Testing & validation

| Layer | What | Tool | Pass threshold |
|---|---|---|---|
| Unit | State machine, reservation SQL, invoice numbering, carrier | `go test -race`, pytest 9, `node --test` | 100% pass; race detector clean |
| Contract | Protos, REST vs OpenAPI, events vs JSON Schema | `buf breaking`, Schemathesis, schema tests | Zero breaking changes or failures |
| Integration | Each service with real Postgres and Kafka | Compose profile `it` | Inbox dedupe proved by duplicate injection |
| End to end | Order → invoice → email on kind | pytest e2e | p95 order-to-invoice < 5 s over 200 orders |
| Load | 100 orders/s for 30 min | k6 v2.3 | `POST` p99 < 300 ms; `http_req_failed` < 0.1% |
| Chaos | Kill loop; Kafka down 60 s; inventory at 0 | kubectl | No lost or duplicate invoices; reads never 5xx; outbox drains < 30 s |
| Security | Dependency and image scans; non-root, read-only | `govulncheck`, `pip-audit`, `pnpm audit`, Grype | No known exploited vulnerabilities; PSA `restricted` dry-run passes |

### 8. Observability & operations

Beyond the automatic RED metrics, add:

| Signal | Source | Alert |
|---|---|---|
| Outbox backlog age (`now() - min(created_at)` for unpublished rows) | Each relay, as a gauge | > 30 s for 5 min → page: events are not flowing |
| Consumer lag per group | Kafka exporter or client metrics | > 5,000 messages or rising for 10 min → ticket |
| DLQ depth | Kafka exporter | Any message in `dlq.*` → ticket with the `x-error` header |
| Pre-check degraded rate | `orders` counter | > 20% for 10 min → ticket: inventory is slow |
| Saga stuck | `orders` query: `PENDING` older than 60 s | > 0 → page |

Runbook: **Orders stuck in `PENDING`.** (1) A growing outbox backlog in orders-db means the relay or Kafka. (2) Otherwise check `inventory` consumer lag. (3) If lag is zero, find the order in `dlq.inventory.v1`. (4) Never hand-edit status: fix the cause and replay the DLQ message so every service sees the same events.

### 9. Security & compliance

- **Threat model highlights.** A compromised pod reaching every database (per-service NetworkPolicies and credentials); forged events (per-principal Kafka ACLs in production); oversell under concurrency (the conditional `UPDATE`); poison messages stalling a partition (the DLQ); dependency compromise (lockfiles, pnpm 11's release-age delay, `allowBuilds`, digest-pinned bases; P22 goes deeper).
- **Controls.** PSA `restricted`, non-root, read-only root filesystem, dropped capabilities, `RuntimeDefault` seccomp, DB credentials as Secrets, and no mounted service account tokens.
- **Compliance mapping.** None for Meridian; the same controls later map to PCI DSS v4.0.1 segmentation (P25) and HIPAA technical safeguards (P26): keep evidence in `docs/evidence/`.

### 10. Extensions for advanced learners

1. **T3 — Kafka share groups for notifications** (production-ready since Kafka 4.2). *Hard because* you lose per-key ordering and must prove that is fine for emails but not for status events.
2. **T3 — Schema registry and `BACKWARD` compatibility gates.** *Hard because* it touches three languages' serializers and every consumer at once.
3. **T3 — Service mesh mTLS** with Istio ambient (GA since 1.24) or Linkerd. *Hard because* HTTP/2 balancing, NetworkPolicies and the gateway all change behavior.
4. **T4 — Saga compensation with timeouts:** cancel and release stock if billing is silent for 10 minutes. *Hard because* timers must survive restarts and race correctly against late events.
5. **T4 — Tenant-aware Freightline** (`tenant_id` everywhere plus Postgres row-level security), the base for P27. *Hard because* every query, topic key, cache key and metric label must carry the tenant with bounded cardinality.

### 11. How to demonstrate it in interviews

**2-minute pitch.** "Freightline is a four-service order-to-cash system for a composite 3PL: orders in Go, inventory in Python, billing and notifications in TypeScript, mirroring how customer teams split. Each service owns its Postgres. State changes and events commit through a transactional outbox, one relay per service keeps per-order ordering, and every consumer dedupes through an inbox. Internally it's Protobuf over Connect and gRPC; externally, REST through Envoy Gateway, since ingress-nginx is retired. Every edge has an explicit timeout, retry and bulkhead. The proof: 1,000 orders while a pod died every 30 seconds, with zero lost or duplicate invoices and p95 order-to-invoice under 5 seconds."

**10-minute demo flow.**
1. Diagram and reference contract table (1.5 min).
2. Place an order and follow its single trace across four services (2 min).
3. The outbox and inbox rows for that order (1 min).
4. Scale inventory to 0: orders still accept, degraded pre-check counter rising (1.5 min).
5. Kill loop under k6, then reconciliation SQL: 1,000 invoices, zero duplicates (2.5 min).
6. A poison message in the DLQ with its headers (1 min), then trade-offs (30 s).

**Likely questions and strong-answer outlines.**
1. *"Why not Kafka transactions?"* They give Kafka-to-Kafka exactly-once, not a database write plus a publish; the outbox makes Postgres the source of truth.
2. *"How do you keep per-order ordering?"* `order_id` keys, one relay per service, sequential per-partition consumption; explain what share groups would break.
3. *"Why three languages?"* Customer team ownership, contained by one library chart, one OTel convention and one contract repo.
4. *"Kafka is down. Now what?"* Writes still commit and the outbox grows; show the backlog-age alert and the drain rate.
5. *"How does gRPC balance behind a ClusterIP?"* It doesn't: HTTP/2 pins a connection. Use `max_connection_age`, client-side balancing over the headless Service, or a mesh.

**Artifacts to bring:** diagram, contract table, ADRs, the one-trace screenshot, the kill-loop k6 summary with reconciliation output, the resilience-policy table.

**Metrics to quote:** p95 order-to-invoice, `POST` p99 at 100 req/s, lost/duplicate counts under chaos (0/0), outbox drain time after a Kafka outage, memory per pod per language.

**What you would do differently:** start with Protobuf events and a registry (retrofitting schemas across three languages is the costliest change); build the reconciliation job on day one.

### 12. Common failure points while building

| Failure | Symptom | Fix |
|---|---|---|
| gRPC connections pinned to one pod | New inventory pods idle while old ones run hot | Server `grpc.max_connection_age_ms`, or client-side balancing over `inventory-headless` |
| Broken traces across Kafka | Consumer spans start new traces | Store `traceparent` in the outbox row; extract it from headers in consumers |
| Mismatched metric names across languages | Dashboards show Go only; Python emits `http.server.duration` in ms | `OTEL_SEMCONV_STABILITY_OPT_IN=http` for Python and Node |
| Native Kafka client blocked | `pnpm install` succeeds; runtime fails with a missing binding | pnpm 11 blocks install scripts: add `@confluentinc/kafka-javascript` to `allowBuilds` |
| Consumer commits before the DB commit | A crash silently loses events | Commit offsets only after the transaction (`enable_auto_commit=False`) |
| Two languages producing to one keyed topic | One order's events land on different partitions | Native librdkafka clients (confluent-kafka-python, confluent-kafka-go) default to CRC32 `consistent_random`; franz-go, aiokafka and the JS client's KafkaJS API use Java-compatible murmur2. Set `partitioner=murmur2_random` explicitly, or keep one producer per topic |

**See also:** [Distributed systems primitives](../../05-theory/05-distributed-systems-primitives.md) and [Production reliability patterns](../../05-theory/06-production-reliability-patterns.md) (outbox, idempotency and bulkhead theory); [M08 Containers and Kubernetes](../../01-curriculum/M08-containers-and-kubernetes.md).

---

