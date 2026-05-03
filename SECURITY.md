# SECURITY.md

## This is a proof of concept — secrets are intentionally hardcoded

This repo is a **local-development POC** that runs entirely inside a kind
(Kubernetes-in-Docker) cluster on the developer's loopback interface. To
keep the bootstrap reproducible and the realm-setup idempotent, several
"secret" values are hardcoded:

| Where | Value | Risk in this POC | Risk if misused |
|---|---|---|---|
| `k8s-manifests/poc-keycloak/02-deployment.yaml` | `KEYCLOAK_ADMIN=admin` / `KEYCLOAK_ADMIN_PASSWORD=admin` | None — Keycloak runs in a kind cluster bound to `127.0.0.1` only; H2 in-memory wipes on restart | Anyone with admin/admin can take over the realm if the cluster is exposed publicly |
| `scripts/04-setup-poc-realm.sh` | client secret `pod-a-secret` for the `pod-a` Keycloak client | None — only valid against the local POC realm | Anyone with the value can request a token from the POC realm if it's exposed |
| `scripts/04-setup-poc-realm.sh` | client secret `pod-b-secret` for the `pod-b` Keycloak client | None — pod-b doesn't use this; it's there only because the client was created confidential | Same as above |
| `pod-a/src/main/resources/application.yml` | Default fallback `client_secret: pod-a-secret` | None — the env var in the deployment overrides the default in production-like flows | Same as above |

**These values are not secrets in the production sense.** They are
configuration constants that make the realm bootstrap reproducible. There
is no real system, no real user data, and no privileged production cluster
that they grant access to.

## What you must change before running this anywhere reachable

If you are taking ideas from this repo into a real environment, **at minimum**:

1. **Replace the admin password** with a generated secret stored in a
   `Secret` (or external KMS). Never commit it.
2. **Replace `pod-a-secret` / `pod-b-secret`** with random per-environment
   secrets, also stored in `Secret`s. Use the existing env-var injection
   points (`KEYCLOAK_CLIENT_SECRET` for pod-a) to wire them in.
3. **Add TLS to Keycloak** (`KC_HTTPS_CERTIFICATE_FILE` / `_KEY_FILE` or
   ingress-terminated TLS) — the POC runs HTTP for simplicity.
4. **Add a persistent database** — the POC's `start-dev` H2 wipes on every
   restart.
5. **Add NetworkPolicies** to restrict pod-to-pod traffic to just
   `pod-a → pod-b` and `pod-* → poc-keycloak`.
6. **Rotate signing keys** on a real schedule.
7. **Audit logs** — pod-b's `AuditLogger` is stdout JSON; ship it somewhere
   tamper-evident (Loki, Splunk, …).

These items are tracked as future plans (10 — security hardening, 11 —
persistence, 14 — sidecar token manager) in [`plans/`](./plans/).

## Reporting a security issue in this POC

If you find a real vulnerability in the **code patterns** demonstrated here
(e.g. JWT validation logic, audit log injection, cache races) — open a
GitHub issue. Don't bother filing reports about the hardcoded
`admin/admin` or `pod-a-secret` values: those are the point.

## Scope

In scope for security feedback:
- Spring Security configuration in `pod-b/src/main/java/com/example/podb/config/SecurityConfig.java`
- JWT → authorities conversion in `PocJwtAuthenticationConverter.java`
- Audit log schema and emission in `AuditLogger.java`
- Token cache thread safety in `TokenCacheManager.java`
- Realm-setup REST flow correctness in `scripts/04-setup-poc-realm.sh`

Out of scope:
- Hardcoded POC default values
- Anything assuming the cluster is reachable beyond loopback
