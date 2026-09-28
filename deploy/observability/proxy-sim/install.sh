#!/usr/bin/env bash
# Install the TLS-inspecting proxy simulation for the Cobalt profile (M7).
#   gateway --HTTPS_PROXY CONNECT--> proxy-sim (mitmproxy) --TLS--> customer-sim HEC :8089
# proxy-sim terminates TLS and re-signs it with the "Cobalt TLS Inspection CA", exactly like a
# corporate proxy; it verifies customer-sim's own server certificate against the "Splunk server CA".
# Keys are generated here into Secrets and never written to the repo (.gitignore blocks *.pem).
# Idempotent: existing Secrets are kept, so the gateway's trusted CA stays stable across re-runs.
set -euo pipefail
cd "$(dirname "$0")"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
kubectl create namespace proxy-sim --dry-run=client -o yaml | kubectl apply -f - >/dev/null

if ! kubectl -n proxy-sim get secret proxy-ca >/dev/null 2>&1; then
  # 1. Cobalt's TLS inspection CA: the proxy signs every intercepted site with it.
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/O=Cobalt Bank (lab)/CN=Cobalt TLS Inspection CA" \
    -keyout "$tmp/insp.key" -out "$tmp/insp.crt" 2>/dev/null
  cat "$tmp/insp.key" "$tmp/insp.crt" > "$tmp/mitmproxy-ca.pem"          # mitmproxy wants key + cert in one file
  kubectl -n proxy-sim create secret generic proxy-ca --from-file=mitmproxy-ca.pem="$tmp/mitmproxy-ca.pem" >/dev/null
  # Only the CERTIFICATE goes to the gateway (what Cobalt's platform team would hand us).
  kubectl -n observability create secret generic cobalt-proxy-ca --from-file=ca.crt="$tmp/insp.crt" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # 2. The real Splunk HEC's server certificate (customer-sim), signed by the "Splunk server CA".
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/O=Cobalt Bank (lab)/CN=Cobalt Splunk Server CA" \
    -keyout "$tmp/srv-ca.key" -out "$tmp/srv-ca.crt" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=hec.cobalt.example" -keyout "$tmp/hec.key" -out "$tmp/hec.csr" 2>/dev/null
  printf 'subjectAltName=DNS:hec.cobalt.example\n' > "$tmp/san.ext"
  openssl x509 -req -in "$tmp/hec.csr" -CA "$tmp/srv-ca.crt" -CAkey "$tmp/srv-ca.key" -CAcreateserial -days 30 \
    -extfile "$tmp/san.ext" -out "$tmp/hec.crt" 2>/dev/null
  kubectl -n customer-sim create secret tls customer-sim-tls --cert="$tmp/hec.crt" --key="$tmp/hec.key" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n proxy-sim create secret generic splunk-server-ca --from-file=ca.crt="$tmp/srv-ca.crt" >/dev/null
  echo "generated: Cobalt TLS Inspection CA, Cobalt Splunk Server CA, hec.cobalt.example server cert"
fi

# The proxy resolves hec.cobalt.example itself (CONNECT carries the name): point it at customer-sim.
ip=$(kubectl -n customer-sim get svc customer-sim -o jsonpath='{.spec.clusterIP}')
sed "s/__CUSTOMER_SIM_IP__/$ip/" proxy-sim.yaml | kubectl apply -f -
kubectl -n proxy-sim rollout status deploy/proxy-sim --timeout=120s
