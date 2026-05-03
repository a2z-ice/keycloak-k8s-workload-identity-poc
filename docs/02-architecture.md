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

Next → [03-setup-guide.md](./03-setup-guide.md)
