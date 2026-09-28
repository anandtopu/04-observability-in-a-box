#!/usr/bin/env python3
"""M8 / spec section 7 "Correlation": exemplar -> Tempo trace -> Loki by trace_id, 20 samples.

Pass: 20/20 exemplars resolve to a trace with >= 1 log line. The same path a person clicks in Grafana
(RED p99 panel -> exemplar -> trace -> "Logs for this span"), done through the backends' APIs.
Needs port-forwards: Prometheus 9090, Tempo 3200, Loki 3100, and live orders traffic.
    python3 tests/m8-correlation.py [N]
"""
import json
import sys
import time
import urllib.parse
import urllib.request

PROM, TEMPO, LOKI = "http://localhost:9090", "http://localhost:3200", "http://localhost:3100"
N = int(sys.argv[1]) if len(sys.argv) > 1 else 20


def get(url, **params):
    with urllib.request.urlopen(f"{url}?{urllib.parse.urlencode(params)}" if params else url, timeout=30) as r:
        return json.load(r)


now = time.time()
# Exemplars older than 60 s only: Python's span batcher (5 s) and log shipping have finished by then.
ex = get(f"{PROM}/api/v1/query_exemplars",
         query='http_server_request_duration_seconds_bucket{job="freightline/orders",http_route="/v1/orders"}',
         start=now - 900, end=now - 60)
seen, samples = set(), []
for series in ex["data"]:
    for e in series["exemplars"]:
        tid = e["labels"].get("trace_id")
        if tid and tid not in seen:
            seen.add(tid)
            samples.append((float(e["value"]), e["timestamp"], tid))
# The slowest first: those are the ones a person clicks on a p99 panel.
samples.sort(reverse=True)
print(f"{len(samples)} distinct exemplar trace IDs in the last 15 min; checking the {min(N, len(samples))} slowest")

ok = 0
for value, ts, tid in samples[:N]:
    try:
        trace = get(f"{TEMPO}/api/v2/traces/{tid}")
        spans = [s for b in trace["trace"]["resourceSpans"] for ss in b["scopeSpans"] for s in ss["spans"]]
        services = sorted({a["value"]["stringValue"] for b in trace["trace"]["resourceSpans"]
                           for a in b["resource"]["attributes"] if a["key"] == "service.name"})
    except Exception as err:  # noqa: BLE001 - report and count as a failure
        spans, services = [], [f"tempo error: {err}"]
    logs = get(f"{LOKI}/loki/api/v1/query_range",
               query=f'{{service_name=~"orders|inventory"}} | trace_id="{tid}"',
               start=int((ts - 300) * 1e9), end=int((ts + 300) * 1e9), limit=100)
    lines = sum(len(s["values"]) for s in logs["data"]["result"])
    good = len(spans) > 0 and lines >= 1
    ok += good
    print(f"{'PASS' if good else 'FAIL'}  exemplar {value * 1000:7.1f} ms  trace {tid}  "
          f"spans={len(spans):2d} services={','.join(services)}  log lines={lines}")

total = min(N, len(samples))
print(f"RESULT {ok}/{total} exemplars resolve to a trace with >= 1 log line (pass: {N}/{N})")
sys.exit(0 if ok == N else 1)
