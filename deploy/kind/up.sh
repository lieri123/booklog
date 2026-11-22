#!/usr/bin/env bash
# Build Booklog, bring up a kind cluster, install the chart, smoke test it.
# Idempotent: safe to re-run after a code change (rebuilds and rolls out).
#
#   bash deploy/kind/up.sh
#
# Requires docker, kind, kubectl and helm on PATH.
set -euo pipefail

CLUSTER=booklog
RELEASE=booklog
NS=booklog
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }

for bin in docker kind kubectl helm; do
  command -v "$bin" >/dev/null || { echo "missing $bin on PATH" >&2; exit 1; }
done

step "Cluster"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "kind cluster '$CLUSTER' already exists"
else
  kind create cluster --config deploy/kind/cluster.yaml
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

step "Zone labels"
# Fake zones so topologySpreadConstraints has a real topology key to work with.
i=0
for node in $(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name); do
  zone=$([ $i -eq 0 ] && echo "ca-central-1a" || echo "ca-central-1b")
  kubectl label "$node" "topology.kubernetes.io/zone=$zone" --overwrite >/dev/null
  echo "  ${node#node/} -> $zone"
  i=$((i+1))
done

step "metrics-server (the HPA cannot scale without it)"
if ! kubectl get deploy metrics-server -n kube-system >/dev/null 2>&1; then
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  # kind's kubelet serving certs are self-signed; metrics-server rejects them
  # by default and reports every pod as <unknown>, which silently disables the
  # HPA. This is the single most common reason an HPA never scales on kind.
  kubectl patch deploy metrics-server -n kube-system --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi
kubectl rollout status deploy/metrics-server -n kube-system --timeout=180s

step "Image"
docker build -t booklog:local .
kind load docker-image booklog:local --name "$CLUSTER"

step "Install"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install "$RELEASE" deploy/helm/booklog \
  --namespace "$NS" \
  --values deploy/kind/values-kind.yaml \
  --atomic --wait --timeout 6m

step "Status"
kubectl get deploy,pod,hpa,svc -n "$NS"

step "Metrics (HPA needs a non-<unknown> TARGETS column)"
for i in $(seq 1 20); do
  t=$(kubectl get hpa "$RELEASE" -n "$NS" -o jsonpath='{.status.currentMetrics}' 2>/dev/null || true)
  [ -n "$t" ] && [ "$t" != "null" ] && break
  sleep 6
done
kubectl get hpa -n "$NS"

step "Smoke test via NodePort (host:8080)"
bash scripts/smoke.sh http://127.0.0.1:8080

cat <<EOF

Ready. The service is on http://127.0.0.1:8080 (NodePort 30080, mapped by kind).

Load test:
  # terminal 1
  bash deploy/scripts/watch-hpa.sh $RELEASE $NS
  # terminal 2
  k6 run -e BASE_URL=http://127.0.0.1:8080 loadtest/load.js

Tear down:
  bash deploy/kind/down.sh
EOF
