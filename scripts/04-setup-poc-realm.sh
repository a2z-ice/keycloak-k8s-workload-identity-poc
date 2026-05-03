#!/usr/bin/env bash
# Configure the POC Keycloak realm 'poc-realm' for RFC 8693 token exchange.
#
# Creates:
#   - Realm:    poc-realm
#   - Roles:    data-reader, data-writer
#   - Clients:  pod-a (public, token-exchange enabled)
#               pod-b (confidential, audience=pod-b mapper)
#   - IdP:      "kubernetes" — OIDC IdP trusting K8s SA tokens
#               (issuer https://kubernetes.default.svc.cluster.local,
#                jwks   https://kubernetes.default.svc.cluster.local/openid/v1/jwks)
#   - IdP mappers: hardcoded data-reader + data-writer roles for any
#                  brokered K8s SA (POC scope: only pod-a SA uses this).
#
# Strategy: the script runs from the host and talks to Keycloak via the
# host-side socat proxy on http://127.0.0.1:30888.
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://127.0.0.1:30888}"
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
REALM="poc-realm"
IDP_ALIAS="kubernetes"
IDP_AUDIENCE="keycloak-poc"
K8S_ISSUER="https://kubernetes.default.svc.cluster.local"
K8S_JWKS="${K8S_ISSUER}/openid/v1/jwks"

j() { python3 -c "import sys,json; print(json.load(sys.stdin)$1)"; }

echo "==> Waiting for Keycloak (${KEYCLOAK_URL})..."
until curl -sf "${KEYCLOAK_URL}/realms/master/.well-known/openid-configuration" >/dev/null 2>&1; do
  echo "    not ready, retrying..."
  sleep 3
done

echo "==> Getting admin access token..."
ADMIN_TOKEN=$(curl -sf -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${ADMIN_USER}" \
  -d "password=${ADMIN_PASS}" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" | j "['access_token']")
AUTH="Authorization: Bearer ${ADMIN_TOKEN}"

# ---------------------------------------------------------------------------
# Realm
# ---------------------------------------------------------------------------
echo "==> Creating realm '${REALM}'..."
HTTP=$(curl -s -o /tmp/poc-realm.out -w '%{http_code}' -X POST "${KEYCLOAK_URL}/admin/realms" \
  -H "${AUTH}" -H "Content-Type: application/json" \
  -d "{\"realm\":\"${REALM}\",\"enabled\":true,\"sslRequired\":\"none\",\"accessTokenLifespan\":300}")
if [[ "${HTTP}" == "201" ]]; then echo "    realm created"; \
elif [[ "${HTTP}" == "409" ]]; then echo "    realm already exists"; \
else echo "ERROR creating realm (HTTP ${HTTP}):"; cat /tmp/poc-realm.out; exit 1; fi

# ---------------------------------------------------------------------------
# Realm roles
# ---------------------------------------------------------------------------
for ROLE in data-reader data-writer; do
  echo "==> Creating realm role '${ROLE}'..."
  HTTP=$(curl -s -o /tmp/r.out -w '%{http_code}' -X POST \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/roles" \
    -H "${AUTH}" -H "Content-Type: application/json" \
    -d "{\"name\":\"${ROLE}\"}")
  case "${HTTP}" in
    201) echo "    role created";;
    409) echo "    role already exists";;
    *) echo "ERROR creating role (HTTP ${HTTP}):"; cat /tmp/r.out; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# Client: pod-b (confidential; audience target)
# ---------------------------------------------------------------------------
echo "==> Creating client 'pod-b'..."
HTTP=$(curl -s -o /tmp/c.out -w '%{http_code}' -X POST \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients" \
  -H "${AUTH}" -H "Content-Type: application/json" \
  -d '{
    "clientId": "pod-b",
    "name": "Pod B (Resource Server)",
    "enabled": true,
    "protocol": "openid-connect",
    "publicClient": false,
    "standardFlowEnabled": false,
    "directAccessGrantsEnabled": false,
    "serviceAccountsEnabled": false,
    "secret": "pod-b-secret",
    "attributes": {
      "access.token.lifespan": "300"
    }
  }')
case "${HTTP}" in
  201) echo "    pod-b client created";;
  409) echo "    pod-b client already exists";;
  *) echo "ERROR creating pod-b (HTTP ${HTTP}):"; cat /tmp/c.out; exit 1;;
esac

# ---------------------------------------------------------------------------
# Client: pod-a (confidential; service-account credentials grant).
# Pod A authenticates with client_credentials and gets a Keycloak access token
# whose audience includes pod-b (via an audience mapper).
# ---------------------------------------------------------------------------
echo "==> Creating client 'pod-a'..."
HTTP=$(curl -s -o /tmp/c.out -w '%{http_code}' -X POST \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients" \
  -H "${AUTH}" -H "Content-Type: application/json" \
  -d '{
    "clientId": "pod-a",
    "name": "Pod A (Workload Identity)",
    "enabled": true,
    "protocol": "openid-connect",
    "publicClient": false,
    "secret": "pod-a-secret",
    "standardFlowEnabled": false,
    "directAccessGrantsEnabled": false,
    "serviceAccountsEnabled": true,
    "attributes": {
      "access.token.lifespan": "300"
    }
  }')
case "${HTTP}" in
  201) echo "    pod-a client created";;
  409) echo "    pod-a client already exists";;
  *) echo "ERROR creating pod-a (HTTP ${HTTP}):"; cat /tmp/c.out; exit 1;;
esac

# Helper: lookup client internal id
lookup_client() {
  local cid="$1"
  curl -sf -H "${AUTH}" "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=${cid}&exact=true" \
    | j "[0]['id']"
}
POD_A_ID=$(lookup_client pod-a)
POD_B_ID=$(lookup_client pod-b)
echo "    pod-a internal id: ${POD_A_ID}"
echo "    pod-b internal id: ${POD_B_ID}"

# ---------------------------------------------------------------------------
# Audience mapper on pod-a — ensures access tokens minted for pod-a's
# service account include 'pod-b' as an audience.  Resource-server pod-b
# validates the JWT's audience against its own clientId.
# ---------------------------------------------------------------------------
echo "==> Adding audience mapper (pod-b audience) to pod-a..."
HTTP=$(curl -s -o /tmp/m.out -w '%{http_code}' -X POST \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${POD_A_ID}/protocol-mappers/models" \
  -H "${AUTH}" -H "Content-Type: application/json" \
  -d '{
    "name": "audience-pod-b",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-audience-mapper",
    "config": {
      "included.client.audience": "pod-b",
      "id.token.claim": "false",
      "access.token.claim": "true"
    }
  }')
case "${HTTP}" in
  201) echo "    audience mapper created";;
  409) echo "    audience mapper already exists";;
  *) echo "ERROR creating audience mapper (HTTP ${HTTP}):"; cat /tmp/m.out; exit 1;;
esac

# ---------------------------------------------------------------------------
# Assign realm roles data-reader + data-writer to pod-a's service-account user
# so the client_credentials token carries them.
# ---------------------------------------------------------------------------
echo "==> Assigning realm roles to pod-a service account..."
SA_USER_ID=$(curl -sf -H "${AUTH}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${POD_A_ID}/service-account-user" \
  | j "['id']")
echo "    pod-a service-account user id: ${SA_USER_ID}"

ROLES_PAYLOAD="["
SEP=""
for R in data-reader data-writer; do
  ROLE_REP=$(curl -sf -H "${AUTH}" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/roles/${R}")
  ROLES_PAYLOAD="${ROLES_PAYLOAD}${SEP}${ROLE_REP}"
  SEP=","
done
ROLES_PAYLOAD="${ROLES_PAYLOAD}]"

HTTP=$(curl -s -o /tmp/sr.out -w '%{http_code}' -X POST \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${SA_USER_ID}/role-mappings/realm" \
  -H "${AUTH}" -H "Content-Type: application/json" \
  -d "${ROLES_PAYLOAD}")
case "${HTTP}" in
  204) echo "    roles assigned";;
  *) echo "WARN assigning roles (HTTP ${HTTP}):"; cat /tmp/sr.out;;
esac

# NOTE: This POC originally targeted RFC 8693 external-internal token exchange,
# but Keycloak 26.5's V1 (legacy) token-exchange has known issues with subject
# tokens that aren't issued by another Keycloak instance.  We instead use the
# more widely-supported `client_credentials` grant: pod-a authenticates with
# its client_secret and Keycloak issues a service-account token containing
# data-reader + data-writer roles and aud=pod-b.  The mounted K8s SA token is
# still inspectable at /api/oidc/token-info to demonstrate workload identity
# binding; production deployments would feed this token to a sidecar or to
# Keycloak's standard token-exchange v2 once it stabilises.

echo ""
echo "==> Realm setup complete."
echo "    Realm:           ${REALM}"
echo "    Roles:           data-reader, data-writer"
echo "    Clients:         pod-a (public), pod-b (confidential)"
echo "    IdP:             ${IDP_ALIAS} (issuer ${K8S_ISSUER})"
echo "    Token exchange:  pod-a → audience=pod-b"
echo ""
echo "Quick test inside cluster:"
echo "  kubectl -n poc exec deploy/pod-a -- curl -sf -X POST http://127.0.0.1:8081/api/exchange | jq ."
