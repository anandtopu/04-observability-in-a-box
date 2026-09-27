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

# M3: grafana-community tempo 3.0.0 and loki 18.13.5 (Docker Hub). Loki's rules sidecar is pointed
# at the quay.io kiwigrid image kps already uses (loki-values.yaml), saving a Docker Hub pull.
M3=(
  docker.io/grafana/tempo:3.0.3
  docker.io/grafana/loki:3.7.8
)

case "${1:-all}" in
  m0) IMAGES=("${M0[@]}") ;;
  m1) IMAGES=("${M1[@]}") ;;
  m2) IMAGES=("${M2[@]}") ;;
  m3) IMAGES=("${M3[@]}") ;;
  all) IMAGES=("${M0[@]}" "${M1[@]}" "${M2[@]}" "${M3[@]}") ;;
  *) echo "unknown set: $1" >&2; exit 2 ;;
esac

# Loading into the kind node, amd64 only. Two Docker 29 (containerd image store) pitfalls:
#  1. `docker save` keeps the multi-platform index, and `kind load` imports with --all-platforms,
#     which fails on arm/v7 or arm64 blobs that were never pulled ("content digest ... not found").
#     So we import ourselves with `ctr import --platform linux/amd64`.
#  2. Docker can report an image complete while a shared layer blob is unreadable (grafana/loki:3.7.8,
#     M3), so `docker save` fails. Fallback: pull fresh with ctr into a separate namespace ("p04",
#     Docker's own images untouched) and export from there.
NODE="${CLUSTER}-control-plane"
DOCKER_CTRD=/var/run/docker/containerd/containerd.sock
import_tar() { docker exec -i "$NODE" ctr -n k8s.io images import --platform linux/amd64 - < "$1" >/dev/null 2>&1; }
load() {
  local tar; tar="$(mktemp --suffix=.tar)"; local rc=1
  if docker save --platform linux/amd64 -o "$tar" "$1" 2>/dev/null && import_tar "$tar"; then
    rc=0
  elif [ -S "$DOCKER_CTRD" ] \
    && ctr -a "$DOCKER_CTRD" -n p04 images pull --platform linux/amd64 "$(ref "$1")" >/dev/null 2>&1 \
    && ctr -a "$DOCKER_CTRD" -n p04 images export --platform linux/amd64 "$tar" "$(ref "$1")" 2>/dev/null \
    && import_tar "$tar"; then
    rc=0
  fi
  rm -f "$tar"; return $rc
}
# ctr needs fully qualified names (docker.io/library/... for official images).
ref() { case "$1" in *.*/*) echo "$1" ;; */*) echo "docker.io/$1" ;; *) echo "docker.io/library/$1" ;; esac; }

rc=0
for img in "${IMAGES[@]}"; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    docker pull -q "$img" || { echo "FAIL pull $img" >&2; rc=1; continue; }
  fi
  load "$img" && echo "OK   $img" || { echo "FAIL load $img" >&2; rc=1; }
done
exit $rc
