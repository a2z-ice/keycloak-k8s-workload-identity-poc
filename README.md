# Keycloak ↔ Kubernetes Workload Identity POC

A working, fully-tested proof-of-concept showing how a Spring Boot pod can
authenticate to **Keycloak**, obtain a scoped, audience-bound, role-bearing
access token, and call another pod's REST API — with RBAC, token caching,
audit logging, and a 45-test Playwright suite.

[![POC e2e](https://img.shields.io/badge/playwright-45%2F45_passing-brightgreen)](e2e-tests/)
[![Spring Boot](https://img.shields.io/badge/spring--boot-3.2-6DB33F)](pod-a/pom.xml)
[![Keycloak](https://img.shields.io/badge/keycloak-26.5.3-orange)](k8s-manifests/poc-keycloak/02-deployment.yaml)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

> **🚨 POC defaults inside.** Hardcoded `admin/admin`, `pod-a-secret`,
> `pod-b-secret`. Do **not** deploy as-is to anything reachable. See
> [SECURITY.md](./SECURITY.md).

---

## What this demonstrates

A two-pod system where **pod-a calls pod-b's protected REST API using a
short-lived Keycloak-issued JWT** — no shared static secrets between the
pods, RBAC enforced server-side, every protected request audit-logged.

```
┌──────── pod-a (Spring Boot) ────────┐         ┌──────── pod-b (Spring Boot) ──────┐
│ Mounted K8s SA token (workload ID)  │         │ OAuth2 Resource Server            │
│ Authenticates to Keycloak via       │         │ Validates JWT via Keycloak JWKS   │
│ client_credentials grant            │ Bearer  │ @PreAuthorize(hasRole("data-...")) │
│ Caches access token (5 min TTL)     │ ──────► │ Structured audit log per request  │
│ Refreshes every 4 min               │         │                                   │
└─────────────────────────────────────┘         └───────────────────────────────────┘
                  │ ▲
                  ▼ │
          ┌──────────────────┐
          │ POC Keycloak 26  │
          │ realm: poc-realm │
          │ roles: data-…    │
          └──────────────────┘
                 (in a dedicated kind cluster: poc-cluster)
```

The original spec ([`spec.md`](./spec.md)) targeted RFC 8693 *external-to-internal
token exchange* using the K8s SA JWT as the `subject_token`. The as-built
implementation pivots to `client_credentials` because Keycloak 26.5's V1
external-IdW broker path has known issues with K8s SA tokens — the mounted
SA token is still inspectable on `pod-a` (`/api/oidc/token-info`) and
ready to feed into a sidecar or Keycloak's `standard-token-exchange-v2` once
that stabilises. See [`docs/01-overview.md`](./docs/01-overview.md#architectural-pivots-made-during-build).

---

## Quick start

```bash
# Prereqs: Docker, kind ≥ 0.22, kubectl ≥ 1.28, Node ≥ 18, curl, jq, python3

# 1. Bootstrap the whole stack from a fresh kind cluster
./scripts/00-setup-all.sh

# 2. Run the 45-test Playwright suite
./scripts/08-run-e2e.sh

# 3. Tear it all down (deletes the dedicated poc-cluster)
./scripts/99-cleanup.sh
```

`00-setup-all.sh` runs ~3 min warm / ~7 min cold-cache. It:

1. Creates the `poc-cluster` kind cluster ([`poc-cluster-config.yaml`](./poc-cluster-config.yaml))
2. Deploys POC Keycloak (`KC_FEATURES=token-exchange:v1,admin-fine-grained-authz:v1`)
3. Applies the JWKS-discovery RBAC binding
4. Builds `pod-a` + `pod-b` Docker images via multi-stage Maven Dockerfiles, loads them into kind
5. Configures the `poc-realm` (clients, roles, audience mapper, SA-user role assignment) via Keycloak admin REST
6. Deploys the pods with projected SA token volumes
7. Smoke-tests the end-to-end flow (`curl`)

Browser endpoints after bootstrap:

| Service | URL | Notes |
|---|---|---|
| POC Keycloak admin | http://127.0.0.1:30888 | `admin / admin` (POC default) |
| pod-a              | http://127.0.0.1:30810 | `/api/health`, `/api/exchange`, `/api/call-pod-b`, `/api/oidc/token-info` |
| pod-b              | http://127.0.0.1:30820 | `/api/health`, `/api/public/info`, `/api/protected/data`, `/api/protected/create` |

---

## Layout

```
.
├── README.md, LICENSE, SECURITY.md      # repo top-level
├── spec.md                              # original POC spec (foundation)
├── E2E_TESTING_QUICK_REFERENCE.md       # the 45-test playbook
├── poc-cluster-config.yaml              # kind config — single node, NodePorts mapped
├── scripts/
│   ├── 00-setup-all.sh                  # one-shot bootstrap
│   ├── 01-create-cluster.sh             # kind create cluster
│   ├── 02-deploy-poc-keycloak.sh        # apply Keycloak manifests + wait
│   ├── 03-jwks-discovery-rbac.sh        # ClusterRoleBinding for /openid/v1/jwks
│   ├── 04-setup-poc-realm.sh            # realm + clients + roles + mappers via REST
│   ├── 05-build-and-load.sh             # docker build → kind load
│   ├── 06-deploy-pods.sh                # apply pod-a + pod-b manifests
│   ├── 07-test-flow.sh                  # curl-based smoke test
│   ├── 08-run-e2e.sh                    # Playwright e2e
│   └── 99-cleanup.sh                    # kind delete cluster
├── pod-a/                               # Spring Boot 3.2 / Java 17 / Maven — token exchanger
├── pod-b/                               # Spring Boot 3.2 / Java 17 / Maven — resource server
├── k8s-manifests/
│   ├── 00-jwks-rbac.yaml
│   ├── poc-keycloak/                    # namespace + deployment + service
│   └── poc/                             # namespace + SAs + pod deployments + services
├── e2e-tests/                           # Playwright + TypeScript (7 specs, 45 tests)
├── docs/                                # 8 markdown files + 20 admin-UI screenshots
│   ├── README.md                        # docs index
│   ├── 01-overview.md
│   ├── 02-architecture.md               # 5 interactive Mermaid diagrams
│   ├── 03-setup-guide.md
│   ├── 04-keycloak-configuration.md
│   ├── 05-manual-testing-guide.md
│   ├── 06-code-walkthrough.md
│   ├── 07-troubleshooting.md
│   ├── capture-screenshots.ts           # Playwright script that produced the screenshots
│   └── screenshots/                     # 20 PNGs from the live admin UI
└── plans/9-poc-...md                    # design history
```

---

## Documentation

The [`docs/`](./docs) folder is the recommended reading path:

* [`docs/README.md`](./docs/README.md) — index
* [`docs/01-overview.md`](./docs/01-overview.md) — problem & solution
* [`docs/02-architecture.md`](./docs/02-architecture.md) — interactive Mermaid diagrams
* [`docs/03-setup-guide.md`](./docs/03-setup-guide.md) — annotated bootstrap walkthrough
* [`docs/04-keycloak-configuration.md`](./docs/04-keycloak-configuration.md) — admin-UI tour with screenshots
* [`docs/05-manual-testing-guide.md`](./docs/05-manual-testing-guide.md) — 10 hands-on test scenarios
* [`docs/06-code-walkthrough.md`](./docs/06-code-walkthrough.md) — annotated source tour
* [`docs/07-troubleshooting.md`](./docs/07-troubleshooting.md) — symptoms → root causes → fixes

---

## Test summary

```
45 / 45 passing on chromium baseline (~1.5 s)
```

| Suite | File | Cases | Focus |
|---|---|---|---|
| Token exchange | [`e2e-tests/tests/01-token-exchange.spec.ts`](./e2e-tests/tests/01-token-exchange.spec.ts) | 6 | health, exchange, claims, S2S |
| Authorization | [`e2e-tests/tests/02-authorization.spec.ts`](./e2e-tests/tests/02-authorization.spec.ts) | 7 | RBAC, public/protected |
| Token refresh | [`e2e-tests/tests/03-token-refresh.spec.ts`](./e2e-tests/tests/03-token-refresh.spec.ts) | 6 | TTL, cache, concurrency |
| Failure / recovery | [`e2e-tests/tests/04-failure-recovery.spec.ts`](./e2e-tests/tests/04-failure-recovery.spec.ts) | 6 | malformed/tampered tokens, audit log |
| Service integration | [`e2e-tests/tests/05-service-integration.spec.ts`](./e2e-tests/tests/05-service-integration.spec.ts) | 6 | identity preservation |
| OIDC binding | [`e2e-tests/tests/06-oidc-binding.spec.ts`](./e2e-tests/tests/06-oidc-binding.spec.ts) | 7 | mounted token, K8s metadata |
| Performance | [`e2e-tests/tests/07-performance.spec.ts`](./e2e-tests/tests/07-performance.spec.ts) | 7 | latency SLAs, load |

---

## Future plans

Roadmap-as-plan-files in [`plans/`](./plans/):

| Plan | Status | Scope |
|---|---|---|
| 9 — POC implementation | ✅ Done | This repo |
| 10 — Security hardening | Open | TLS for POC Keycloak, mTLS pod↔Keycloak, NetworkPolicies |
| 11 — Persistence | Open | PostgreSQL backend; realm import via `--import-realm` |
| 12 — Standard token-exchange v2 | Open | Once Keycloak's V2 external exchange stabilises, drop client_credentials |
| 13 — GitOps | Open | ArgoCD ApplicationSet + image automation |
| 14 — Sidecar token manager | Open | Refactor pod-a's caching into a sidecar |
| 15 — Observability | Open | Prometheus, Grafana, OpenTelemetry traces |

---

## License

[MIT](./LICENSE) — copy, fork, learn from.
