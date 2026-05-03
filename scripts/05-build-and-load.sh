#!/usr/bin/env bash
# Build pod-a + pod-b Docker images and load them into the kind cluster.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-poc-cluster}"
echo "==> kind cluster: ${CLUSTER_NAME}"

build_and_load() {
  local APP="$1"
  local TAG="$2"
  echo ""
  echo "==> Building ${APP} image -> ${TAG}"
  docker build --tag "${TAG}" "${REPO_ROOT}/kubernetes/${APP}"

  echo "==> Loading ${TAG} into kind cluster '${CLUSTER_NAME}'"
  kind load docker-image "${TAG}" --name "${CLUSTER_NAME}"
}

build_and_load pod-a pod-a:latest
build_and_load pod-b pod-b:latest

echo ""
echo "==> Built images:"
docker images | head -1
docker images | grep -E '^pod-[ab] ' | head -5
