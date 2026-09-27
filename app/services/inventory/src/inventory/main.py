"""inventory: stock and reservations for P04-lite.

Run as `opentelemetry-instrument python -m inventory`: the wrapper patches FastAPI and
psycopg before this module imports them, so every request and SQL statement is a span.
"""

import asyncio
import logging
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, Response
from psycopg_pool import AsyncConnectionPool, PoolTimeout
from pydantic import BaseModel, Field

log = logging.getLogger("inventory")

# M8's game day shrinks DB_POOL_MAX to 2 to reproduce the P04 incident (exhausted pool).
pool = AsyncConnectionPool(
    os.environ.get("DATABASE_URL", ""),
    min_size=1,
    max_size=int(os.environ.get("DB_POOL_MAX", "10")),
    timeout=float(os.environ.get("DB_POOL_TIMEOUT_SECONDS", "2")),
    open=False,
)

SCHEMA = """
CREATE TABLE IF NOT EXISTS stock (
  sku     text PRIMARY KEY,
  on_hand bigint NOT NULL CHECK (on_hand >= 0)
);
CREATE TABLE IF NOT EXISTS reservations (
  order_id   uuid PRIMARY KEY,
  sku        text NOT NULL REFERENCES stock (sku),
  qty        int  NOT NULL CHECK (qty > 0),
  created_at timestamptz NOT NULL DEFAULT now()
);
-- SKU-000 never has stock, so k6 can produce REJECTED orders on purpose.
INSERT INTO stock (sku, on_hand) VALUES ('SKU-000', 0) ON CONFLICT DO NOTHING;
INSERT INTO stock (sku, on_hand)
  SELECT format('SKU-%s', lpad(i::text, 3, '0')), 1000000000 FROM generate_series(1, 50) AS i
  ON CONFLICT DO NOTHING;
"""


schema_ready = asyncio.Event()


async def migrate_until_ready() -> None:
    """Postgres may be in initdb or restarting when this pod starts. Retry instead of failing
    startup: /healthz stays green and /readyz holds traffic until the schema exists."""
    attempt = 0
    while True:
        attempt += 1
        try:
            async with pool.connection(timeout=3) as conn:
                await conn.execute(SCHEMA)
            schema_ready.set()
            log.info("database ready", extra={"attempts": attempt})
            return
        except Exception as e:
            log.warning("database not ready, retrying", extra={"attempt": attempt, "err": str(e)})
            await asyncio.sleep(min(attempt, 5))


@asynccontextmanager
async def lifespan(_: FastAPI):
    await pool.open(wait=False)  # connect in the background; never fail startup on the DB
    task = asyncio.create_task(migrate_until_ready())
    log.info("inventory started", extra={"db_pool_max": pool.max_size})
    yield
    task.cancel()
    await pool.close()
    log.info("shutdown complete")


app = FastAPI(title="inventory", lifespan=lifespan)


class Reservation(BaseModel):
    order_id: str
    sku: str
    qty: int = Field(gt=0)


class OutOfStock(Exception):
    pass


@app.post("/v1/reservations", status_code=201)
async def reserve(r: Reservation, response: Response):
    try:
        async with pool.connection() as conn, conn.transaction():
            cur = await conn.execute(
                "INSERT INTO reservations (order_id, sku, qty) VALUES (%s, %s, %s)"
                " ON CONFLICT (order_id) DO NOTHING RETURNING order_id",
                (r.order_id, r.sku, r.qty),
            )
            if await cur.fetchone() is None:  # replayed order: already reserved
                response.status_code = 200
                return {"order_id": r.order_id, "status": "RESERVED", "replay": True}
            cur = await conn.execute(
                "UPDATE stock SET on_hand = on_hand - %s WHERE sku = %s AND on_hand >= %s RETURNING on_hand",
                (r.qty, r.sku, r.qty),
            )
            if await cur.fetchone() is None:
                raise OutOfStock  # rolls back the reservation row too
    except OutOfStock:
        log.info("stock rejected", extra={"order_id": r.order_id, "sku": r.sku, "qty": r.qty})
        response.status_code = 409
        return {"order_id": r.order_id, "status": "REJECTED"}
    except PoolTimeout:
        # The failure mode behind P04's 70-minute incident: visible in the span, the log and the 503 rate.
        log.error("db pool exhausted", extra={"order_id": r.order_id, "db_pool_max": pool.max_size})
        response.status_code = 503
        response.headers["Retry-After"] = "1"
        return {"error": "database busy"}
    log.info("stock reserved", extra={"order_id": r.order_id, "sku": r.sku, "qty": r.qty})
    return {"order_id": r.order_id, "status": "RESERVED"}


@app.get("/v1/stock/{sku}")
async def stock(sku: str, response: Response):
    async with pool.connection() as conn:
        row = await (await conn.execute("SELECT on_hand FROM stock WHERE sku = %s", (sku,))).fetchone()
    if row is None:
        response.status_code = 404
        return {"error": "unknown sku"}
    return {"sku": sku, "on_hand": row[0]}


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}  # process only: a DB blip must not restart the pod


@app.get("/readyz")
async def readyz(response: Response):
    if not schema_ready.is_set():
        response.status_code = 503
        return {"status": "not ready"}
    try:
        async with pool.connection(timeout=1) as conn:
            await conn.execute("SELECT 1")
    except Exception:
        response.status_code = 503
        return {"status": "not ready"}
    return {"status": "ready"}
