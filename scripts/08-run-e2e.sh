#!/usr/bin/env bash
# Run the Playwright e2e suite (45 tests, chromium baseline).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}/kubernetes/e2e-tests"

if [[ ! -d node_modules ]]; then
  echo "==> Installing npm deps..."
  npm ci
fi

if [[ ! -f .env.local ]]; then
  echo "==> Creating .env.local from example..."
  cp .env.local.example .env.local
fi

echo "==> Installing Playwright browsers (chromium)..."
npx playwright install chromium

echo "==> Running Playwright e2e..."
exec npx playwright test --project=chromium "$@"
