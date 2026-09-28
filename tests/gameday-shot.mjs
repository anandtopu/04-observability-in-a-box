// M8 game day relay: a remote participant can't reach the lab's Grafana (a port-forward inside the
// VM), so the guide performs each step they ask for in the real Grafana and sends the screenshot.
//   node tests/gameday-shot.mjs "<grafana path, e.g. /d/freightline-red/...>" <out.png> [wait-ms] ["panel title to scroll to"]
// Needs the Grafana port-forward on :3000. Same auth and locale fix as tests/m5-walkthrough.mjs.
import { execSync } from "node:child_process";
import { createRequire } from "node:module";
const { chromium } = createRequire(execSync("npm root -g").toString().trim() + "/")("playwright");

const [path, out, wait = "5000", scrollTo] = process.argv.slice(2);
const pw = Buffer.from(execSync("kubectl -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}'").toString(), "base64").toString();
const browser = await chromium.launch();
const page = await browser.newPage({ locale: "en-US", timezoneId: "UTC", viewport: { width: 1600, height: 1000 },
  extraHTTPHeaders: { Authorization: "Basic " + Buffer.from(`admin:${pw}`).toString("base64") } });
const t0 = Date.now();
await page.goto("http://localhost:3000" + path, { waitUntil: "networkidle" });
await page.waitForTimeout(Number(wait));
if (scrollTo) { // "scroll down to <panel>": bring the panel title to the top, then let lazy panels render
  await page.getByText(scrollTo, { exact: false }).first().evaluate((el) => el.scrollIntoView({ block: "start" }));
  await page.waitForTimeout(3000);
}
await page.screenshot({ path: out });
console.log(`${new Date().toISOString()} ${out} (${((Date.now() - t0) / 1000).toFixed(1)} s)`);
await browser.close();
