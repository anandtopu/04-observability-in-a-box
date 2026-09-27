#!/usr/bin/env bash
# Build the P04-lite service images and load them into the kind cluster.
# Usage (from the repo root): bash app/build-images.sh [tag]
set -euo pipefail
TAG="${1:-0.1.0}"
CLUSTER="${KIND_CLUSTER:-freightline}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# orders: static Go binary built on the host, copied into a scratch image (DEVIATIONS D-05).
( cd "$HERE/services/orders" && GOTOOLCHAIN=local CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o bin/orders ./cmd/orders )
docker build -q -t "freightline/orders:$TAG" "$HERE/services/orders"

# inventory: pass the TLS-inspecting proxy's CA as a build secret when it exists (cloud VM only).
secret=()
[ -s /root/.ccr/ca-bundle.crt ] && secret=(--secret id=ca,src=/root/.ccr/ca-bundle.crt)
docker build -q "${secret[@]}" -t "freightline/inventory:$TAG" "$HERE/services/inventory"

# Single-platform archive: see the note in scripts/kind-load-images.sh.
for svc in orders inventory; do
  tar="$(mktemp --suffix=.tar)"
  docker save --platform linux/amd64 -o "$tar" "freightline/$svc:$TAG"
  kind load image-archive "$tar" --name "$CLUSTER" >/dev/null 2>&1 && echo "loaded freightline/$svc:$TAG"
  rm -f "$tar"
done
