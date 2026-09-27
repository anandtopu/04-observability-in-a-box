// Steady order traffic for P04-lite. Constant arrival rate: RATE requests/s whatever the
// latency, so a slow backend shows up as latency and errors, not as less traffic.
//   k6 run --no-usage-report -e BASE_URL=http://localhost:18080 -e RATE=20 -e DURATION=5m load/steady.js
// (--no-usage-report: k6 otherwise sends a usage report to stats.grafana.org; the session proxy
//  blocked it, and a customer's SOC would ask why a lab tool calls out.)
// The spec's target is 100 req/s; the cloud VM may not reach it through a port-forward.
// Record the rate you actually ran next to the target (never report the target as a result).
import http from "k6/http";
import { check } from "k6";

const BASE_URL = __ENV.BASE_URL || "http://localhost:18080";

export const options = {
  scenarios: {
    steady: {
      executor: "constant-arrival-rate",
      rate: Number(__ENV.RATE || 20),
      timeUnit: "1s",
      duration: __ENV.DURATION || "1m",
      preAllocatedVUs: 20,
      maxVUs: 200,
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],
    "http_req_duration{name:POST /v1/orders}": ["p(99)<300"], // P02's latency NFR
  },
};

// Synthetic PII only. M7 seeds a known consignee name and proves it never reaches the customer sink.
const CONSIGNEES = ["Avery Lab", "Jordan Sample", "Riley Placeholder", "Casey Fixture"];
const SEEDED = __ENV.SEEDED_CONSIGNEE; // e.g. "Zephyrine Q. Testperson" in M7

export default function () {
  const sku = Math.random() < 0.01 ? "SKU-000" : `SKU-${String(1 + Math.floor(Math.random() * 50)).padStart(3, "0")}`;
  const consignee = SEEDED && Math.random() < 0.1 ? SEEDED : CONSIGNEES[Math.floor(Math.random() * CONSIGNEES.length)];
  const res = http.post(
    `${BASE_URL}/v1/orders`,
    JSON.stringify({ sku, qty: 1, ship_to: `${1 + Math.floor(Math.random() * 999)} Lab Street`, consignee_name: consignee }),
    {
      headers: { "Content-Type": "application/json", "Idempotency-Key": `k6-${__VU}-${__ITER}-${Date.now()}` },
      tags: { name: "POST /v1/orders" },
    },
  );
  check(res, {
    "202 accepted": (r) => r.status === 202,
    "has Location": (r) => r.headers["Location"] !== undefined,
  });
}
