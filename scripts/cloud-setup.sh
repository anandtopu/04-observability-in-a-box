#!/usr/bin/env bash
# Idempotent environment setup for a Claude Code cloud session (Ubuntu 24.04, x86_64) for P04.
# Use it as the cloud environment's setup script, or have Claude run it: bash scripts/cloud-setup.sh
# It never fails hard on a blocked download. It prints WARN plus the domain to allow, so you can fix the allowlist.
set -uo pipefail

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
SUDO=""; if [ "$(id -u)" -ne 0 ] && have sudo; then SUDO="sudo"; fi
BIN="${HOME}/.local/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH"

KIND_VERSION="v0.33.0"
KUBECTL_VERSION="v1.36.4"
HELM_VERSION="v4.3.0"
K6_VERSION="v2.3.0"
SLOTH_VERSION="v0.16.0"
KUBECONFORM_VERSION="v0.7.0"

fetch() { # url dest domain-hint
  if curl -fsSL --retry 2 "$1" -o "$2"; then return 0; fi
  warn "download failed: $1  -> allow domain '$3' (Environment settings > Network access > Custom, keep the default list)"; return 1
}

log "OS / arch / resources"
uname -srm; (. /etc/os-release && echo "$PRETTY_NAME") || true
echo "CPUs: $(nproc)  RAM: $(free -g | awk '/Mem:/{print $2" GB total, "$7" GB available"}')  Disk: $(df -h / | awk 'NR==2{print $4" free"}')"

log "uv + Python 3.14"
have uv || curl -LsSf https://astral.sh/uv/install.sh | sh
uv python install 3.14 >/dev/null 2>&1 && uv python find 3.14 || warn "uv python install 3.14 failed (github.com / python-build-standalone)"

log "Go and Node (preinstalled in the cloud image)"
go version || warn "go missing"; node --version || warn "node missing"

log "jq, openssl"
have jq || { $SUDO apt-get update -y >/dev/null && $SUDO apt-get install -y jq >/dev/null; }

log "kubectl ${KUBECTL_VERSION} (dl.k8s.io)"
if ! have kubectl; then fetch "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" "$BIN/kubectl" "dl.k8s.io" && chmod +x "$BIN/kubectl"; fi
have kubectl && kubectl version --client 2>/dev/null | head -1

log "kind ${KIND_VERSION} (github.com)"
if ! have kind; then fetch "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64" "$BIN/kind" "github.com" && chmod +x "$BIN/kind"; fi
have kind && kind version

log "helm ${HELM_VERSION} (get.helm.sh)"
if ! have helm; then
  tmp=$(mktemp -d)
  fetch "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" "$tmp/helm.tgz" "get.helm.sh" && tar -xzf "$tmp/helm.tgz" -C "$tmp" && install -m 0755 "$tmp/linux-amd64/helm" "$BIN/helm"
fi
have helm && helm version --short

log "k6 ${K6_VERSION}, sloth ${SLOTH_VERSION}, kubeconform ${KUBECONFORM_VERSION} (github.com)"
if ! have k6; then tmp=$(mktemp -d); fetch "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-amd64.tar.gz" "$tmp/k6.tgz" "github.com" && tar -xzf "$tmp/k6.tgz" -C "$tmp" && install -m 0755 "$tmp"/k6-*/k6 "$BIN/k6"; fi
if ! have sloth; then fetch "https://github.com/slok/sloth/releases/download/${SLOTH_VERSION}/sloth-linux-amd64" "$BIN/sloth" "github.com" && chmod +x "$BIN/sloth"; fi
if ! have kubeconform; then tmp=$(mktemp -d); fetch "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" "$tmp/kc.tgz" "github.com" && tar -xzf "$tmp/kc.tgz" -C "$tmp" && install -m 0755 "$tmp/kubeconform" "$BIN/kubeconform"; fi
for t in k6 sloth kubeconform; do have $t && echo "$t: ok" || warn "$t missing"; done

log "Container runtime"
if have docker && docker info >/dev/null 2>&1; then
  docker version --format 'docker client {{.Client.Version}} / server {{.Server.Version}}'
  docker compose version || warn "docker compose plugin missing"
else
  warn "docker daemon not reachable - Tier B/C only (see CLAUDE.md)"
fi

log "Registry reachability (these hosts P04 pulls from)"
for u in https://registry-1.docker.io/v2/ https://quay.io/v2/ https://registry.k8s.io/v2/ https://ghcr.io/v2/ https://prometheus-community.github.io/helm-charts/index.yaml https://open-telemetry.github.io/opentelemetry-helm-charts/index.yaml; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$u"); case "$code" in 2*|401) echo "OK   $u ($code)";; *) warn "BLOCKED/ERR $u ($code)";; esac
done

log "Done. Next: decide the tier (A kind / B compose / C render-only) per CLAUDE.md."
