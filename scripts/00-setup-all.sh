#!/usr/bin/env bash
# Orchestrator: full POC bootstrap from scratch on a fresh kind cluster.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "########################################"
echo "# POC bootstrap (token exchange POC)   #"
echo "# kind cluster:  poc-cluster           #"
echo "########################################"

echo ""; echo "### [1/7] Create kind cluster"
bash "${DIR}/01-create-cluster.sh"

echo ""; echo "### [2/7] Deploy POC Keycloak"
bash "${DIR}/02-deploy-poc-keycloak.sh"

echo ""; echo "### [3/7] JWKS discovery RBAC"
bash "${DIR}/03-jwks-discovery-rbac.sh"

echo ""; echo "### [4/7] Build pod-a + pod-b images"
bash "${DIR}/05-build-and-load.sh"

echo ""; echo "### [5/7] Configure poc-realm"
bash "${DIR}/04-setup-poc-realm.sh"

echo ""; echo "### [6/7] Deploy pod-a + pod-b"
bash "${DIR}/06-deploy-pods.sh"

echo ""; echo "### [7/7] Smoke test"
bash "${DIR}/07-test-flow.sh"

echo ""
echo "########################################"
echo "# POC ready.                           #"
echo "# Run e2e:    scripts/08-run-e2e.sh   #"
echo "# Cleanup:    scripts/99-cleanup.sh   #"
echo "########################################"
