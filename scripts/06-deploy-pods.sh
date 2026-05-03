#!/usr/bin/env bash
# Deploy pod-a + pod-b into the 'poc' namespace.
# Host ports 30810 / 30820 are exposed by kind extraPortMappings (no socat).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST_DIR="${REPO_ROOT}/kubernetes/k8s-manifests/poc"
NS=poc

echo "==> Applying poc namespace + manifests..."
kubectl apply -f "${MANIFEST_DIR}/01-namespace.yaml"
kubectl apply -f "${MANIFEST_DIR}/02-service-accounts.yaml"
kubectl apply -f "${MANIFEST_DIR}/03-pod-a-deployment.yaml"
kubectl apply -f "${MANIFEST_DIR}/04-pod-a-service.yaml"
kubectl apply -f "${MANIFEST_DIR}/05-pod-b-deployment.yaml"
kubectl apply -f "${MANIFEST_DIR}/06-pod-b-service.yaml"

# Force a rollout so freshly-loaded images replace any older cached ones
# (kind load swaps the image bits, but a Deployment with the same image
# reference does not roll on its own).
echo "==> Restarting deployments to pick up freshly-loaded images..."
kubectl -n "${NS}" rollout restart deploy/pod-a
kubectl -n "${NS}" rollout restart deploy/pod-b

echo "==> Waiting for pod-a..."
kubectl -n "${NS}" rollout status deployment/pod-a --timeout=300s
echo "==> Waiting for pod-b..."
kubectl -n "${NS}" rollout status deployment/pod-b --timeout=300s

echo "==> Probing host ports..."
for PORT in 30810 30820; do
  for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
      echo "    :${PORT} OK"
      break
    fi
    sleep 2
  done
done

echo ""
echo "==> Pods deployed and reachable:"
echo "    pod-a:  http://127.0.0.1:30810"
echo "    pod-b:  http://127.0.0.1:30820"
