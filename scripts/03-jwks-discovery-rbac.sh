#!/usr/bin/env bash
# Apply the ClusterRoleBinding that lets unauthenticated callers (i.e. POC Keycloak
# fetching from in-cluster) access the K8s API's /openid/v1/jwks discovery endpoint.
# Idempotent: safe to re-run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "==> Applying JWKS discovery RBAC..."
kubectl apply -f "${REPO_ROOT}/kubernetes/k8s-manifests/00-jwks-rbac.yaml"

echo "==> Verifying JWKS endpoint reachable from inside the cluster..."
# The Keycloak 26 image is distroless and lacks curl, so spin up a tiny
# alpine/curl pod in the poc-keycloak namespace and curl the discovery URL.
KEYS=$(kubectl -n poc-keycloak run jwks-probe --rm -i --quiet --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -sk https://kubernetes.default.svc.cluster.local/openid/v1/jwks 2>/dev/null \
  | tr -d '\r' | grep -oE '"kid"' | wc -l | tr -d ' ')

if [[ "${KEYS}" -gt 0 ]]; then
  echo "    JWKS endpoint reachable; ${KEYS} key(s) returned."
else
  echo "ERROR: JWKS endpoint not reachable from inside the cluster" >&2
  exit 1
fi
