#!/usr/bin/env bash
# Check and unit-test the PrometheusRules with promtool from the Prometheus image we run (3.14.0).
# Extracts spec.groups from each PrometheusRule manifest into a plain rule file first.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
python3 -c 'import sys,yaml; print(yaml.safe_dump({"groups": yaml.safe_load(open(sys.argv[1]))["spec"]["groups"]}))' \
  deploy/observability/pipeline-alerts.yaml > "$tmp/pipeline-alerts.rules.yaml"
cp tests/pipeline-alerts.test.yaml "$tmp/"
chmod 755 "$tmp"; chmod 644 "$tmp"/*   # promtool runs as nobody in the image
img=quay.io/prometheus/prometheus:v3.14.0-distroless
docker run --rm -v "$tmp:/w" -w /w --entrypoint promtool "$img" check rules pipeline-alerts.rules.yaml
docker run --rm -v "$tmp:/w" -w /w --entrypoint promtool "$img" test rules pipeline-alerts.test.yaml
