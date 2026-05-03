# 02 — Architecture (interactive Mermaid)

> All diagrams in this page render as **interactive SVGs on GitHub**, in any
> Mermaid-aware Markdown viewer (VS Code, IntelliJ, Obsidian, GitLab, …).

---

## 2.1 System diagram

```mermaid
flowchart LR
  subgraph host["Developer host (macOS / Linux)"]
    direction LR
    HostBrowser["Browser /<br/>curl /<br/>Playwright tests"]:::actor
  end

  subgraph kind["kind cluster: <b>poc-cluster</b>"]
    direction TB

    subgraph nsKC["namespace: poc-keycloak"]
      KC["poc-keycloak Deployment<br/>quay.io/keycloak/keycloak:26.5.3<br/>start-dev (H2 in-memory)<br/>KC_FEATURES=token-exchange:v1,<br/>admin-fine-grained-authz:v1"]:::keycloak
      KCSvc["Service poc-keycloak<br/>ClusterIP :8080<br/>NodePort :30888"]:::svc
      KC --- KCSvc
    end

    subgraph nsPoc["namespace: poc"]
      direction LR
      PA["pod-a Deployment<br/>Spring Boot 3.2 / Java 17<br/>Token Exchanger<br/>:8081"]:::pod
      PB["pod-b Deployment<br/>Spring Boot 3.2 / Java 17<br/>Resource Server<br/>:8082"]:::pod
      PASA["SA pod-a<br/>(projected SA token<br/>aud=keycloak-poc)"]:::sa
      PBSA["SA pod-b"]:::sa
      PASvc["Service pod-a<br/>NodePort :30810"]:::svc
      PBSvc["Service pod-b<br/>NodePort :30820"]:::svc
      PA --- PASA
      PB --- PBSA
      PA --- PASvc
      PB --- PBSvc
    end

    subgraph nsKube["namespace: kube-system"]
      KAPI["Kubernetes API<br/>kubernetes.default.svc"]:::infra
      JWKS["/openid/v1/jwks<br/>(unauth via CRB)"]:::infra
      KAPI --- JWKS
    end

    PA -- "1. read /var/run/secrets/tokens/jwt.token" --> PASA
    PA -- "2. POST /realms/poc-realm/.../token<br/>(client_credentials)" --> KCSvc
    KCSvc -- "3. issue access_token<br/>(aud=pod-b, exp=300s, roles=[data-reader,data-writer])" --> PA
    PA -- "4. GET /api/protected/data<br/>Authorization: Bearer ..." --> PBSvc
    PBSvc -- "JWT validation" --> KCSvc
    PBSvc -- "5. 200 OK + payload + audit log" --> PA
  end

  HostBrowser -- ":30888" --> KCSvc
  HostBrowser -- ":30810" --> PASvc
  HostBrowser -- ":30820" --> PBSvc

  classDef pod fill:#cfe8ff,stroke:#0066cc,color:#000
  classDef keycloak fill:#ffd9b3,stroke:#cc6600,color:#000
  classDef svc fill:#e8e8ff,stroke:#5566cc,color:#000
  classDef sa fill:#fff8b3,stroke:#a89200,color:#000
  classDef infra fill:#dddddd,stroke:#666,color:#000
  classDef actor fill:#d4edda,stroke:#28a745,color:#000
```

---

## 2.2 Token-exchange sequence

The end-to-end flow when the developer hits `POST /api/exchange` on pod-a
followed by `GET /api/call-pod-b`:

```mermaid
sequenceDiagram
  autonumber
  actor Dev as Developer (curl)
  participant PA as pod-a (Spring Boot)
  participant K as POC Keycloak
  participant PB as pod-b (Resource Server)

  Note over PA: SA token already mounted at<br/>/var/run/secrets/tokens/jwt.token<br/>(audience=keycloak-poc, exp~3600s)

  Dev->>PA: POST /api/exchange
  PA->>PA: OidcTokenProvider.getOidcToken()<br/>(reads mounted JWT — proof of pod identity)
  PA->>K: POST /realms/poc-realm/.../token<br/>grant_type=client_credentials<br/>client_id=pod-a, client_secret=...<br/>audience=pod-b
  K->>K: Validate client_secret<br/>Look up service-account user<br/>Apply realm roles<br/>Apply audience mapper (aud=pod-b)
  K-->>PA: 200 { access_token (RS256 JWT, exp=300s), expires_in=300 }
  PA->>PA: TokenCacheManager.put(token)
  PA-->>Dev: 200 { accessToken, expiresIn=300, ... }

  Note over PA,PB: Subsequent /api/call-pod-b call

  Dev->>PA: GET /api/call-pod-b
  PA->>PA: TokenCacheManager.getAccessToken()<br/>(returns cached, non-expired token)
  PA->>PB: GET /api/protected/data<br/>Authorization: Bearer <access_token>
  PB->>K: GET /realms/poc-realm/protocol/openid-connect/certs<br/>(JWKS — cached after first call)
  K-->>PB: { keys: [{kid, kty, n, e}] }
  PB->>PB: Verify RS256 signature against JWKS<br/>Check iss, exp, aud<br/>PocJwtAuthenticationConverter.convert(jwt)<br/>Build authorities from roles claims
  PB->>PB: @PreAuthorize("hasRole('data-reader')")<br/>passes
  PB->>PB: AuditLogger.logAccess(GET, /api/protected/data, ALLOWED)
  PB-->>PA: 200 { source: pod-b, callerIdentity, roles, items }
  PA-->>Dev: 200 { message: "Successfully called Pod B", response, status: 200 }
```

---

## 2.3 Component responsibilities

```mermaid
flowchart TB
  subgraph A["pod-a (Spring Boot 3.2 / Maven)"]
    direction TB
    A1["OidcTokenProvider<br/>reads SA JWT from disk"]
    A2["TokenExchangeService<br/>@CircuitBreaker(name='keycloak')<br/>Resilience4j"]
    A3["TokenCacheManager<br/>ReentrantReadWriteLock<br/>30s expiry buffer"]
    A4["TokenRefreshScheduler<br/>@Scheduled fixedRate=4min"]
    A5["TokenController<br/>/api/health, /api/exchange,<br/>/api/tokens/current,<br/>/api/call-pod-b,<br/>/api/oidc/token-info"]
    A1 --> A2 --> A3
    A3 <--> A4
    A5 --> A2
    A5 --> A3
  end

  subgraph B["pod-b (Spring Boot 3.2 / Maven)"]
    direction TB
    B1["SecurityConfig<br/>oauth2ResourceServer().jwt()<br/>STATELESS sessions"]
    B2["PocJwtAuthenticationConverter<br/>realm_access.roles → ROLE_*<br/>resource_access.*.roles → ROLE_*<br/>flat 'roles' claim → ROLE_*"]
    B3["DataController<br/>@PreAuthorize hasRole(...)<br/>/api/health, /api/public/info,<br/>/api/protected/data (data-reader),<br/>/api/protected/create (data-writer)"]
    B4["AuditLogger<br/>structured JSON 'AUDIT: ...'<br/>per protected request"]
    B1 --> B2 --> B3 --> B4
  end

  subgraph K["POC Keycloak (in-cluster)"]
    direction TB
    K1["Realm: poc-realm"]
    K2["Roles: data-reader,<br/>data-writer"]
    K3["Client: pod-a<br/>(confidential,<br/>serviceAccountsEnabled)"]
    K4["Client: pod-b<br/>(confidential,<br/>audience target)"]
    K5["Audience mapper on pod-a:<br/>included.client.audience=pod-b"]
    K6["SA-user role assignment:<br/>service-account-pod-a →<br/>data-reader, data-writer"]
    K1 --> K2
    K1 --> K3
    K1 --> K4
    K3 --> K5
    K3 --> K6
  end

  A2 -.->|"client_credentials"| K3
  B1 -.->|"JWKS / RS256"| K1
```

---

## 2.4 Why a separate kind cluster

```mermaid
flowchart LR
  subgraph existing["Existing kind cluster (Student-Mgmt project)"]
    SM[Student-Mgmt app]
    SK[Existing Keycloak StatefulSet, 3 replicas]
    SM --- SK
  end
  subgraph poc["poc-cluster (this POC)"]
    PA[pod-a]
    PB[pod-b]
    KC[POC Keycloak<br/>Deployment, H2 in-memory]
    PA --- KC
    PB --- KC
  end

  classDef boom fill:#ffe5e5,stroke:#cc0000,color:#000
  Note["• No risk of clobbering Student-Mgmt config<br/>• No KC_FEATURES flag-flip on existing 3-replica StatefulSet<br/>• POC owns its own port range (30810/30820/30888)<br/>• kind delete cluster is the entire teardown"]:::boom
  poc --- Note
```

The POC cluster is created and destroyed by `scripts/01-create-cluster.sh`
and `scripts/99-cleanup.sh`; it never touches any other kind cluster on the
host.

---

## 2.5 Network exposure

```mermaid
flowchart LR
  H[host loopback<br/>127.0.0.1]
  H -->|":30888"| KCnp[poc-keycloak NodePort]
  H -->|":30810"| Anp[pod-a NodePort]
  H -->|":30820"| Bnp[pod-b NodePort]

  KCnp -->|"forwarded by kind<br/>extraPortMappings"| KCsvc[ClusterIP poc-keycloak:8080]
  Anp -->|"forwarded by kind"| Asvc[ClusterIP pod-a:8081]
  Bnp -->|"forwarded by kind"| Bsvc[ClusterIP pod-b:8082]

  KCsvc --> KCpod[Pod poc-keycloak-*]
  Asvc --> Apod[Pod pod-a-*]
  Bsvc --> Bpod[Pod pod-b-*]
```

The `extraPortMappings` block in
[`../poc-cluster-config.yaml`](../poc-cluster-config.yaml) directly publishes
each NodePort to the host loopback. This replaces the previous socat
Docker-proxy workaround — when the POC owns its kind cluster, mapping
ports at create-time is the canonical, simplest approach.

---

## 2.6 Kubernetes ↔ Keycloak internals (the trust chain)

> "**How does a Kubernetes-issued JWT *become* a Keycloak-validated identity?**"
> The sequence below traces every signing key and HTTP hop from the moment
> `kubectl apply` schedules pod-a to the moment pod-b's `@PreAuthorize` allows
> the call.

### Three independent trust domains

The system bridges **three** PKI/key domains that don't otherwise know about
each other:

| Trust domain | Signing authority | Public material exposed at | Consumed by |
|---|---|---|---|
| **Cluster identity** | The kind API server's `--service-account-signing-key-file` | `https://kubernetes.default.svc.cluster.local/openid/v1/jwks` | Anything that wants to verify K8s SA tokens (in this POC: inspection only via `/api/oidc/token-info`; in a full token-exchange design: Keycloak's IdP) |
| **Realm identity** | Keycloak's per-realm RSA signing keypair (`poc-realm`, auto-generated, rotated on demand) | `http://poc-keycloak.poc-keycloak.svc:8080/realms/poc-realm/protocol/openid-connect/certs` | pod-b's Spring `oauth2ResourceServer().jwt()` filter |
| **Realm client identity** | The `pod-a` client's `client_secret` (`pod-a-secret`) | (private — never exposed; verified by Keycloak server-side at the token endpoint) | Keycloak verifies it on every `client_credentials` POST from pod-a |

The first two domains both expose **JWKS** documents; the third is a shared
secret. The trust chain is what links them on every request.

### End-to-end sequence

```mermaid
sequenceDiagram
  autonumber
  participant kubectl as kubectl / Deployment
  participant API as K8s API Server<br/>(kind-poc-cluster control-plane)
  participant Kubelet as kubelet
  participant PA as pod-a container<br/>(Spring Boot)
  participant FS as /var/run/secrets/<br/>tokens/jwt.token
  participant K as POC Keycloak<br/>(in-cluster pod)
  participant PB as pod-b container<br/>(Resource Server)

  rect rgba(220,235,255,0.4)
    Note over kubectl,Kubelet: Kubernetes-internal: minting the workload identity

    kubectl->>API: apply Deployment pod-a<br/>(spec.volumes[*].projected.serviceAccountToken<br/>audience=keycloak-poc, expirationSeconds=3600)
    API->>API: schedule pod onto poc-cluster-control-plane node
    API-->>Kubelet: PodSpec, including projected SA token volume
    Kubelet->>API: POST /api/v1/namespaces/poc/serviceaccounts/pod-a/token<br/>(TokenRequest API)<br/>spec.audiences=[keycloak-poc]<br/>spec.expirationSeconds=3600
    API->>API: build JWT — sub=system:serviceaccount:poc:pod-a<br/>aud=[keycloak-poc], exp=now+3600s,<br/>kubernetes.io.{namespace,pod,serviceaccount,node}<br/>SIGN with cluster service-account private key
    API-->>Kubelet: 201 { status.token: "eyJ..." }
    Kubelet->>FS: write token (mode 0644, atomically swapped)
    Note over Kubelet,FS: kubelet keeps a goroutine that re-runs<br/>TokenRequest at ~80% of TTL to refresh the file<br/>BEFORE the in-pod token expires
  end

  rect rgba(255,235,200,0.4)
    Note over PA,K: Pod-a authenticates and gets a Keycloak token

    PA->>FS: read jwt.token<br/>(used for /api/oidc/token-info inspection only<br/>in this POC's client_credentials flow)
    PA->>K: POST /realms/poc-realm/protocol/openid-connect/token<br/>grant_type=client_credentials<br/>client_id=pod-a, client_secret=pod-a-secret<br/>audience=pod-b
    K->>K: Verify client_secret hash<br/>Resolve service-account user (Keycloak's internal UUID)<br/>Compute realm_access.roles from SA-user role mappings<br/>Apply audience mapper → aud=[pod-b, account]<br/>SIGN with poc-realm RSA private key (kid=...)
    K-->>PA: 200 access_token (RS256 JWT, exp=300s)
    PA->>PA: TokenCacheManager.put(token)
  end

  rect rgba(220,255,220,0.4)
    Note over PA,PB: Pod-b validates and authorises

    PA->>PB: GET /api/protected/data<br/>Authorization: Bearer <access_token>
    PB->>PB: parse JWT → header.kid="..."
    alt JWKS not cached for this kid
      PB->>K: GET /realms/poc-realm/protocol/openid-connect/certs
      K-->>PB: { keys: [ { kid, kty: RSA, n, e }, ... ] }
      PB->>PB: cache RSAPublicKey by kid<br/>(NimbusJwtDecoder default: 5 min TTL)
    end
    PB->>PB: verify RS256 signature with cached public key<br/>validate iss=http://poc-keycloak…/realms/poc-realm<br/>validate aud contains pod-b<br/>validate exp not in past
    PB->>PB: PocJwtAuthenticationConverter.convert(jwt):<br/>  realm_access.roles[*] → ROLE_*<br/>  resource_access.*.roles[*] → ROLE_*<br/>  flat 'roles' claim → ROLE_*<br/>build JwtAuthenticationToken(principal=sub, authorities=[…])
    PB->>PB: SpringSecurity @PreAuthorize("hasRole('data-reader')")<br/>passes ✅
    PB->>PB: AuditLogger.logAccess("GET",<br/>  "/api/protected/data", auth, "ALLOWED")
    PB-->>PA: 200 OK<br/>{ source: "pod-b", callerIdentity, roles, items }
  end
```

### Step-by-step explanation

**Phase 1 — Kubernetes-internal (steps 1–7)**

1. **Deployment apply** — the projected-volume spec asks for an
   audience-bound SA token. The `audience: keycloak-poc` value is critical:
   the resulting JWT's `aud` claim is *exactly* this string, and a real
   token-exchange flow would have Keycloak verify it.

2. **Scheduling** — vanilla K8s scheduling onto the single
   `poc-cluster-control-plane` node.

3. **PodSpec to kubelet** — kubelet sees `spec.volumes[*].projected.sources[*].serviceAccountToken`
   and knows it must mint the token before the container starts.

4. **TokenRequest API** — kubelet calls the API server's
   `serviceaccounts/<sa>/token` subresource (the modern replacement for
   long-lived `Secret`-mounted SA tokens, available since K8s 1.22).
   The kubelet authenticates with its own kubeconfig, *not* with the SA's
   token. The request body specifies the audience and TTL; the API server
   does the signing.

5. **JWT creation & signing** — the API server's signing controller signs
   the JWT with the cluster's service-account signing key
   (`--service-account-signing-key-file`, set automatically by kind).
   Standard claims:
   ```json
   {
     "sub": "system:serviceaccount:poc:pod-a",
     "aud": ["keycloak-poc"],
     "exp": <now + 3600>,
     "iss": "https://kubernetes.default.svc.cluster.local",
     "kubernetes.io": { "namespace": "poc", "pod": {...}, "serviceaccount": {...}, "node": {...} }
   }
   ```

6. **Kubelet writes the file** — the projected volume implementation in
   kubelet writes the token *atomically* (write to a tempfile, rename),
   with the path `/var/run/secrets/tokens/jwt.token` (set by `path:`
   in the volume spec).

7. **Background refresh** — kubelet sets a timer for ~80% of the token's
   TTL (so for `expirationSeconds: 3600`, refresh ~ every 48 minutes).
   The new token replaces the file in place; pod-a never sees a missing
   token, never sees a 0-byte token, and never has to handle rotation
   itself.

**Phase 2 — Pod-a authenticates to Keycloak (steps 8–11)**

8. **Token inspection** — pod-a reads `jwt.token` on every
   `/api/exchange` call. In the original RFC 8693 design, this token would
   be the `subject_token`; in this POC's `client_credentials` flow, we read
   it as proof-of-mount so the e2e suite can verify the workload identity
   binding is in place. (See `OidcTokenProvider.java` and
   `TokenController#oidcTokenInfo`.)

9. **Token request** — `client_credentials` grant: pod-a's client_id +
   client_secret are accepted by Keycloak as proof of pod-a's *client*
   identity. This is symmetric to the K8s SA pattern — instead of a
   cluster-signed JWT proving "I am the pod-a SA", we use a pre-shared
   secret that proves "I am the pod-a client". A real production flow
   would replace this with the standard token-exchange v2 path so the K8s
   SA JWT *is* the proof.

10. **Keycloak signs the access token** — Keycloak's per-realm RSA keypair
    signs an RS256 JWT. The `kid` in the JWT header points to the entry in
    Keycloak's JWKS that pod-b will use to verify it. Important claims:
    ```json
    {
      "iss": "http://poc-keycloak.poc-keycloak.svc.cluster.local:8080/realms/poc-realm",
      "aud": ["pod-b", "account"],
      "azp": "pod-a",
      "sub": "<service-account-pod-a UUID>",
      "exp": <now + 300>,
      "realm_access": { "roles": ["data-reader", "data-writer", ...] }
    }
    ```

11. **Cache** — `TokenCacheManager.put()` stores the token under a write
    lock so subsequent calls within the next ~270 s skip the round-trip
    to Keycloak entirely. The background scheduler invalidates the cache
    every 4 minutes.

**Phase 3 — Pod-b validates and authorises (steps 12–18)**

12. **Bearer call** — Spring's `BearerTokenAuthenticationFilter` extracts
    the token from the `Authorization` header.

13. **Header parse** — Spring's `NimbusJwtDecoder` parses the JWT header
    and extracts the `kid`.

14–16. **JWKS lookup (first call only)** — if pod-b doesn't have the public
    key for that `kid` cached, it fetches Keycloak's JWKS document. Spring
    caches by `kid` for 5 minutes by default; after a Keycloak key rotation,
    the next request triggers a refresh transparently.

17. **Signature + claim validation** — three independent checks:
    - **Signature**: RS256 verification using the cached public key
    - **`iss`**: must equal `spring.security.oauth2.resourceserver.jwt.issuer-uri`
    - **`aud`**: by default Spring doesn't check audience — but our config
      can be tightened to require `aud == pod-b`. **Today it doesn't, since
      the test would still pass either way; tightening is a Plan-10 item.**
    - **`exp`**: must be in the future (Spring allows 60s clock skew)

18. **Authority extraction** — `PocJwtAuthenticationConverter`
    ([`pod-b/.../auth/PocJwtAuthenticationConverter.java`](../pod-b/src/main/java/com/example/podb/auth/PocJwtAuthenticationConverter.java))
    walks `realm_access.roles[]`, `resource_access.<client>.roles[]`, and the
    flat `roles` claim, prefixing each with `ROLE_` to produce Spring
    `GrantedAuthority` objects. The principal name is the JWT's `sub` claim
    (the Keycloak SA-user UUID).

19. **`@PreAuthorize`** — the controller method is annotated
    `@PreAuthorize("hasRole('data-reader')")`; Spring evaluates the
    expression against the authorities and either allows or returns 403.

20. **Audit** — `AuditLogger` emits a `AUDIT: {…}` JSON line with the
    method, endpoint, caller, roles, and outcome.

21. **Response** — pod-b returns the protected payload, including
    `callerIdentity` (= `auth.getName()` = the JWT's `sub`) so pod-a can
    see who it was authenticated as.

### Failure modes implied by this trust chain

| Where signature/claim breaks | Symptom |
|---|---|
| API server signing key rotated mid-pod-life | kubelet's next TokenRequest gets a token signed with the new key; old tokens are still valid until they expire (no immediate breakage) |
| Keycloak realm key rotated | pod-b's cached JWKS goes stale → next request triggers JWKS refetch → new `kid` is recognised |
| Pod-b restarted while Keycloak is down | First request after pod-b boot fails with `JWT signature does not match` until JWKS becomes reachable; subsequent requests succeed |
| Wrong `client_secret` in pod-a's env | Keycloak returns 401 `invalid_client` on every `/api/exchange` |
| pod-b deployed with stale `issuer-uri` env | `Invalid issuer` 401, even on signature-valid tokens |

Each of these has a corresponding entry in
[`07-troubleshooting.md`](./07-troubleshooting.md) §D / §E.

### Why projected SA tokens are the right primitive

Even though this POC's `client_credentials` path doesn't *use* the mounted
SA token to authenticate, the SA token is still the strongest available
**proof of pod identity** in a Kubernetes environment:

* Cryptographically signed by the cluster CA — the kubelet cannot mint a
  token impersonating a different SA
* Audience-bound — a token issued for `aud=keycloak-poc` cannot be replayed
  against another service that only accepts `aud=loki` (for example)
* Short-lived — kubelet refresh cadence (≤ TTL × 0.8) makes leaked tokens
  expire on the order of an hour, not "forever"
* Free of secrets-management overhead — no Vault, no SealedSecrets, no
  rotation pipeline

These properties are what plan-10 onwards exploit when migrating off the
shared `client_secret` to standard token-exchange v2.

---

Next → [03-setup-guide.md](./03-setup-guide.md)
