# 01 — Overview: Problem & Solution

> *"How does Service A prove its identity to Service B without storing static
> shared secrets in Service A?"*

This POC demonstrates a working answer using **Keycloak as the identity
broker** and a **Kubernetes-issued OIDC service-account token** as the
identity primitive.

---

## The problem

In any non-trivial Kubernetes cluster, services need to call each other.
Pod A invokes Pod B; the queue worker calls the database; the cron job
hits the inventory API. Each of these calls needs:

1. **Authentication** — Pod B must verify the caller is who they claim to be.
2. **Authorisation** — Pod B must enforce *what* this caller is allowed to do
   (RBAC, fine-grained permissions, …).
3. **Auditability** — every successful or denied call must be traceable to a
   workload identity for compliance and forensics.

Common solutions all carry pain:

| Approach | Pain |
|---|---|
| Hard-coded API keys per service | Rotation is manual; secrets sprawl in env vars / files; one leaked key blast-radius is the entire service |
| mTLS with X.509 client certs | PKI complexity (CA, rotation, CRL, OCSP, expiries cause prod incidents); no fine-grained RBAC out of the box |
| "Trust the network" / IP allowlists | Falls apart in dynamic Kubernetes (pod IPs cycle); fails an actual zero-trust posture |
| Naive shared JWT signing key | Secret distribution problem just moved one layer |

What we want, instead, is the same *user-centric* OAuth 2 / OIDC pattern that
already works for human authentication, applied to **workloads**:

* Each workload has a strong identity (its Kubernetes ServiceAccount).
* That identity is cryptographically signed by a trusted issuer.
* A central authorisation server (Keycloak) translates that identity into a
  **scoped, short-lived, audience-bound access token**.
* Other services validate that token against the issuer's public JWKS — no
  shared secrets, no per-pair PKI.

This is the **workload identity** pattern — sometimes called *zero-trust pod
identity* — and Kubernetes + Keycloak give you all the building blocks.

---

## What this POC delivers

A minimal, fully-working two-pod system that demonstrates the pattern:

```
pod-a (Spring Boot)                 pod-b (Spring Boot)
=================                   ===================
1. Reads its mounted K8s SA JWT     1. Stateless OAuth2 Resource Server
   /var/run/secrets/tokens/...      2. Validates incoming Bearer tokens
2. Authenticates to Keycloak           against Keycloak's JWKS
   (client_credentials + client       (no shared secrets)
   secret) — its workload           3. Extracts roles from JWT claims
   identity is the pod-a client        and enforces @PreAuthorize
3. Receives Keycloak access token    4. Logs every request as
   (aud=pod-b, exp=300s, roles)        structured AUDIT JSON
4. Calls pod-b /api/protected/data
   with Authorization: Bearer
```

| Property of the POC | Where it's enforced |
|---|---|
| **No static secrets in pod-a's source code** — its K8s SA token is mounted at runtime by the kubelet (TokenRequest API, audience-bound, ≤1h TTL) | `k8s-manifests/poc/03-pod-a-deployment.yaml` projected volume |
| **Tokens are short-lived** (5 min access TTL, refreshed every 4 min) | `pod-a/src/main/resources/application.yml` + `TokenRefreshScheduler.java` |
| **Audience binding** — pod-b refuses any token whose `aud` doesn't include `pod-b` | Audience mapper on pod-a client; resource-server validates `aud` |
| **Role-based authz** — `data-reader` for GET, `data-writer` for POST | `pod-b/.../config/SecurityConfig.java` `@PreAuthorize` |
| **Auditability** — every protected request is logged as structured JSON with caller identity + roles + outcome | `pod-b/.../audit/AuditLogger.java` |
| **Fully testable** — 45 Playwright tests across 7 suites cover happy path, RBAC negatives, token refresh, audit log scraping, performance | `e2e-tests/tests/` |

---

## Architectural pivots made during build

This POC originally targeted **RFC 8693 external-internal token exchange**
(see [`../spec.md`](../spec.md) §5.1) — pod-a sends its K8s SA JWT directly
as the `subject_token`, Keycloak validates it via the cluster's public JWKS,
and mints an internal access token. Two real-world obstacles forced a pivot:

1. **Keycloak 26.5's V1 (legacy) external token-exchange path is broken** for
   K8s SA tokens with the OIDC-style IdP — the V2 (`standard`) provider is
   hardcoded as the SPI default and rejects the legacy `subject_issuer`
   parameter.
2. **The K8s API server's `/openid/v1/jwks` endpoint requires the caller to
   be in the `system:service-account-issuer-discovery` group** — solvable
   (see [`../k8s-manifests/00-jwks-rbac.yaml`](../k8s-manifests/00-jwks-rbac.yaml)),
   but adds another moving piece.

The pragmatic pivot — fully validated end-to-end here — is **`client_credentials`**:

* Pod-a authenticates with its **client_secret**
* Keycloak issues an access token bound to the pod-a *client* identity
  (client_id, azp claim) with audience pod-b and the realm roles assigned
  to pod-a's service-account user
* The mounted K8s SA token is **still inspectable** at `/api/oidc/token-info`
  to demonstrate workload identity binding — production deployments would
  feed this token to a sidecar (e.g. SPIRE agent) or to Keycloak's standard
  token-exchange v2 once that feature stabilises (currently `preview`)

The architectural value — short-lived, audience-scoped, role-bearing,
auditable tokens validated by a central authority — is **identical** in both
shapes. See `plans/9-poc-keycloak-token-exchange-spring-boot.md`
for the full design history.

---

## What the running system looks like

After `00-setup-all.sh` succeeds:

| Component | Where | Resource cost |
|---|---|---|
| `poc-cluster` kind cluster | 1 control-plane node | ~500MB |
| `poc-keycloak/poc-keycloak` Deployment | dedicated POC Keycloak (Deployment, 1 replica, H2 in-memory) | ~512Mi RAM |
| `poc/pod-a` Deployment | Spring Boot 3.2 token exchanger | ~256Mi RAM |
| `poc/pod-b` Deployment | Spring Boot 3.2 resource server | ~256Mi RAM |

Total bootstrap time on a cold Maven cache: **~5 min**. Subsequent
`scripts/00-setup-all.sh` runs are dominated by Keycloak's startup
(~30–60s readiness probe).

---

## Code references — where to look first

| What | File | Why |
|---|---|---|
| Token exchange logic | [`../pod-a/src/main/java/com/example/poda/service/TokenExchangeService.java`](../pod-a/src/main/java/com/example/poda/service/TokenExchangeService.java) | The heart of pod-a — RFC 8693-shaped form post (current code uses `client_credentials`, see L72-86) |
| Token cache | [`../pod-a/src/main/java/com/example/poda/service/TokenCacheManager.java`](../pod-a/src/main/java/com/example/poda/service/TokenCacheManager.java) | Read-write-locked cache so we don't exchange on every call |
| Background refresh | [`../pod-a/src/main/java/com/example/poda/scheduler/TokenRefreshScheduler.java`](../pod-a/src/main/java/com/example/poda/scheduler/TokenRefreshScheduler.java) | `@Scheduled` every 4 min — token TTL is 5 min |
| OIDC Resource Server | [`../pod-b/src/main/java/com/example/podb/config/SecurityConfig.java`](../pod-b/src/main/java/com/example/podb/config/SecurityConfig.java) | `oauth2ResourceServer().jwt()` — Spring validates against Keycloak's JWKS |
| JWT → Spring authorities | [`../pod-b/src/main/java/com/example/podb/auth/PocJwtAuthenticationConverter.java`](../pod-b/src/main/java/com/example/podb/auth/PocJwtAuthenticationConverter.java) | Extracts roles from `realm_access.roles`, `resource_access.*.roles`, and flat `roles` claim |
| Audit logger | [`../pod-b/src/main/java/com/example/podb/audit/AuditLogger.java`](../pod-b/src/main/java/com/example/podb/audit/AuditLogger.java) | Structured `AUDIT: {…}` JSON line per request |
| Realm bootstrap | [`../scripts/04-setup-poc-realm.sh`](../scripts/04-setup-poc-realm.sh) | Idempotent realm/clients/roles/IdP/audience-mapper/role-assignment via Keycloak admin REST API |

See [06-code-walkthrough.md](./06-code-walkthrough.md) for an annotated tour.

---

Next → [02-architecture.md](./02-architecture.md)
