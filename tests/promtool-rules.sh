#!/usr/bin/env bash
# Check and unit-test the PrometheusRules (FR-8 pipeline alerts, M6 Sloth SLO rules) with promtool from the Prometheus image we run (3.14.0).
# Extracts spec.groups from each PrometheusRule manifest into a plain rule file first.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
python3 -c 'import sys,yaml; print(yaml.safe_dump({"groups": yaml.safe_load(open(sys.argv[1]))["spec"]["groups"]}))' \
  deploy/observability/pipeline-alerts.yaml > "$tmp/pipeline-alerts.rules.yaml"
python3 -c 'import sys,yaml; d=[x for x in yaml.safe_load_all(open(sys.argv[1])) if x][0]; print(yaml.safe_dump({"groups": d["spec"]["groups"]}))' \
  deploy/observability/slo/generated/orders.rules.yaml > "$tmp/orders-slo.rules.yaml"
cp tests/pipeline-alerts.test.yaml tests/slo-burn.test.yaml "$tmp/"
chmod 755 "$tmp"; chmod 644 "$tmp"/*   # promtool runs as nobody in the image
img=quay.io/prometheus/prometheus:v3.14.0-distroless
docker run --rm -v "$tmp:/w" -w /w --entrypoint promtool "$img" check rules pipeline-alerts.rules.yaml orders-slo.rules.yaml
docker run --rm -v "$tmp:/w" -w /w --entrypoint promtool "$img" test rules pipeline-alerts.test.yaml slo-burn.test.yaml
