#!/usr/bin/env bash
# Deploy the dedicated POC Keycloak into the poc-cluster kind cluster.
# Host port is mapped via kind extraPortMappings (no socat needed).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST_DIR="${REPO_ROOT}/kubernetes/k8s-manifests/poc-keycloak"
NS=poc-keycloak
HOST_PORT=30888

echo "==> Verifying kubectl context..."
ctx=$(kubectl config current-context)
if [[ "${ctx}" != "kind-poc-cluster" ]]; then
  echo "WARN: current context is '${ctx}', expected 'kind-poc-cluster'."
  echo "      Run scripts/01-create-cluster.sh first."
fi

echo "==> Applying namespace + Deployment + Service..."
kubectl apply -f "${MANIFEST_DIR}/01-namespace.yaml"
kubectl apply -f "${MANIFEST_DIR}/02-deployment.yaml"
kubectl apply -f "${MANIFEST_DIR}/03-service.yaml"

echo "==> Waiting for poc-keycloak rollout..."
kubectl -n "${NS}" rollout status deployment/poc-keycloak --timeout=300s

echo "==> Waiting for /health/ready inside the pod..."
for i in $(seq 1 60); do
  if kubectl -n "${NS}" exec deploy/poc-keycloak -- curl -sf http://127.0.0.1:9000/health/ready >/dev/null 2>&1; then
    echo "    Keycloak ready."
    break
  fi
  echo "    not yet ($i)..."
  sleep 3
done

echo "==> Probing host port :${HOST_PORT} (NodePort published via kind extraPortMappings)..."
for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:${HOST_PORT}/realms/master/.well-known/openid-configuration" >/dev/null 2>&1; then
    echo "    Host port reachable: http://127.0.0.1:${HOST_PORT}"
    break
  fi
  sleep 2
done

echo "==> POC Keycloak deployed."
echo "    Namespace:   ${NS}"
echo "    In-cluster:  http://poc-keycloak.${NS}.svc.cluster.local:8080"
echo "    Host:        http://127.0.0.1:${HOST_PORT}"
echo "    Admin:       admin / admin"
