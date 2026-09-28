#!/usr/bin/env bash
# Bring the Tier A lab back after the cloud VM was reclaimed (M8: it happened 4 times in one day).
# The kind node container keeps etcd, images and volumes, so this only restarts things; it changes no
# Helm values (a running game-day fault stays as deployed).
#   bash scripts/recover.sh [k6-minutes]     (0 = don't start load)
# Port-forward PIDs go to $PF_DIR/pids (default: /tmp/p04-pf) so they can be stopped by PID.
set -uo pipefail
cd "$(dirname "$0")/.."
PF_DIR=${PF_DIR:-/tmp/p04-pf}; K6_MIN=${1:-120}
say() { echo "$(date -u +%H:%M:%S) $*"; }

bash scripts/cloud-setup.sh 2>&1 | grep -E "dockerd|BLOCKED"
# cloud-setup.sh returns as soon as dockerd is launched; its socket can take a few seconds to accept
# (M8: `docker start` raced it and the node never came up). Wait, then start the node.
until docker info >/dev/null 2>&1; do sleep 1; done
docker start freightline-control-plane >/dev/null || { say "docker start FAILED"; exit 1; }
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do sleep 3; done; say "node Ready"
# Right after a restart kubelet reports "services have not yet been read" and the scheduler may lose its
# lease once: both clear on their own. Wait until every pod (except old k6 runs) is Ready.
notready() { kubectl get pods -A --no-headers 2>/dev/null | grep -v k6-steady |
  awk '{split($3,a,"/"); if (a[1]!=a[2] && $4!="Completed") n++} END {print n+0}'; }
# Just after the node turns Ready, pods still show their pre-restart "1/1 Running" (M8: this script's
# first version declared "all pods Ready" in the same second). Give kubelet 30 s to report, then
# require 3 clean checks in a row.
sleep 30; ok=0
while [ $ok -lt 3 ]; do if [ "$(notready)" = "0" ]; then ok=$((ok+1)); else ok=0; fi; sleep 10; done
say "all pods Ready (3 consecutive checks)"

mkdir -p "$PF_DIR"; : > "$PF_DIR/pids"
pf() { nohup kubectl -n "$1" port-forward "$2" "$3" > "$PF_DIR/$(echo "$2" | tr / _).log" 2>&1 & echo "$! $1 $2 $3" >> "$PF_DIR/pids"; }
pf monitoring svc/kps-prometheus 9090:9090; pf monitoring svc/loki 3100:3100; pf monitoring svc/tempo 3200:3200
pf monitoring svc/kps-grafana 3000:80; pf monitoring svc/kps-alertmanager 9093:9093; pf freightline svc/mailpit 18025:8025
until curl -sf localhost:3000/api/health >/dev/null && curl -sf localhost:9090/-/ready >/dev/null; do sleep 1; done
for u in localhost:9090/-/ready localhost:3100/ready localhost:3200/ready localhost:3000/api/health localhost:9093/-/ready localhost:18025/api/v1/info; do
  printf "%s=%s " "$u" "$(curl -s -o /dev/null -w '%{http_code}' "$u")"; done; echo

if [ "$K6_MIN" != "0" ]; then
  kubectl -n freightline delete job k6-steady --ignore-not-found --wait >/dev/null
  sed -e 's/value: "10"/value: "100"/' -e "s/value: \"60s\"/value: \"${K6_MIN}m\"/" load/k6-job.yaml | kubectl apply -f - >/dev/null
  say "k6 started: 100 req/s for ${K6_MIN} min"
fi
