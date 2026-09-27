#!/usr/bin/env python3
"""M1 runtime check: analyse what the temporary debug gateway received.

Reads the Collector's container log files straight from the kind node (kubectl logs shows
only the current file, and `verbosity: detailed` rotates past 10 MiB within minutes; older
rotations are gzipped).

  python3 tests/m1-debug-analyse.py --since 2026-09-27T18:30:05 [--until ...]

Checks: distinct service.instance.id per pod, span names per service, probe spans (must be 0),
traces that contain both services, exemplars and bucket boundaries on the duration histogram.
"""

import argparse
import collections
import re
import subprocess

NODE = "freightline-control-plane"
LOGS = "/var/log/pods/observability_otel-debug-gateway-*/otelcol/0.log*"

ap = argparse.ArgumentParser()
ap.add_argument("--since", required=True, help="UTC, e.g. 2026-09-27T18:30:05")
ap.add_argument("--until", default="9999")
args = ap.parse_args()

raw = subprocess.run(
    # The kubelet gzips older rotations, so decompress those.
    ["docker", "exec", NODE, "sh", "-c", f"for f in $(ls -tr {LOGS}); do case $f in *.gz) zcat $f;; *) cat $f;; esac; done"],
    capture_output=True, text=True, check=True,
).stdout
# CRI log format: "<time> stdout F <line>"
txt = "\n".join(re.sub(r"^\S+ (stdout|stderr) [FP] ", "", line) for line in raw.splitlines())

parts = re.split(r"\n(\S+)\tinfo\tResource(Metrics|Spans) #\d+\n", "\n" + txt)
ids, spans_by, traces = set(), collections.Counter(), collections.defaultdict(set)
probe, exemplars, bounds, routes = 0, collections.Counter(), set(), collections.Counter()
for i in range(1, len(parts) - 2, 3):
    ts, kind, block = parts[i], parts[i + 1], parts[i + 2]
    if not (args.since <= ts <= args.until):
        continue
    head = re.split(r"Scope(?:Metrics|Spans) #", block)[0]
    attrs = dict(re.findall(r"-> ([\w.]+): Str\(([^)]*)\)", head))
    svc = attrs.get("service.name")
    if "service.instance.id" in attrs:
        ids.add((svc, attrs["service.instance.id"], attrs.get("freightline.pod_template_hash"), attrs.get("service.version")))
    if kind == "Spans":
        for span in re.split(r"\nSpan #\d+\n", block)[1:]:
            name = re.search(r"Name +: (.*)", span)
            trace_id = re.search(r"Trace ID +: (\w+)", span)
            spans_by[(svc, name.group(1).strip() if name else "?")] += 1
            if trace_id:
                traces[trace_id.group(1)].add(svc)
            if re.search(r"(url\.path|http\.target|http\.route): Str\(/(healthz|readyz)\)", span):
                probe += 1
    else:
        for m in re.finditer(r"Name: http\.server\.request\.duration\n.*?(?=\nMetric #|\Z)", block, re.S):
            seg = m.group(0)
            exemplars[svc] += len(re.findall(r"Exemplar #", seg))
            bounds.update(float(b) for b in re.findall(r"ExplicitBounds #\d+: ([\d.]+)", seg))
            for r in re.findall(r"http\.route: Str\(([^)]*)\)", seg):
                routes[(svc, r)] += 1

print(f"window {args.since} .. {args.until}")
print("1. service.instance.id per pod (service, id, pod_template_hash, version):")
for row in sorted(ids):
    print("    ", *row)
print("2. spans by service and name:")
for (svc, name), n in sorted(spans_by.items()):
    print(f"     {n:6d}  {svc:10s} {name}")
print(f"   probe spans (/healthz, /readyz): {probe}")
both = sum(1 for s in traces.values() if {"orders", "inventory"} <= s)
print(f"3. traces: {len(traces)}, of which {both} contain spans from both orders and inventory")
print("4. exemplars on http.server.request.duration:", dict(exemplars))
print("   http.route values on the duration histogram:", sorted({r for (_, r) in routes}))
print("5. bucket boundaries (s):", ", ".join(f"{b:g}" for b in sorted(bounds)))
