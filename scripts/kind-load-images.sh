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

case "${1:-all}" in
  m0) IMAGES=("${M0[@]}") ;;
  all) IMAGES=("${M0[@]}") ;;
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
