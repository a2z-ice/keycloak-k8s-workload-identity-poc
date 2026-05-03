#!/usr/bin/env bash
# Create the dedicated POC kind cluster from poc-cluster-config.yaml.
# Idempotent: if the cluster already exists, this script is a no-op.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="${REPO_ROOT}/kubernetes/poc-cluster-config.yaml"
CLUSTER_NAME="poc-cluster"

echo "==> Checking for existing kind cluster '${CLUSTER_NAME}'..."
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "    Cluster already exists; skipping create."
else
  echo "==> Creating kind cluster '${CLUSTER_NAME}' from ${CONFIG}..."
  kind create cluster --name "${CLUSTER_NAME}" --config "${CONFIG}"
fi

echo "==> Switching kubectl context to kind-${CLUSTER_NAME}..."
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

echo "==> Cluster info:"
kubectl cluster-info | head -3

echo "==> Nodes:"
kubectl get nodes -o wide
