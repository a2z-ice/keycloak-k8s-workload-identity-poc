# Plan 9 — POC: Keycloak Token Exchange + Kubernetes Workload Identity (Spring Boot)

> **Final filename on execution:** `plans/9-poc-keycloak-token-exchange-spring-boot.md`
> **Source spec:** `spec.md` (v1.0, May 2026)
> **E2E reference:** `E2E_TESTING_QUICK_REFERENCE.md` (45 tests across 7 suites)
> **POC root directory:** `` (current working dir)
> **Numbering:** Plans 1–8 exist (Student-Mgmt history). This is plan **9**, the first POC plan. Future enhancements continue at 10, 11, … using the same `N-kebab-case.md` convention.

---

## Context

The existing repo (Student Management System) demonstrates **user-centric** OAuth2.1 with Keycloak. This **new POC** demonstrates a different identity pattern — **workload identity** — where one pod proves *its own* identity to another pod via a chained trust:

1. The kind API server issues a Kubernetes-signed OIDC JWT to `pod-a` (mounted at `/var/run/secrets/tokens/jwt.token`, audience `keycloak-poc`).
2. `pod-a` POSTs that JWT to its **dedicated POC Keycloak** using grant `urn:ietf:params:oauth:grant-type:token-exchange` (RFC 8693).
3. POC Keycloak validates the JWT against the cluster's JWKS, looks up roles for the SA, and returns a Keycloak-signed access token (audience `pod-b`).
4. `pod-a` calls `pod-b` with that bearer token. `pod-b` validates via the POC Keycloak's JWKS and enforces `data-reader` / `data-writer` RBAC.

**Why now / why this shape:**
- No shared static secrets in pods (the OIDC token is ephemeral, ~5 min, signed by the cluster CA).
- Audience-scoped tokens, fully auditable.
- **One kind cluster only** — uses the existing `kind` cluster; no new cluster created.
- **Dedicated POC Keycloak** in a separate `poc-keycloak` namespace — the existing Student-Mgmt Keycloak StatefulSet (namespace `keycloak`) is **not touched**, not reconfigured, not restarted. Independent realm, independent feature flags, independent lifecycle.

**Architecture**

```
┌── existing kind cluster (single, unchanged) ────────────────────────┐
│                                                                      │
│ ns: keycloak (UNTOUCHED)                                             │
│   keycloak-0/1/2  StatefulSet — student-mgmt realm only              │
│                                                                      │
│ ns: poc-keycloak (NEW, isolated)                                     │
│   poc-keycloak  Deployment, 1 replica                                │
│     image: quay.io/keycloak/keycloak:26.5.3                          │
│     start-dev, H2 in-memory DB, HTTP only (POC)                      │
│     KC_FEATURES=token-exchange,admin-fine-grained-authz              │
│   Service: poc-keycloak (ClusterIP :8080)                            │
│   realm: poc-realm                                                   │
│     IdP "kubernetes" → issuer https://kubernetes.default.svc         │
│                          jwks_uri https://kubernetes.default.svc/    │
│                                       openid/v1/jwks                 │
│     clients: pod-a (public, token-exchange permission enabled)       │
│              pod-b (confidential, audience mapper)                   │
│     roles: data-reader, data-writer                                  │
│                                                                      │
│ ns: poc (NEW)                                                        │
│   pod-a Deployment (Spring Boot 3.2, port 8081)                      │
│     ENV: KEYCLOAK_URL=http://poc-keycloak.poc-keycloak.svc:8080      │
│     vol: projected SA token, audience=keycloak-poc, exp=3600         │
│   pod-b Deployment (Spring Boot 3.2, port 8082)                      │
│     ENV: SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI=       │
│            http://poc-keycloak.poc-keycloak.svc:8080/realms/poc-realm│
│                                                                      │
│ cluster-level                                                        │
│   ClusterRoleBinding: system:service-account-issuer-discovery        │
│     subject: system:unauthenticated (lets POC Keycloak fetch JWKS    │
│     from the K8s API without a bearer token — many kind versions     │
│     ship this; we apply it idempotently)                             │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

Host access (for tests + manual smoke) via socat Docker proxies on the
existing "kind" Docker network (same pattern as existing argocd-http-proxy):
    127.0.0.1:30810 → pod-a:30810 → ClusterIP pod-a:8081
    127.0.0.1:30820 → pod-b:30820 → ClusterIP pod-b:8082
    127.0.0.1:30888 → poc-keycloak:30888 → ClusterIP poc-keycloak:8080
```

**Key consequence of single-cluster design:** JWKS validation happens entirely inside the cluster via the in-cluster `kubernetes.default.svc` service — no cross-cluster networking, no certificate juggling between clusters, no `host.docker.internal`. The plan is **substantially simpler** than the original draft.

---

## Scope of this plan

**Included (full POC + complete E2E suite):**
- A dedicated POC Keycloak Deployment + Service + ConfigMap + realm-setup Job in namespace `poc-keycloak`. Started with `KC_FEATURES=token-exchange,admin-fine-grained-authz` from the first boot — no flag flip on existing infra.
- Realm `poc-realm` configured via REST script (clone of `keycloak/realm-config/realm-setup.sh`):
  - clients `pod-a` (public, token-exchange permission policy) and `pod-b` (confidential, audience mapper)
  - realm roles `data-reader`, `data-writer`
  - Identity Provider type `keycloak-oidc` (or `oidc`) named `kubernetes`, issuer `https://kubernetes.default.svc.cluster.local`, JWKS URL `https://kubernetes.default.svc.cluster.local/openid/v1/jwks`
  - role mapper: SA subjects matching `system:serviceaccount:poc:pod-a` → grant both roles
- Spring Boot 3.2 / Java 17 / **Maven** projects for `pod-a` (token exchanger) and `pod-b` (resource server) per spec §5, with Resilience4j circuit breaker and Micrometer metrics. Source largely lifted from spec §5.1–5.2.
- Kubernetes manifests (namespaces, ServiceAccounts, Deployments, Services, projected SA token volume, ClusterRoleBinding for JWKS discovery) per spec §6 (adapted to in-cluster Keycloak URL).
- Build + load script: `mvn package` → `docker build` → `kind load docker-image --name kind` (extends existing pattern from `scripts/build-test-deploy.sh`).
- Smoke test script `scripts/test-flow.sh` (curl-based happy path, per spec §7.1).
- **Full 45-test Playwright suite** in `e2e-tests/` (TypeScript) covering all 7 suites listed in `E2E_TESTING_QUICK_REFERENCE.md`. NodePort access via socat proxies.
- socat Docker-proxy setup script for host-side NodePort exposure (matches existing `argocd-http-proxy` pattern documented in CLAUDE.md — no recreation of the kind cluster, no edits to `cluster/kind-config.yaml`).
- Cleanup script that deletes namespaces `poc`, `poc-keycloak`, the ClusterRoleBinding, and the socat proxies.

**Explicitly out of scope (deferrable to plans 10+):**
- mTLS pod ↔ Keycloak (spec §8 hardening) — the POC Keycloak runs HTTP, sufficient for in-cluster + local POC.
- Persistent DB for POC Keycloak — H2 in-memory is fine; realm is recreated on each setup.
- NetworkPolicies, multi-cluster federation, sidecar token manager.
- ArgoCD/GitOps integration for the POC (existing GitOps targets Student-Mgmt only).
- Production Keycloak deployment changes (HA, persistence tuning).
- Docker-compose alternative (spec mentions it; we ship k8s-only).

---

## Final project layout (under ``)

```
kubernetes/
├── spec.md                           # already exists (read-only reference)
├── E2E_TESTING_QUICK_REFERENCE.md    # already exists (read-only reference)
├── README.md                         # NEW — quickstart + architecture summary
│
├── scripts/
│   ├── 00-setup-all.sh               # Orchestrator: runs every 0N-* in order
│   ├── 01-deploy-poc-keycloak.sh     # apply k8s-manifests/poc-keycloak/*
│   │                                 #   wait for poc-keycloak Ready
│   │                                 #   start socat proxy for :30888
│   ├── 02-jwks-discovery-rbac.sh     # apply k8s-manifests/00-jwks-rbac.yaml
│   │                                 #   verify Keycloak pod can curl
│   │                                 #   https://kubernetes.default.svc/openid/v1/jwks
│   ├── 03-setup-poc-realm.sh         # REST-API style (clone of
│   │                                 #   keycloak/realm-config/realm-setup.sh):
│   │                                 #   create realm poc-realm
│   │                                 #   create client pod-a (public,
│   │                                 #     token-exchange permission policy)
│   │                                 #   create client pod-b (confidential,
│   │                                 #     audience mapper)
│   │                                 #   create roles data-reader, data-writer
│   │                                 #   create Identity Provider "kubernetes"
│   │                                 #     issuer=https://kubernetes.default.svc
│   │                                 #     jwksUrl=…/openid/v1/jwks
│   │                                 #     validateSignature=true
│   │                                 #   token-exchange permission policy:
│   │                                 #     pod-a may exchange for audience=pod-b
│   │                                 #   role mapper: subject startsWith
│   │                                 #     "system:serviceaccount:poc:pod-a"
│   │                                 #     → grant data-reader, data-writer
│   ├── 04-build-and-load.sh          # mvn -pl pod-a,pod-b package
│   │                                 #   docker build pod-a → kind load --name kind
│   │                                 #   docker build pod-b → kind load --name kind
│   ├── 05-deploy-pods.sh             # kubectl apply -f k8s-manifests/poc/
│   │                                 #   wait for rollout
│   │                                 #   start socat proxies for :30810, :30820
│   ├── 06-test-flow.sh               # spec §7.1 curl smoke test
│   │                                 #   (NodePorts 30810/30820 via socat)
│   ├── 07-run-e2e.sh                 # cd e2e-tests && npm ci &&
│   │                                 #   npx playwright test
│   └── 99-cleanup.sh                 # kubectl delete ns poc poc-keycloak
│                                     #   delete ClusterRoleBinding
│                                     #   docker rm -f pod-a-proxy
│                                     #     pod-b-proxy poc-keycloak-proxy
│
├── pod-a/                            # Spring Boot 3.2, Java 17, Maven
│   ├── pom.xml                       # deps per spec §5.1.1: web, cloud-kubernetes-client,
│   │                                 #   security-oauth2-client, resilience4j, micrometer, lombok
│   ├── Dockerfile                    # multi-stage:
│   │                                 #   maven:3.9-eclipse-temurin-17 (build) →
│   │                                 #   eclipse-temurin:17-jre (runtime)
│   ├── src/main/java/com/example/poda/
│   │   ├── PodAApplication.java
│   │   ├── config/SecurityConfig.java
│   │   ├── config/RestTemplateConfig.java
│   │   ├── service/OidcTokenProvider.java   # spec §5.1.2 (verbatim)
│   │   ├── service/TokenExchangeService.java# spec §5.1.3 (verbatim,
│   │   │                                    #   with @CircuitBreaker)
│   │   ├── service/TokenCacheManager.java   # spec §5.1.4 (verbatim,
│   │   │                                    #   RW-locked cache)
│   │   ├── controller/TokenController.java  # spec §5.1.5 (verbatim):
│   │   │                                    #   /health, /api/tokens/current,
│   │   │                                    #   /api/exchange, /api/call-pod-b
│   │   └── scheduler/TokenRefreshScheduler.java # @Scheduled every 4 min
│   └── src/main/resources/
│       ├── application.yml           # spec §5.1.6 with values:
│       │                             #   keycloak.server-url: http://
│       │                             #     poc-keycloak.poc-keycloak.svc:8080
│       │                             #   keycloak.realm: poc-realm
│       │                             #   keycloak.token-exchange-endpoint:
│       │                             #     ${keycloak.server-url}/realms/
│       │                             #     poc-realm/protocol/openid-connect/token
│       │                             #   keycloak.client-id: pod-a
│       │                             #   keycloak.audience: pod-b
│       └── logback-spring.xml
│
├── pod-b/                            # Spring Boot 3.2, Java 17, Maven
│   ├── pom.xml                       # spring-boot-starter-oauth2-resource-server,
│   │                                 #   security, web, lombok
│   ├── Dockerfile                    # same multi-stage pattern as pod-a
│   ├── src/main/java/com/example/podb/
│   │   ├── PodBApplication.java
│   │   ├── config/SecurityConfig.java       # spec §5.2.1 (verbatim)
│   │   ├── auth/JwtAuthenticationConverter.java  # spec §5.2.2 (verbatim)
│   │   ├── auth/PodIdentityExtractor.java   # extract sub claim
│   │   ├── controller/DataController.java   # spec §5.2.3 (verbatim):
│   │   │                                    #   /health, /api/public/info,
│   │   │                                    #   /api/protected/data,
│   │   │                                    #   /api/protected/create
│   │   ├── service/DataService.java
│   │   └── audit/AuditLogger.java           # spec §5.2.4 (verbatim,
│   │                                        #   structured JSON audit logs)
│   └── src/main/resources/
│       ├── application.yml           # spring.security.oauth2.resourceserver.jwt:
│       │                             #   issuer-uri: http://
│       │                             #     poc-keycloak.poc-keycloak.svc:8080/
│       │                             #     realms/poc-realm
│       │                             #   jwk-set-uri: ${issuer-uri}/protocol/
│       │                             #     openid-connect/certs
│       └── logback-spring.xml
│
├── k8s-manifests/
│   ├── 00-jwks-rbac.yaml             # ClusterRoleBinding so unauthenticated
│   │                                 #   callers can fetch /openid/v1/jwks
│   ├── poc-keycloak/
│   │   ├── 01-namespace.yaml         # ns poc-keycloak
│   │   ├── 02-deployment.yaml        # quay.io/keycloak/keycloak:26.5.3
│   │   │                             #   args: ["start-dev"]
│   │   │                             #   env: KEYCLOAK_ADMIN/KEYCLOAK_ADMIN_PASSWORD
│   │   │                             #     KC_FEATURES=token-exchange,
│   │   │                             #       admin-fine-grained-authz
│   │   │                             #     KC_HTTP_ENABLED=true
│   │   │                             #     KC_HOSTNAME_STRICT=false
│   │   │                             #   resources: 512Mi/1Gi
│   │   │                             #   probes: /health/ready (port 9000)
│   │   ├── 03-service.yaml           # ClusterIP 8080 + NodePort 30888 (admin)
│   │   └── 04-realm-setup-job.yaml   # OPTIONAL — equivalent to running
│   │                                 #   scripts/03-setup-poc-realm.sh
│   │                                 #   in-cluster (image: curlimages/curl,
│   │                                 #   mounts a ConfigMap with the script)
│   └── poc/
│       ├── 01-namespace.yaml         # ns poc
│       ├── 02-service-accounts.yaml  # SA pod-a + SA pod-b in ns poc
│       ├── 03-pod-a-deployment.yaml  # spec §6.2 with projected SA token
│       │                             #   audience=keycloak-poc
│       │                             #   expirationSeconds=3600
│       │                             #   path=jwt.token
│       │                             #   ENV pointing to in-cluster Keycloak svc
│       ├── 04-pod-a-service.yaml     # ClusterIP 8081 + NodePort 30810
│       ├── 05-pod-b-deployment.yaml  # spec §6.3 with in-cluster issuer URI
│       └── 06-pod-b-service.yaml     # ClusterIP 8082 + NodePort 30820
│
└── e2e-tests/                        # full 45-test Playwright suite
    ├── package.json                  # @playwright/test, dotenv,
    │                                 #   jsonwebtoken (decode helper)
    ├── playwright.config.ts          # 3 browsers (chromium, firefox, webkit)
    │                                 #   reporters: html + json + junit
    ├── .env.local.example            # POD_A_URL=http://127.0.0.1:30810
    │                                 #   POD_B_URL=http://127.0.0.1:30820
    │                                 #   KEYCLOAK_URL=http://127.0.0.1:30888
    ├── tsconfig.json
    ├── utils/
    │   ├── api-client.ts             # PodAApiClient + PodBApiClient
    │   │                             #   per quick-ref §"Test Utilities"
    │   └── jwt-helper.ts             # decode JWT payload, assert claims
    └── tests/
        ├── 01-token-exchange.spec.ts        # 6 cases — health, exchange, cache, S2S
        ├── 02-authorization.spec.ts         # 7 cases — public/protected, RBAC
        ├── 03-token-refresh.spec.ts         # 6 cases — expiry, cache, concurrency
        ├── 04-failure-recovery.spec.ts      # 6 cases — timeout, malformed,
        │                                    #   expired, circuit breaker, audit
        ├── 05-service-integration.spec.ts   # 6 cases — Pod A → Pod B,
        │                                    #   identity preservation
        ├── 06-oidc-binding.spec.ts          # 7 cases — token mount, audience,
        │                                    #   K8s metadata
        └── 07-performance.spec.ts           # 7 cases — latency SLAs, concurrency
                                              # = 45 cases total, chromium baseline
```

---

## Critical reused pieces (DO NOT recreate)

| Reuse | Source | Why |
|---|---|---|
| Keycloak realm-setup pattern | `keycloak/realm-config/realm-setup.sh` | Generic curl + admin-token approach; clone & adapt for `poc-realm`, **add token-exchange grant + IdP + permission policy**. |
| Build/load Docker image pattern | `scripts/build-test-deploy.sh` lines 130–144 | Same `docker build` → `kind load docker-image --name kind` recipe; only swap base image to Maven/JRE. |
| socat Docker-proxy NodePort exposure | CLAUDE.md "Critical Gotchas" — `argocd-http-proxy` block | Avoids recreating kind cluster to add port mappings; runs `alpine/socat` containers on the `kind` Docker network bridging host:port → node-internal-IP:nodePort. **Same recipe, just three new ports: 30810, 30820, 30888.** |
| Existing kind cluster | `cluster/kind-config.yaml` (do **not** modify) | Single-cluster mandate; kind-config is left alone, all new exposure done via socat. |

## Critical NEW capabilities (must implement)

1. **Dedicated POC Keycloak with token-exchange enabled at boot.** A 1-replica Deployment (not StatefulSet — the H2 in-memory DB is fine for a POC), `start-dev` mode, HTTP only. The `KC_FEATURES` env enables `token-exchange` and `admin-fine-grained-authz` (the latter is required by Keycloak ≥24 to attach permission policies to the token-exchange grant). **Resource ask: ~512Mi memory, ~250m CPU; pod is up in ~30s.**

2. **JWKS discovery RBAC.** The K8s API's `/openid/v1/jwks` endpoint requires the caller to belong to `system:service-account-issuer-discovery`. We apply a ClusterRoleBinding granting that role to `system:unauthenticated` so POC Keycloak can fetch JWKS without a bearer token. Many kind versions ship this binding already; the script applies idempotently and is harmless if the binding already exists. Verify with:
   ```bash
   kubectl exec -n poc-keycloak deploy/poc-keycloak -- \
     curl -sk https://kubernetes.default.svc.cluster.local/openid/v1/jwks
   ```

3. **Token-exchange permission policy.** Beyond enabling the feature flag, Keycloak ≥24 requires a fine-grained authorization policy: the `pod-a` client must be granted permission to exchange tokens for the `pod-b` audience. This is configured per-client in Keycloak (`Client → Permissions → token-exchange → enable`). The `03-setup-poc-realm.sh` script must create this policy via the Authorization REST API. Without it, exchanges return `403 Forbidden` even with the feature flag — this was the most-cited gotcha in the prior plan iteration.

4. **Projected SA token audience matches IdP issuer expectation.** The `pod-a` Deployment's projected volume requests audience `keycloak-poc`. In the realm IdP config, the expected audience is also `keycloak-poc`. (Spec §6.2 uses bare `keycloak`; we use `keycloak-poc` to avoid any conceptual collision with the existing student-mgmt Keycloak's namespace name.)

5. **Audit-log discovery.** Pod B's `AuditLogger` writes structured JSON to stdout; the E2E suite #04 (failure-recovery, "All access attempts are logged") asserts via `kubectl logs` parsed in TypeScript. The audit format is locked at plan-write time; future test suites can rely on the schema.

---

## Step-by-step execution order

1. Scaffold directory tree under ``. Verify: `tree kubernetes -L 2`.
2. Write `k8s-manifests/poc-keycloak/*` and `scripts/01-deploy-poc-keycloak.sh`. Apply, wait. Verify: `kubectl -n poc-keycloak get pod` shows 1/1 Ready; `curl http://127.0.0.1:30888` (after socat proxy starts) returns the Keycloak welcome page.
3. Write `k8s-manifests/00-jwks-rbac.yaml` and `scripts/02-jwks-discovery-rbac.sh`. Apply. Verify: `kubectl exec -n poc-keycloak deploy/poc-keycloak -- curl -sk https://kubernetes.default.svc.cluster.local/openid/v1/jwks | jq '.keys | length'` returns ≥1.
4. Write `scripts/03-setup-poc-realm.sh` (clone of `keycloak/realm-config/realm-setup.sh`, adapted). Run. Eyeball in admin UI (http://127.0.0.1:30888, admin/admin) that `poc-realm` exists with: 2 clients, 2 realm roles, IdP `kubernetes`, token-exchange permission policy on `pod-a`, role mapper. Run a manual exchange test from inside Keycloak's pod with `curl` to confirm the policy works.
5. Scaffold `pod-a` and `pod-b` Maven projects (source largely copy-paste from spec §5). `cd pod-a && mvn package` and `cd pod-b && mvn package` locally — both produce runnable JARs.
6. Write Dockerfiles. `scripts/04-build-and-load.sh` should produce both images visible to kind: `docker exec -it $(docker ps -qf name=kind-control-plane) crictl images | grep pod-`.
7. Write k8s-manifests under `poc/`. `scripts/05-deploy-pods.sh` deploys; both pods reach Ready; socat proxies for 30810/30820 start.
8. Run `scripts/06-test-flow.sh`. Expected: 200 from `/api/protected/data` with `callerIdentity=system:serviceaccount:poc:pod-a` and roles `[data-reader, data-writer]`.
9. Build the Playwright suite under `e2e-tests/`. Each suite tested independently first, then `07-run-e2e.sh` for the full run. All 45 tests pass on chromium baseline.
10. Document in `README.md`: prerequisites, single-command bootstrap (`scripts/00-setup-all.sh`), test commands, troubleshooting (mirrors spec §11).

---

## Key configuration values

| Setting | Value | Where |
|---|---|---|
| Cluster | existing `kind` (no new cluster) | n/a |
| Keycloak namespace | `poc-keycloak` | k8s-manifests/poc-keycloak/01-namespace.yaml |
| App namespace | `poc` | k8s-manifests/poc/01-namespace.yaml |
| POC Keycloak image | `quay.io/keycloak/keycloak:26.5.3` (matches existing) | poc-keycloak Deployment |
| POC Keycloak feature flags | `token-exchange,admin-fine-grained-authz` | KC_FEATURES env |
| POC Keycloak admin | `admin` / `admin` (POC only — H2 wipes on restart) | env KEYCLOAK_ADMIN[_PASSWORD] |
| POC Keycloak URL (in-cluster) | `http://poc-keycloak.poc-keycloak.svc:8080` | pod-a + pod-b application.yml |
| POC Keycloak URL (host) | `http://127.0.0.1:30888` (via socat) | E2E .env, manual realm setup |
| Realm | `poc-realm` | realm-setup |
| Pod A client | `pod-a` (public, token-exchange permission policy enabled) | realm-setup |
| Pod B client | `pod-b` (confidential, audience mapper) | realm-setup |
| Realm roles | `data-reader`, `data-writer` | realm-setup |
| OIDC token mount | `/var/run/secrets/tokens/jwt.token` (audience=`keycloak-poc`, exp=3600s) | pod-a Deployment projected volume |
| K8s issuer (IdP "kubernetes") | `https://kubernetes.default.svc.cluster.local` | realm IdP |
| K8s JWKS URL | `https://kubernetes.default.svc.cluster.local/openid/v1/jwks` | realm IdP |
| Pod A NodePort (host) | `30810 → service nodePort 30810 → 8081` | poc/04-pod-a-service.yaml + socat |
| Pod B NodePort (host) | `30820 → service nodePort 30820 → 8082` | poc/06-pod-b-service.yaml + socat |
| POC Keycloak NodePort (host) | `30888 → service nodePort 30888 → 8080` | poc-keycloak/03-service.yaml + socat |
| Token exchange grant | `urn:ietf:params:oauth:grant-type:token-exchange` | TokenExchangeService.java |
| Subject token type | `urn:ietf:params:oauth:token-type:jwt` | TokenExchangeService.java |
| Access token TTL | 300 s (5 min) | realm client config |
| SA token refresh | every 4 min | TokenRefreshScheduler.java |

---

## Verification (end-to-end happy path)

After running `scripts/00-setup-all.sh` from a clean state:

```bash
# 1. Existing app still works (regression — should pass since we didn't touch it)
cd frontend && APP_URL=http://localhost:30000 npx playwright test auth.spec.ts
# expected: 7/7 pass

# 2. Smoke test (curl-based)
./scripts/06-test-flow.sh
# expected output ends with: "✅ End-to-end test completed successfully!"

# 3. Manual JWT inspection
TOKEN=$(curl -s -X POST http://127.0.0.1:30810/api/exchange | jq -r '.accessToken')
echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | jq '{aud,sub,roles,exp}'
# expected: aud="pod-b" (or includes pod-b),
#           sub starts with "system:serviceaccount:poc:pod-a",
#           roles contains data-reader + data-writer,
#           exp ~5 min ahead

# 4. RBAC negative test
curl -s -o /dev/null -w "%{http_code}\n" \
  http://127.0.0.1:30820/api/protected/data            # → 401
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer not-a-jwt" \
  http://127.0.0.1:30820/api/protected/data            # → 401

# 5. Full Playwright suite
./scripts/07-run-e2e.sh
# expected: "45 passed (XXs)" on chromium; report in
#   e2e-tests/playwright-report/

# 6. Audit logs
kubectl logs -n poc deploy/pod-b | grep AUDIT
# expected: every protected request logged with caller=
#   system:serviceaccount:poc:pod-a

# 7. Clean teardown
./scripts/99-cleanup.sh
kubectl get ns | grep -E "^(poc|poc-keycloak)" || echo "namespaces gone ✅"
docker ps --filter name=poc | grep -E "(pod-a-proxy|pod-b-proxy|poc-keycloak-proxy)" || \
  echo "proxies gone ✅"
```

---

## Risks & mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Keycloak token-exchange permission policy wiring | High | Spec doesn't spell this out — we explicitly script it in step 4 via Authorization REST API. Without it, exchange returns 403 even with `KC_FEATURES=token-exchange` enabled. Test in step 4 using a curl from inside the pod *before* moving on. |
| `system:service-account-issuer-discovery` not bound to unauthenticated | Med | Step 3 applies the ClusterRoleBinding idempotently; verify cross-namespace JWKS curl works before continuing. |
| Maven build slow in Docker (no cache) | Med | Multi-stage Dockerfile with `mvn dependency:go-offline` cached layer; mount a host BuildKit cache. ~First build 3–5 min, subsequent ~30s. |
| Playwright NodePort flakiness on macOS Docker | Med | Use `127.0.0.1` (avoid IPv6 surprises); add `await expect.poll()` retries on health checks at suite start; `globalSetup` waits for all three socat proxies + pods Ready. |
| socat proxy stale node-IP if cluster recreates | Low | The `99-cleanup.sh` removes proxies; `01-deploy-poc-keycloak.sh` and `05-deploy-pods.sh` recreate them with fresh `kubectl get nodes` IP — same defensive pattern as existing `argocd-http-proxy`. |
| H2 in-memory DB resets on Keycloak restart | By design | The realm-setup script is idempotent and re-runs in `00-setup-all.sh`. If a restart happens mid-test, just re-run setup. Persistence is plan-10 territory. |
| `aud` claim is array vs string | Med | Spec §5.1.3 reads `aud` as a single value; Keycloak may return an array. The TokenExchangeService should accept both (`asText()` falls back to `get(0).asText()`). The Playwright suite handles both shapes in jwt-helper.ts. |
| Pod A truststore / TLS to Keycloak | None | POC Keycloak uses HTTP only (in-cluster). RestTemplate default config works; no truststore needed. |

---

## Incremental-plan strategy (for future enhancements)

This plan is the **first** plan for the POC. Future enhancement requests should land as new files in `plans/`, numbered sequentially using the same `N-kebab-case.md` convention as plans 1–8:

| Plan # | Trigger | Likely scope |
|---|---|---|
| 9 (this) | "Implement the spec" | Full POC + 45 E2E tests |
| 10 | "Harden security" | TLS for POC Keycloak, mTLS pod↔Keycloak, NetworkPolicies, sealed admin secret |
| 11 | "Persist Keycloak state" | PostgreSQL backend for POC Keycloak, realm import via `--import-realm` instead of REST script |
| 12 | "Multi-cluster federation" | Pod A in cluster X exchanging via central Keycloak for Pod B in cluster Y |
| 13 | "GitOps integration" | ArgoCD Application + ApplicationSet for the POC, image automation |
| 14 | "Sidecar token manager" | Refactor TokenCacheManager out of pod-a into a sidecar |
| 15 | "Observability" | Prometheus + Grafana dashboards, OpenTelemetry traces |

Each future plan should:
- Reference plan 9 as its baseline (`Status: extends plan 9`).
- Only document the **delta** (changed/new files), not re-spec the POC.
- Add a corresponding row to the table in `CLAUDE.md` ("Plans & Implementation History").

---

## Files this plan will create on execution

**New files (under ``):**
- `README.md`
- `scripts/00-setup-all.sh`, `01-deploy-poc-keycloak.sh`, `02-jwks-discovery-rbac.sh`, `03-setup-poc-realm.sh`, `04-build-and-load.sh`, `05-deploy-pods.sh`, `06-test-flow.sh`, `07-run-e2e.sh`, `99-cleanup.sh`
- `pod-a/` and `pod-b/` Maven projects (per spec §5, full source)
- `k8s-manifests/00-jwks-rbac.yaml`
- `k8s-manifests/poc-keycloak/01-namespace.yaml` … `04-realm-setup-job.yaml` (realm-setup job is optional; the host-side script is the primary path)
- `k8s-manifests/poc/01-namespace.yaml` … `06-pod-b-service.yaml`
- `e2e-tests/` Playwright project (config + utils + 7 spec files = 45 tests)

**New files (under `plans/`):**
- `plans/9-poc-keycloak-token-exchange-spring-boot.md` — copy of this plan, finalized for repo history.

**Modified files (existing):**
- `CLAUDE.md` — append Plan 9 row under "Plans & Implementation History" + a brief "POC: Token Exchange ()" subsection under "Project Overview". Small additive edit.

**Untouched (explicit non-goals of this plan):**
- All existing `backend/`, `frontend/`, `gitops/`, `jenkins/` code paths.
- The existing `kind` cluster's `cluster/kind-config.yaml` — no recreate.
- The existing `keycloak/` namespace, StatefulSet, realm `student-mgmt`, feature flags. **Zero changes.**
