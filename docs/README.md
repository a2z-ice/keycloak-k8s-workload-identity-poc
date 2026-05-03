# POC: Keycloak Token Exchange + Kubernetes Workload Identity — Documentation

> A hands-on, fully-tested POC showing how a Spring Boot pod can use a
> Kubernetes-issued service account token to obtain a scoped Keycloak access
> token and call another pod's REST API — with audience binding, RBAC, and
> structured audit logs.

**Status:** ✅ End-to-end pipeline works on a fresh `poc-cluster` kind cluster.
**Tests:** ✅ 45 / 45 Playwright tests pass on chromium baseline.

---

## How this folder is organised

| # | Document | What's inside |
|---|---|---|
| [01](./01-overview.md) | **Overview — Problem & Solution** | Why workload identity matters, what this POC demonstrates, business value, code references |
| [02](./02-architecture.md) | **Architecture (interactive Mermaid)** | System diagram, sequence diagrams, component responsibilities |
| [03](./03-setup-guide.md) | **Setup Guide — step-by-step** | Prerequisites → fresh kind cluster → Keycloak → realm → pods → smoke test, with screenshots |
| [04](./04-keycloak-configuration.md) | **Keycloak Configuration walkthrough** | Annotated tour of every realm artefact, with admin-UI screenshots |
| [05](./05-manual-testing-guide.md) | **Manual Testing Guide** | curl-based scenarios, JWT inspection, RBAC negative tests, expected outputs |
| [06](./06-code-walkthrough.md) | **Code Walkthrough** | Annotated tour of pod-a + pod-b source with file:line references |
| [07](./07-troubleshooting.md) | **Troubleshooting** | Symptoms → root causes → fixes, drawn from real issues hit during build |

Plus `screenshots/` (20 PNGs captured via Playwright on the live cluster) and
`capture-screenshots.ts` (the Playwright script that produced them — re-run
to refresh after a Keycloak version bump or UI change).

---

## TL;DR — 90-second tour

```bash
# 1. Bootstrap (creates kind cluster + Keycloak + builds Spring Boot images +
#    deploys pods + smoke-tests the full flow). Takes ~5 min on a cold cache.
./scripts/00-setup-all.sh

# 2. Run the 45-test Playwright suite
./scripts/08-run-e2e.sh

# 3. Manual probe
curl -sf http://127.0.0.1:30810/api/health        # pod-a healthy
curl -sf http://127.0.0.1:30820/api/health        # pod-b healthy
TOKEN=$(curl -sf -X POST http://127.0.0.1:30810/api/exchange | jq -r .accessToken)
curl -sf -H "Authorization: Bearer $TOKEN" http://127.0.0.1:30820/api/protected/data | jq .

# 4. Tear down everything (deletes the dedicated kind cluster)
./scripts/99-cleanup.sh
```

After bootstrap, the Keycloak admin UI is at **http://127.0.0.1:30888**
(`admin / admin`).

---

## Where to start reading

* New to the problem? → [01-overview.md](./01-overview.md)
* "How does this thing work?" → [02-architecture.md](./02-architecture.md)
* "Get me running" → [03-setup-guide.md](./03-setup-guide.md)
* "Let me poke the Keycloak UI" → [04-keycloak-configuration.md](./04-keycloak-configuration.md)
* "Show me how to test it manually" → [05-manual-testing-guide.md](./05-manual-testing-guide.md)
* "What does the code actually do?" → [06-code-walkthrough.md](./06-code-walkthrough.md)
* Stuck? → [07-troubleshooting.md](./07-troubleshooting.md)

---

## Key URLs

| Service | URL | Notes |
|---|---|---|
| POC Keycloak admin | http://127.0.0.1:30888 | admin / admin (H2 in-memory; resets on restart) |
| Pod A | http://127.0.0.1:30810 | Spring Boot — `/api/health`, `/api/exchange`, `/api/call-pod-b`, `/api/oidc/token-info` |
| Pod B | http://127.0.0.1:30820 | Spring Boot resource server — `/api/health`, `/api/public/info`, `/api/protected/data`, `/api/protected/create` |
| OIDC discovery | http://127.0.0.1:30888/realms/poc-realm/.well-known/openid-configuration | Standard OIDC well-known |
| JWKS | http://127.0.0.1:30888/realms/poc-realm/protocol/openid-connect/certs | RS256 public keys for token verification |

---

## The cluster name is `poc-cluster`

Throughout the docs, **all kubectl/kind commands target the `poc-cluster`
kind cluster created from
[`../poc-cluster-config.yaml`](../poc-cluster-config.yaml).** This cluster is
created and destroyed by the bootstrap/cleanup scripts and is fully isolated
from any other kind cluster on your machine.
