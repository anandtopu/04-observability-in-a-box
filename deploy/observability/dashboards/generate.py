#!/usr/bin/env python3
"""Dashboards as code (FR-5). Generates the three Freightline dashboards and their ConfigMaps.

  python3 deploy/observability/dashboards/generate.py

Writes json/{red,use,flow}.json (reviewable dashboard JSON) and {red,use,flow}.yaml (ConfigMaps
labelled grafana_dashboard: "1", which kps's Grafana sidecar loads from any namespace).
`kubectl apply -f deploy/observability/dashboards/` (spec section 6) applies the ConfigMaps; kubectl
does not recurse into json/. Edit this file, re-run it, commit both outputs: the diff is the review.
"""

import json
import pathlib

HERE = pathlib.Path(__file__).parent
PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}
TEMPO = {"type": "tempo", "uid": "tempo"}
KSM = "Needs kube-state-metrics, not installed yet in this lab (DEVIATIONS D-14): 'No data' is expected until it is."

# Deploy annotations from our own telemetry: a (job, pod_template_hash) pair that did not exist
# 2 minutes ago is a new ReplicaSet, i.e. a rollout. P03's Argo Rollouts annotations can replace it.
ROLLOUTS = {
    "name": "Rollouts",
    "datasource": PROM,
    "enable": True,
    "iconColor": "purple",
    "expr": 'count by (job, freightline_pod_template_hash, service_version) (target_info{job=~"freightline/.*"})'
            ' unless count by (job, freightline_pod_template_hash, service_version) (target_info{job=~"freightline/.*"} offset 2m)',
    "step": "30s",
    "titleFormat": "rollout {{job}}",
    "textFormat": "version {{service_version}}, pod-template-hash {{freightline_pod_template_hash}}",
    "tagKeys": "job",
}


def target(expr, legend="", ref="A", exemplar=False, ds=PROM, instant=False):
    t = {"refId": ref, "datasource": ds, "expr": expr, "legendFormat": legend}
    if exemplar:
        t["exemplar"] = True
    if instant:
        t["instant"], t["range"] = True, False
    return t


class Board:
    def __init__(self, uid, title, tags, variables=(), description=""):
        self.uid, self.title, self.tags, self.vars, self.desc = uid, title, tags, list(variables), description
        self.panels, self.y, self.next_id = [], 0, 1

    def _add(self, p, w, h):
        # Simple flow layout on Grafana's 24-column grid.
        if not self.panels or self.x + w > 24:
            self.x, self.y = 0, self.y + (self.row_h if self.panels else 0)
            self.row_h = 0
        p.update(id=self.next_id, gridPos={"x": self.x, "y": self.y, "w": w, "h": h})
        self.next_id += 1
        self.x += w
        self.row_h = max(self.row_h, h)
        self.panels.append(p)

    def row(self, title):
        if self.panels:
            self.y += self.row_h
        self.panels.append({"type": "row", "title": title, "id": self.next_id, "collapsed": False,
                            "gridPos": {"x": 0, "y": self.y, "w": 24, "h": 1}, "panels": []})
        self.next_id += 1
        self.y += 1
        self.x, self.row_h = 24, 0   # force the next panel onto a new line

    def ts(self, title, targets, unit="short", w=12, h=8, desc="", stack=False, max_=None, soft_max=None):
        fc = {"defaults": {"unit": unit, "min": 0, "custom": {"fillOpacity": 10, "stacking": {"mode": "normal" if stack else "none"}}},
              "overrides": []}
        if soft_max is not None:   # a sensible scale when everything is ~0, still grows on a real burst
            fc["defaults"]["custom"]["axisSoftMax"] = soft_max
        if max_ is not None:
            fc["defaults"]["max"] = max_
        self._add({"type": "timeseries", "title": title, "description": desc, "datasource": targets[0]["datasource"],
                   "targets": targets, "fieldConfig": fc,
                   "options": {"legend": {"displayMode": "table", "placement": "bottom", "calcs": ["lastNotNull", "max"]},
                               "tooltip": {"mode": "multi"}}}, w, h)

    def stat(self, title, targets, unit="short", w=6, h=4, desc="", thresholds=None):
        steps = thresholds or [{"color": "green", "value": None}]
        self._add({"type": "stat", "title": title, "description": desc, "datasource": targets[0]["datasource"],
                   "targets": targets,
                   "fieldConfig": {"defaults": {"unit": unit, "thresholds": {"mode": "absolute", "steps": steps}}, "overrides": []},
                   "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background", "graphMode": "area"}}, w, h)

    def logs(self, title, expr, w=24, h=10, desc=""):
        self._add({"type": "logs", "title": title, "description": desc, "datasource": LOKI,
                   "targets": [{"refId": "A", "datasource": LOKI, "expr": expr}],
                   "options": {"showTime": True, "wrapLogMessage": True, "enableLogDetails": True, "sortOrder": "Descending"}}, w, h)

    def text(self, title, md, w=24, h=4):
        self._add({"type": "text", "title": title, "options": {"mode": "markdown", "content": md}}, w, h)

    def node_graph(self, title, w=24, h=12, desc=""):
        self._add({"type": "nodeGraph", "title": title, "description": desc, "datasource": TEMPO,
                   "targets": [{"refId": "A", "datasource": TEMPO, "queryType": "serviceMap"}]}, w, h)

    def dashboard(self):
        return {
            "uid": self.uid, "title": self.title, "tags": ["freightline", "p04"] + self.tags, "description": self.desc,
            "editable": False, "schemaVersion": 41, "version": 1, "timezone": "utc", "refresh": "30s",
            "time": {"from": "now-1h", "to": "now"},
            "templating": {"list": self.vars},
            "annotations": {"list": [ROLLOUTS]},
            "panels": self.panels,
        }


def query_var(name, label, query, ds=PROM, multi=True, include_all=True, regex=""):
    return {"name": name, "label": label, "type": "query", "datasource": ds, "query": {"query": query, "refId": name},
            "definition": query, "refresh": 2, "multi": multi, "includeAll": include_all, "regex": regex,
            "current": {"selected": True, "text": ["All"], "value": ["$__all"]} if include_all else {}, "sort": 1}


# ---------------------------------------------------------------- RED: one template for every service
H = "http_server_request_duration_seconds"
red = Board("freightline-red", "Freightline / RED", ["red"],
            [query_var("service", "service", f'label_values({H}_count{{job=~"freightline/.*"}}, job)')],
            "Rate, errors and duration for every Freightline service from one template ($service = Prometheus job, "
            "i.e. service.namespace/service.name). Probes are excluded at the source (M1). Exemplars link to Tempo.")
red.row("Rate")
red.ts("Request rate by service", [target(f'sum by (job) (rate({H}_count{{job=~"$service"}}[$__rate_interval]))', "{{job}}")],
       "reqps", desc="Server requests per second (kubelet probes are filtered out, so idle reads 0).")
red.ts("Request rate by route and status", [target(
    f'sum by (job, http_route, http_response_status_code) (rate({H}_count{{job=~"$service"}}[$__rate_interval]))',
    "{{job}} {{http_route}} {{http_response_status_code}}")], "reqps", stack=True,
       desc="http.route is a template (never an ID), so this stays low-cardinality. 409 on reservations = out of stock.")
red.row("Errors")
# "or ... * 0": with no 5xx at all the numerator has no series and a / b returns NOTHING, which a
# panel shows as "No data" exactly when everything is healthy (M5 finding). This makes it read 0.
red.ts("Error ratio (5xx / all)", [target(
    f'(sum by (job) (rate({H}_count{{job=~"$service",http_response_status_code=~"5.."}}[$__rate_interval]))'
    f' or sum by (job) (rate({H}_count{{job=~"$service"}}[$__rate_interval])) * 0)'
    f' / sum by (job) (rate({H}_count{{job=~"$service"}}[$__rate_interval]))', "{{job}}")], "percentunit", soft_max=0.01,
       desc="The availability SLO (M6) counts the same 5xx. A 409 (REJECTED order) is a correct answer, not an error.")
red.stat("Error ratio, last 5 min", [target(
    f'(sum(rate({H}_count{{job=~"$service",http_response_status_code=~"5.."}}[5m])) or sum(rate({H}_count{{job=~"$service"}}[5m])) * 0)'
    f' / sum(rate({H}_count{{job=~"$service"}}[5m]))',
    instant=True)], "percentunit", w=12,
         thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.001}, {"color": "red", "value": 0.01}])
red.row("Duration")
red.ts("Latency p50 / p99 (exemplars on: click a dot to open the trace)", [
    target(f'histogram_quantile(0.99, sum by (job, le) (rate({H}_bucket{{job=~"$service"}}[$__rate_interval])))', "p99 {{job}}", "A", exemplar=True),
    target(f'histogram_quantile(0.50, sum by (job, le) (rate({H}_bucket{{job=~"$service"}}[$__rate_interval])))', "p50 {{job}}", "B"),
], "s", w=16, desc="Quantiles are interpolated inside buckets (…0.1, 0.25, 0.5…). Exemplars carry trace_id (M1) and link to Tempo.")
red.stat("Requests within 250 ms (latency SLI)", [target(
    f'sum(rate({H}_bucket{{job=~"$service",le="0.25"}}[5m])) / sum(rate({H}_count{{job=~"$service"}}[5m]))', instant=True)],
         "percentunit", w=8, h=8, desc="0.25 is a real bucket boundary, so this ratio is exact, not interpolated (why M6 uses 250 ms).",
         thresholds=[{"color": "red", "value": None}, {"color": "orange", "value": 0.98}, {"color": "green", "value": 0.99}])
red.row("Logs")
red.logs("Warnings and errors (click a line: trace_id links to Tempo)",
         '{service_namespace="freightline"} | severity_text=~"warn|error"',
         desc="Loki via the node agent (M4). trace_id is structured metadata, so the derived field opens the trace.")

# ---------------------------------------------------------------- USE: every pod and the node
C = 'namespace="$namespace", container!="", container!="POD"'
use = Board("freightline-use", "Freightline / USE", ["use"],
            [query_var("namespace", "namespace", 'label_values(container_cpu_usage_seconds_total{container!=""}, namespace)',
                       multi=False, include_all=False) | {"current": {"text": "freightline", "value": "freightline"}}],
            "Utilisation, saturation and errors for every pod in $namespace and for the node. Ratios against "
            "requests/limits and restart/OOM reasons come from kube-state-metrics (D-14: not installed yet).")
use.row("Pods: CPU")
use.ts("CPU used (cores)", [target(f'sum by (pod) (rate(container_cpu_usage_seconds_total{{{C}}}[$__rate_interval]))', "{{pod}}")],
       "short", desc="Absolute usage from cAdvisor. Works without kube-state-metrics.")
use.ts("CPU utilisation vs request", [target(
    f'sum by (pod) (rate(container_cpu_usage_seconds_total{{{C}}}[$__rate_interval]))'
    ' / sum by (pod) (kube_pod_container_resource_requests{namespace="$namespace", resource="cpu"})', "{{pod}}")],
       "percentunit", desc="Above 100% is fine without a CPU limit, but it is what the scheduler did not reserve. " + KSM)
use.ts("CPU saturation: CFS throttled / total periods", [target(
    f'sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{{{C}}}[$__rate_interval]))'
    f' / sum by (pod) (rate(container_cpu_cfs_periods_total{{{C}}}[$__rate_interval]))', "{{pod}}")],
       "percentunit", w=24, desc="Only pods with a CPU limit have a CFS quota. Freightline sets memory limits only (P02), so "
                                 "'No data' here means 'not throttleable', not 'broken'.")
use.row("Pods: memory")
use.ts("Working set (bytes)", [target(f'sum by (pod) (container_memory_working_set_bytes{{{C}}})', "{{pod}}")], "bytes",
       desc="What the kernel counts against the limit (cAdvisor). Works without kube-state-metrics.")
use.ts("Working set vs limit", [target(
    f'sum by (pod) (container_memory_working_set_bytes{{{C}}})'
    ' / sum by (pod) (kube_pod_container_resource_limits{namespace="$namespace", resource="memory"})', "{{pod}}")],
       "percentunit", max_=1, desc="Near 100% means the next allocation spike is an OOMKill. " + KSM)
use.row("Pods: errors")
use.ts("Container restarts (1 h)", [target('sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace="$namespace"}[1h]))', "{{pod}}")],
       "short", w=8, desc=KSM)
use.ts("Last termination reason = OOMKilled", [target(
    'sum by (pod) (kube_pod_container_status_last_terminated_reason{namespace="$namespace", reason="OOMKilled"})', "{{pod}}")],
       "short", w=8, desc=KSM)
use.ts("OOM events (cAdvisor, works today)", [target(f'sum by (pod) (increase(container_oom_events_total{{{C}}}[$__rate_interval]))', "{{pod}}")],
       "short", w=8, desc="Kernel OOM kills inside the pod's cgroup, from the kubelet.")
use.row("Node")
use.ts("CPU utilisation", [target('1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[$__rate_interval]))', "{{instance}}")],
       "percentunit", w=8, max_=1)
use.ts("CPU saturation: load1 per core", [target(
    'node_load1 / on (instance) count by (instance) (node_cpu_seconds_total{mode="idle"})', "{{instance}}")], "short", w=8,
       desc="Above 1 means runnable tasks are waiting for a CPU.")
use.ts("Memory utilisation", [target('1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes', "{{instance}}")],
       "percentunit", w=8, max_=1)
use.ts("Memory saturation: major page faults/s", [target('rate(node_vmstat_pgmajfault[$__rate_interval])', "{{instance}}")],
       "short", w=12, desc="Pages read back from disk: the node is short of memory before anything is OOM-killed.")
use.ts("Network errors/s", [target(
    'sum by (instance) (rate(node_network_receive_errs_total[$__rate_interval]) + rate(node_network_transmit_errs_total[$__rate_interval]))',
    "{{instance}}")], "short", w=12)

# ---------------------------------------------------------------- Flow: the order journey (adapted, D-01a)
S = "traces_spanmetrics"
flow = Board("freightline-flow", "Freightline / Flow", ["flow"], [],
             "How an order moves through Freightline. P04-lite has no Kafka (D-01a): the spec's outbox backlog age, "
             "consumer lag and DLQ depth are replaced by the synchronous reservation path (adapted).")
flow.text("About this dashboard (P04-lite adaptation)",
          "Full Freightline (P02) publishes events through a transactional outbox to Kafka; this dashboard would show "
          "**outbox backlog age, consumer lag and DLQ depth**. P04-lite reserves stock with a synchronous HTTP call "
          "(DEVIATIONS D-01a), so those panels are replaced by **order outcomes, reservation results, precheck "
          "degradations and database latency**, plus Tempo's service graph, which is the same in both.", h=3)
flow.row("Order outcomes")
flow.ts("Orders by final status (from logs)", [target(
    'sum by (status) (count_over_time({service_name="orders"} | json | msg="order accepted" | replay="false" [$__auto]))',
    "{{status}}", ds=LOKI)], "short", stack=True,
        desc="LogQL metric over the orders JSON log line. REJECTED = out of stock; PENDING = inventory was slow or down.")
flow.ts("Reservation results (inventory)", [target(
    f'sum by (http_response_status_code) (rate({H}_count{{job="freightline/inventory", http_route="/v1/reservations"}}[$__rate_interval]))',
    "{{http_response_status_code}}")], "reqps", stack=True,
        desc="201 reserved, 200 replayed, 409 out of stock, 503 database pool exhausted (the P04 incident, M8).")
flow.ts("Precheck degraded (orders could not reach inventory in 300 ms)", [target(
    'sum(count_over_time({service_name="orders"} |= "inventory precheck degraded" [$__auto]))', "degraded", ds=LOKI)],
        "short", desc="Orders accepted as PENDING because inventory was slow or down: early warning for the M8 game day.")
flow.ts("DB pool exhausted (inventory 503s)", [target(
    'sum(count_over_time({service_name="inventory"} |= "db pool exhausted" [$__auto]))', "pool exhausted", ds=LOKI)],
        "short")
flow.row("Latency along the path (Tempo span metrics)")
flow.ts("p99 by span (server, client, database)", [target(
    f'histogram_quantile(0.99, sum by (service, span_name, le) (rate({S}_latency_bucket{{service=~"orders|inventory"}}[$__rate_interval])))',
    "{{service}} {{span_name}}", exemplar=True)], "s", w=24,
        desc="From Tempo's metrics-generator: every span, including SQL statements, with exemplars back to traces.")
flow.row("Service graph")
flow.node_graph("orders -> inventory -> postgres (Tempo service graph)",
                desc="Edges from client/server span pairs (traces_service_graph_*); click a node for its RED and traces.")

for name, board in (("red", red), ("use", use), ("flow", flow)):
    d = board.dashboard()
    body = json.dumps(d, indent=2, sort_keys=False)
    (HERE / "json").mkdir(exist_ok=True)
    (HERE / "json" / f"{name}.json").write_text(body + "\n")
    cm = (
        "# GENERATED by generate.py from the same definition as json/{0}.json. Do not edit by hand.\n"
        "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: freightline-{0}-dashboard\n  namespace: monitoring\n"
        "  labels:\n    grafana_dashboard: \"1\"\n    app.kubernetes.io/part-of: p04-observability\n"
        "data:\n  freightline-{0}.json: |\n"
    ).format(name) + "".join(f"    {line}\n" for line in body.splitlines())
    (HERE / f"{name}.yaml").write_text(cm)
    print(f"{name}: {sum(1 for p in d['panels'] if p['type'] != 'row')} panels -> json/{name}.json, {name}.yaml")
