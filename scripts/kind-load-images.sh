#!/usr/bin/env bash
# Pull third-party images on the host and side-load them into the kind node.
#
# Why: in the cloud VM, kind copies the host's HTTPS_PROXY (http://127.0.0.1:<port>) into the
# node, where 127.0.0.1 is the node itself, so containerd cannot pull anything. The host's
# dockerd can. Side-loading also avoids re-pulling from Docker Hub, whose anonymous limit is
# shared by every session behind the same egress IP. On a laptop this script is optional.
#
# Usage: bash scripts/kind-load-images.sh [m0|m2|...|all]   (default: all milestones so far)
set -uo pipefail
CLUSTER="${KIND_CLUSTER:-freightline}"

# One list per milestone; pods must reference exactly these tags (imagePullPolicy IfNotPresent).
M0=(
  ghcr.io/cloudnative-pg/postgresql:18
  ghcr.io/axllent/mailpit:v1.31
)

# M1 uses the Collector image for a temporary debug gateway; M4 runs it for real.
M1=(
  otel/opentelemetry-collector-contrib:0.161.0
  grafana/k6:2.3.0          # in-cluster load (load/k6-job.yaml)
)

# M2: kube-prometheus-stack 91.5.1 (list from `helm template`; the config-reloader is injected
# by the operator via --prometheus-config-reloader, so it never appears as an image: line).
M2=(
  quay.io/prometheus/prometheus:v3.14.0-distroless
  quay.io/prometheus-operator/prometheus-operator:v0.94.1
  quay.io/prometheus-operator/prometheus-config-reloader:v0.94.1
  quay.io/prometheus/alertmanager:v0.34.1
  quay.io/prometheus/node-exporter:v1.12.1-distroless
  quay.io/kiwigrid/k8s-sidecar:2.11.2
  registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0
  ghcr.io/jkroepke/kube-webhook-certgen:1.8.8
  docker.io/grafana/grafana:13.2.2-distroless     # the only Docker Hub image so far
)

case "${1:-all}" in
  m0) IMAGES=("${M0[@]}") ;;
  m1) IMAGES=("${M1[@]}") ;;
  m2) IMAGES=("${M2[@]}") ;;
  all) IMAGES=("${M0[@]}" "${M1[@]}" "${M2[@]}") ;;
  *) echo "unknown set: $1" >&2; exit 2 ;;
esac

# Docker 29's containerd image store saves a multi-platform index whose other-arch layers
# were never pulled, and `kind load docker-image` (ctr import --all-platforms) then fails with
# "content digest ... not found". Saving only linux/amd64 and loading the archive avoids it.
load() {
  local tar; tar="$(mktemp --suffix=.tar)"
  docker save --platform linux/amd64 -o "$tar" "$1" && kind load image-archive "$tar" --name "$CLUSTER" >/dev/null 2>&1
  local rc=$?; rm -f "$tar"; return $rc
}

rc=0
for img in "${IMAGES[@]}"; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    docker pull -q "$img" || { echo "FAIL pull $img" >&2; rc=1; continue; }
  fi
  load "$img" && echo "OK   $img" || { echo "FAIL load $img" >&2; rc=1; }
done
exit $rc
