#!/usr/bin/env bash
# Install or upgrade the Freightline (P04-lite) release. Always rebuilds the library-chart
# dependency first: the umbrella renders the packaged copy in charts/*.tgz, so an edit to
# freightline-service without `helm dependency build` silently does nothing (M2 finding).
# Usage (repo root): bash app/deploy.sh [extra helm args, e.g. --set services.orders.replicas=2]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
helm dependency build "$HERE/deploy/helm/freightline" >/dev/null
helm upgrade --install freightline "$HERE/deploy/helm/freightline" -n freightline \
  -f "$HERE/deploy/envs/kind/values.yaml" --wait --timeout 5m "$@"
