// M5 walk-through: exemplar -> trace -> logs, checked through the APIs and captured as screenshots.
//   node tests/m5-walkthrough.mjs     (uses the globally installed playwright; ESM ignores NODE_PATH)
// Needs port-forwards: Grafana :3000, Prometheus :9090, Tempo :3200, Loki :3100.
// Writes docs/evidence/p04/m5-{red,trace,logs,flow,use}.png and prints each hop.
import { execSync } from "node:child_process";
import { createRequire } from "node:module";
const { chromium } = createRequire(execSync("npm root -g").toString().trim() + "/")("playwright");

const G = "http://localhost:3000", OUT = "docs/evidence/p04";
const pw = Buffer.from(execSync("kubectl -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}'").toString(), "base64").toString();
const auth = "Basic " + Buffer.from(`admin:${pw}`).toString("base64");
const j = async (url) => (await fetch(url)).json();
const now = Math.floor(Date.now() / 1000);

// Hop 1: the slowest exemplar on the RED p99 panel (the dot an on-call engineer would click).
const ex = await j(`http://localhost:9090/api/v1/query_exemplars?query=${encodeURIComponent(
  'http_server_request_duration_seconds_bucket{job="freightline/orders"}')}&start=${now - 900}&end=${now}`);
const all = ex.data.flatMap((s) => s.exemplars);
const slow = all.sort((a, b) => Number(b.value) - Number(a.value))[0];
const tid = slow.labels.trace_id;
console.log(`hop 1 exemplar: ${all.length} exemplars in 15 min on orders; slowest ${(Number(slow.value) * 1000).toFixed(1)} ms -> trace_id ${tid}`);

// Hop 2: that trace in Tempo.
const tr = await j(`http://localhost:3200/api/v2/traces/${tid}`);
const spans = tr.trace.resourceSpans.flatMap((r) => r.scopeSpans.flatMap((s) => s.spans.map((sp) => ({
  svc: r.resource.attributes.find((a) => a.key === "service.name").value.stringValue, name: sp.name.split("\n")[0].slice(0, 40),
  ms: (Number(sp.endTimeUnixNano) - Number(sp.startTimeUnixNano)) / 1e6 }))));
console.log(`hop 2 trace: ${spans.length} spans; services ${[...new Set(spans.map((s) => s.svc))].sort().join(", ")}`);
for (const s of spans.sort((a, b) => b.ms - a.ms).slice(0, 4)) console.log(`      ${s.ms.toFixed(1).padStart(7)} ms  ${s.svc}  ${s.name}`);

// Hop 3: its logs, with the query Grafana's tracesToLogsV2 builds (service.name -> service_name, filterByTraceID).
const lq = `{service_name=~"orders|inventory"} | trace_id="${tid}"`;
const lg = await j(`http://localhost:3100/loki/api/v1/query_range?query=${encodeURIComponent(lq)}&start=${now - 900}000000000&limit=20`);
const lines = lg.data.result.flatMap((st) => st.values.map((v) => `${st.stream.service_name}: ${JSON.parse(v[1]).msg}`));
console.log(`hop 3 logs: ${lines.length} lines for the trace -> ${lines.join(" | ")}`);

// Screenshots of the same path in Grafana's UI.
const browser = await chromium.launch();
// locale: in the cloud VM Chromium inherits LANG=C and reports "en-US@posix", which Grafana's
// bootstrap rejects (RangeError: Invalid language tag) and renders "failed to load" (M5 finding).
const page = await browser.newPage({ locale: "en-US", timezoneId: "UTC", viewport: { width: 1600, height: 1000 }, extraHTTPHeaders: { Authorization: auth } });
const shot = async (url, file, wait = 6000) => {
  await page.goto(G + url, { waitUntil: "networkidle" });
  await page.waitForTimeout(wait);
  await page.screenshot({ path: `${OUT}/${file}`, fullPage: false });
  console.log(`   screenshot ${OUT}/${file}`);
};
const pane = (ds, q) => "/explore?schemaVersion=1&panes=" + encodeURIComponent(JSON.stringify({
  a: { datasource: ds, queries: [Object.assign({ refId: "A", datasource: { type: ds, uid: ds } }, q)], range: { from: "now-15m", to: "now" } } }));
await shot("/d/freightline-red/freightline-red?orgId=1&from=now-15m&to=now&kiosk", "m5-red.png");
await shot(pane("tempo", { queryType: "traceql", query: tid }), "m5-trace.png");
await shot(pane("loki", { expr: lq }), "m5-logs.png");
await shot("/d/freightline-flow/freightline-flow?orgId=1&from=now-15m&to=now&kiosk", "m5-flow.png", 8000);
await shot("/d/freightline-use/freightline-use?orgId=1&from=now-15m&to=now&kiosk", "m5-use.png");
await browser.close();
