#!/usr/bin/env bash
# Tear down the POC entirely: delete the dedicated kind cluster.
# Because the POC owns its cluster, this is destructive only to POC state —
# the parent repo's kind cluster (Student-Mgmt) is untouched.
set -euo pipefail

CLUSTER_NAME="poc-cluster"

echo "==> Deleting kind cluster '${CLUSTER_NAME}'..."
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  kind delete cluster --name "${CLUSTER_NAME}"
else
  echo "    (cluster does not exist; nothing to delete)"
fi

# Best-effort: remove any leftover socat proxies from older POC runs.
docker rm -f pod-a-proxy pod-b-proxy poc-keycloak-proxy 2>/dev/null || true

echo "==> Cleanup complete."
echo "    Existing 'kind' / 'aauth' Student-Mgmt cluster is untouched."
