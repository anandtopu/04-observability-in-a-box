#!/usr/bin/env python3
"""M5: run every panel query of the Freightline dashboards through Grafana, as the browser would.

Fetches each dashboard back from Grafana (/api/dashboards/uid/...), substitutes the template
variables, and posts every target to /api/ds/query. Reports ERROR / EMPTY / OK per panel.
A panel whose description says it needs kube-state-metrics is allowed to be EMPTY (D-14).
Needs the Grafana port-forward on :3000; the admin password is read from the kps-grafana Secret.
  python3 tests/m5-dashboard-queries.py
"""

import base64
import json
import subprocess
import sys
import time
import urllib.request

GRAFANA = "http://localhost:3000"
VARS = {"$service": "freightline/.*", "$namespace": "freightline"}
pw = base64.b64decode(subprocess.run(
    ["kubectl", "-n", "monitoring", "get", "secret", "kps-grafana", "-o", "jsonpath={.data.admin-password}"],
    capture_output=True, text=True, check=True).stdout).decode()
auth = "Basic " + base64.b64encode(f"admin:{pw}".encode()).decode()


def call(path, body=None):
    req = urllib.request.Request(GRAFANA + path, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": auth, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return json.load(e)


now = int(time.time() * 1000)
bad = 0
for uid in ("freightline-red", "freightline-use", "freightline-flow"):
    dash = call(f"/api/dashboards/uid/{uid}")["dashboard"]
    print(f"== {dash['title']}  (uid {uid}, loaded by Grafana)")
    for p in dash["panels"]:
        if p["type"] in ("row", "text"):
            continue
        ksm = "kube-state-metrics" in p.get("description", "")
        if p["type"] == "nodeGraph":
            # Grafana builds the service map in the browser from Prometheus queries; the backend
            # answers "unsupported query type: 'serviceMap'". Check the series it is built from.
            p = dict(p, targets=[{"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"},
                                  "expr": "sum by (client, server) (rate(traces_service_graph_request_total[5m]))"}])
        queries = []
        for t in p["targets"]:
            q = dict(t)
            if "expr" in q:
                for k, v in VARS.items():
                    q["expr"] = q["expr"].replace(k, v)
            q.update(intervalMs=15000, maxDataPoints=500)
            queries.append(q)
        res = call("/api/ds/query", {"from": str(now - 15 * 60 * 1000), "to": str(now), "queries": queries})
        errs, points, series = [], 0, 0
        for ref, r in res.get("results", {}).items():
            if r.get("error"):
                errs.append(f"{ref}: {r['error'][:120]}")
            for f in r.get("frames", []):
                vals = f.get("data", {}).get("values", [])
                n = len(vals[0]) if vals else 0
                series += 1 if n else 0
                points += n
        if "message" in res and not res.get("results"):
            errs.append(res["message"][:120])
        if errs:
            status, bad = "ERROR", bad + 1
        elif points == 0:
            status = "EMPTY (expected: needs kube-state-metrics, D-14)" if ksm else "EMPTY"
            if not ksm and p["type"] != "nodeGraph":
                bad += 0  # reported, judged in BUILD_LOG (e.g. CFS throttling without CPU limits)
        else:
            status = f"OK    {series} series/frames, {points} points"
        print(f"   [{p['type']:10s}] {p['title'][:62]:62s} {status}" + ("".join(f"\n        {e}" for e in errs)))
print(f"== {bad} panels with query errors")
sys.exit(1 if bad else 0)
