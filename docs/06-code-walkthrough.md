# 06 — Code Walkthrough

An annotated tour of the Java + script + manifest source. Every reference is
a clickable link with a `file:line` suffix so you can jump to the exact
location.

---

## 6.1 pod-a (Spring Boot — Token Exchanger)

```
pod-a/
├── pom.xml
├── Dockerfile
└── src/main/
    ├── java/com/example/poda/
    │   ├── PodAApplication.java
    │   ├── config/RestTemplateConfig.java
    │   ├── service/OidcTokenProvider.java
    │   ├── service/TokenExchangeService.java
    │   ├── service/TokenCacheManager.java
    │   ├── controller/TokenController.java
    │   └── scheduler/TokenRefreshScheduler.java
    └── resources/
        ├── application.yml
        └── logback-spring.xml
```

### 6.1.1 Application bootstrap

[`pod-a/src/main/java/com/example/poda/PodAApplication.java:6-12`](../pod-a/src/main/java/com/example/poda/PodAApplication.java#L6-L12)

```java
@SpringBootApplication
@EnableScheduling
public class PodAApplication {
    public static void main(String[] args) {
        SpringApplication.run(PodAApplication.class, args);
    }
}
```

`@EnableScheduling` is needed for `TokenRefreshScheduler`'s `@Scheduled`
annotation.

### 6.1.2 Reading the mounted SA token

[`pod-a/src/main/java/com/example/poda/service/OidcTokenProvider.java`](../pod-a/src/main/java/com/example/poda/service/OidcTokenProvider.java)

The whole class is ~70 lines; key bits:

```java
@Value("${oidc.token.path:/var/run/secrets/tokens/jwt.token}")
private String tokenPath;

public String getOidcToken() throws IOException {
    Path path = Paths.get(tokenPath);
    if (!Files.exists(path)) {
        throw new IllegalStateException(
            "OIDC token not mounted. Ensure pod has serviceAccountToken projected volume.");
    }
    return Files.readString(path).trim();
}
```

Pod-a never *sends* this token to Keycloak (in the current
`client_credentials` flow), but it does:

* Read it on every `/api/exchange` to prove the file is mounted (logs
  `mounted-SA-token-len=...`)
* Expose it (length + JWT structure) at `/api/oidc/token-info` for the
  e2e suite

The mount is configured in
[`k8s-manifests/poc/03-pod-a-deployment.yaml:62-72`](../k8s-manifests/poc/03-pod-a-deployment.yaml#L62-L72):

```yaml
volumes:
  - name: oidc-token
    projected:
      sources:
        - serviceAccountToken:
            audience: keycloak-poc
            expirationSeconds: 3600
            path: jwt.token
```

The kubelet renews this token automatically (Kubernetes TokenRequest API).

### 6.1.3 Token exchange — the core

[`pod-a/src/main/java/com/example/poda/service/TokenExchangeService.java:48-86`](../pod-a/src/main/java/com/example/poda/service/TokenExchangeService.java#L48-L86)

```java
@CircuitBreaker(name = "keycloak", fallbackMethod = "exchangeFallback")
public TokenExchangeResponse exchange() throws IOException {
    String oidcToken = oidcTokenProvider.getOidcToken();   // demo / inspection
    OidcTokenProvider.PodMetadata pod = oidcTokenProvider.getPodMetadata();
    log.info("Workload identity: pod={}/{}, mounted-SA-token-len={}, audience={}",
        pod.getNamespace(), pod.getPodName(), oidcToken.length(), targetAudience);

    MultiValueMap<String, String> body = new LinkedMultiValueMap<>();
    body.add("grant_type",     "client_credentials");
    body.add("client_id",      clientId);
    body.add("client_secret",  clientSecret);
    body.add("audience",       targetAudience);
    // ...
    String responseBody = restTemplate.postForObject(tokenExchangeUrl, request, String.class);
    JsonNode json = objectMapper.readTree(responseBody);
    return TokenExchangeResponse.builder()
        .accessToken(json.get("access_token").asText())
        .tokenType (json.has("token_type") ? json.get("token_type").asText() : "Bearer")
        .expiresIn (json.has("expires_in") ? json.get("expires_in").asInt() : 300)
        .issuedAt  (Instant.now())
        .build();
}
```

Notable:
* `@CircuitBreaker(name="keycloak")` — Resilience4j; when Keycloak is down,
  cascading failures stop after a threshold (config in `application.yml`)
* `@Value`-injected `tokenExchangeUrl`, `clientId`, `clientSecret`,
  `targetAudience` — see `application.yml`
* The fallback throws — pod-a doesn't try to fake a token

### 6.1.4 Token cache

[`pod-a/src/main/java/com/example/poda/service/TokenCacheManager.java`](../pod-a/src/main/java/com/example/poda/service/TokenCacheManager.java)

* `ReentrantReadWriteLock` — many readers, single writer
* `getAccessToken()` — read-locked fast path, double-checked write-locked
  refresh on miss/expiry
* `put(token)` — write-lock seed (called by the controller after an exchange)
* `invalidate()` — write-lock clear (called by the scheduler)

Expiry buffer is 30 s — `isExpired()` returns `true` when there are < 30 s
left, so we refresh proactively rather than letting the next caller hit a
401:

[`TokenExchangeService.java:101-104`](../pod-a/src/main/java/com/example/poda/service/TokenExchangeService.java#L101-L104)

```java
public boolean isExpired() {
    return Instant.now().isAfter(issuedAt.plusSeconds(Math.max(0, expiresIn - 30)));
}
```

### 6.1.5 Background refresh

[`pod-a/src/main/java/com/example/poda/scheduler/TokenRefreshScheduler.java`](../pod-a/src/main/java/com/example/poda/scheduler/TokenRefreshScheduler.java)

```java
@Scheduled(fixedRateString = "${token.refresh.interval-ms:240000}",
           initialDelayString = "${token.refresh.initial-delay-ms:60000}")
public void refresh() {
    tokenCacheManager.invalidate();
    tokenCacheManager.getAccessToken();
}
```

* `fixedRate = 240_000ms` = every 4 min (token TTL is 5 min)
* `initialDelay = 60_000ms` so we don't hit Keycloak in the first 60 s of
  pod startup (avoids flake when pod-a comes up before Keycloak is fully
  ready)
* Failures are logged and **swallowed** — the next call to
  `getAccessToken()` will retry

### 6.1.6 REST controller

[`pod-a/src/main/java/com/example/poda/controller/TokenController.java`](../pod-a/src/main/java/com/example/poda/controller/TokenController.java)

| Method | Path | What it does |
|---|---|---|
| GET  | `/api/health` | static `{"status":"UP","pod":"pod-a"}` |
| POST | `/api/exchange` | calls `TokenExchangeService.exchange()`, seeds cache via `put()`, returns the new token |
| GET  | `/api/tokens/current` | returns the cached token (or 204 if cache is empty) |
| GET  | `/api/call-pod-b` | uses cached token, calls pod-b's `/api/protected/data`, returns the response |
| GET  | `/api/oidc/token-info` | metadata about the mounted K8s SA token (length, parts, namespace, pod name) |

### 6.1.7 application.yml

[`pod-a/src/main/resources/application.yml`](../pod-a/src/main/resources/application.yml)

Key lines:

```yaml
keycloak:
  server-url: ${KEYCLOAK_SERVER_URL:http://poc-keycloak.poc-keycloak.svc.cluster.local:8080}
  realm: ${KEYCLOAK_REALM:poc-realm}
  token-exchange-endpoint: ${keycloak.server-url}/realms/${keycloak.realm}/protocol/openid-connect/token
  client-id:     ${KEYCLOAK_CLIENT_ID:pod-a}
  client-secret: ${KEYCLOAK_CLIENT_SECRET:pod-a-secret}
  audience:      ${KEYCLOAK_AUDIENCE:pod-b}

oidc:
  token:
    path: ${OIDC_TOKEN_PATH:/var/run/secrets/tokens/jwt.token}

resilience4j:
  circuitbreaker:
    instances:
      keycloak:
        slidingWindowSize: 10
        failureRateThreshold: 50
        waitDurationInOpenState: 10s
```

All of these have safe defaults; the deployment overrides via env vars set
in [`k8s-manifests/poc/03-pod-a-deployment.yaml`](../k8s-manifests/poc/03-pod-a-deployment.yaml).

---

## 6.2 pod-b (Spring Boot — Resource Server)

```
pod-b/
├── pom.xml
├── Dockerfile
└── src/main/
    ├── java/com/example/podb/
    │   ├── PodBApplication.java
    │   ├── config/SecurityConfig.java
    │   ├── auth/PocJwtAuthenticationConverter.java
    │   ├── audit/AuditLogger.java
    │   ├── service/DataService.java
    │   └── controller/DataController.java
    └── resources/
        ├── application.yml
        └── logback-spring.xml
```

### 6.2.1 Security config

[`pod-b/src/main/java/com/example/podb/config/SecurityConfig.java`](../pod-b/src/main/java/com/example/podb/config/SecurityConfig.java)

```java
@Bean
public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
    http
        .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
        .authorizeHttpRequests(authz -> authz
            .requestMatchers("/api/health", "/api/public/**", "/actuator/**").permitAll()
            .requestMatchers(HttpMethod.GET,  "/api/protected/data").hasRole("data-reader")
            .requestMatchers(HttpMethod.POST, "/api/protected/create").hasRole("data-writer")
            .anyRequest().authenticated()
        )
        .oauth2ResourceServer(oauth2 -> oauth2
            .jwt(jwt -> jwt.jwtAuthenticationConverter(jwtAuthenticationConverter))
        )
        .csrf(c -> c.disable());
    return http.build();
}
```

Two layers of authz:

1. **URL-based:** `/api/health` and `/api/public/**` are open; everything
   else needs an authenticated principal.
2. **Method-based:** `@PreAuthorize` on the controllers (declared via
   `@EnableMethodSecurity(prePostEnabled = true)` at class level).

The `oauth2ResourceServer().jwt()` chain wires Spring to:
- Discover Keycloak's JWKS via `spring.security.oauth2.resourceserver.jwt.issuer-uri`
- Verify the RS256 signature on every incoming request
- Validate `iss`, `exp`, and `aud` claims
- Convert the JWT into a Spring `Authentication` via our custom
  `PocJwtAuthenticationConverter`

### 6.2.2 JWT → authorities

[`pod-b/src/main/java/com/example/podb/auth/PocJwtAuthenticationConverter.java:31-66`](../pod-b/src/main/java/com/example/podb/auth/PocJwtAuthenticationConverter.java#L31-L66)

```java
@Override
public AbstractAuthenticationToken convert(Jwt jwt) {
    Set<GrantedAuthority> authorities = new HashSet<>();

    // realm_access.roles
    Map<String, Object> realmAccess = jwt.getClaim("realm_access");
    if (realmAccess != null) {
        Object roles = realmAccess.get("roles");
        if (roles instanceof Collection<?> c) {
            for (Object r : c) authorities.add(new SimpleGrantedAuthority("ROLE_" + r));
        }
    }
    // resource_access.<client>.roles
    Map<String, Object> resourceAccess = jwt.getClaim("resource_access");
    if (resourceAccess != null) {
        for (Object v : resourceAccess.values()) {
            if (v instanceof Map<?, ?> m) {
                Object roles = m.get("roles");
                if (roles instanceof Collection<?> c) {
                    for (Object r : c) authorities.add(new SimpleGrantedAuthority("ROLE_" + r));
                }
            }
        }
    }
    // top-level "roles" claim (some flow shapes)
    Object flat = jwt.getClaim("roles");
    if (flat instanceof Collection<?> c) {
        for (Object r : c) authorities.add(new SimpleGrantedAuthority("ROLE_" + r));
    }

    String principal = jwt.getClaimAsString("sub");
    return new JwtAuthenticationToken(jwt, authorities, principal);
}
```

We deliberately handle three claim shapes — Keycloak's exact token shape
varies between grant types and feature versions. Walking all three keeps
the converter resilient.

The `ROLE_` prefix is essential: Spring Security's `hasRole("data-reader")`
matches against `ROLE_data-reader` (the `ROLE_` is implicit in `hasRole`,
which is *why* it must be present in the authority).

### 6.2.3 Audit logger

[`pod-b/src/main/java/com/example/podb/audit/AuditLogger.java:18-31`](../pod-b/src/main/java/com/example/podb/audit/AuditLogger.java#L18-L31)

```java
public void logAccess(String method, String endpoint, Authentication auth, String outcome) {
    Map<String, Object> event = new LinkedHashMap<>();
    event.put("timestamp", Instant.now().toString());
    event.put("method",   method);
    event.put("endpoint", endpoint);
    event.put("caller",   auth != null ? auth.getName() : "anonymous");
    event.put("roles",    auth == null ? List.of() :
        auth.getAuthorities().stream().map(GrantedAuthority::getAuthority).collect(toList()));
    event.put("outcome",  outcome);
    log.info("AUDIT: {}", json.writeValueAsString(event));
}
```

The `AUDIT: ` prefix is the schema marker — it's what
[`e2e-tests/tests/04-failure-recovery.spec.ts`](../e2e-tests/tests/04-failure-recovery.spec.ts)
greps for via `kubectl logs`.

### 6.2.4 Controller (the protected endpoints)

[`pod-b/src/main/java/com/example/podb/controller/DataController.java`](../pod-b/src/main/java/com/example/podb/controller/DataController.java)

```java
@PreAuthorize("hasRole('data-reader')")
@GetMapping("/protected/data")
public ResponseEntity<Map<String, Object>> getProtectedData(Authentication auth) {
    auditLogger.logAccess("GET", "/api/protected/data", auth, "ALLOWED");
    Map<String, Object> data = new HashMap<>(dataService.getProtectedData());
    data.put("callerIdentity", auth.getName());
    data.put("roles", auth.getAuthorities().stream()
        .map(a -> a.getAuthority()).collect(Collectors.toList()));
    return ResponseEntity.ok(data);
}

@PreAuthorize("hasRole('data-writer')")
@PostMapping("/protected/create")
public ResponseEntity<Map<String, Object>> createData(...) { ... 201 ... }
```

The audit log fires only when `@PreAuthorize` *passes* — denials are caught
by Spring Security's exception translator and surfaced as 401/403 (no audit
line is emitted for failed auth). If you want a "DENIED" audit line, add an
`AccessDeniedHandler` bean.

### 6.2.5 application.yml

[`pod-b/src/main/resources/application.yml`](../pod-b/src/main/resources/application.yml)

```yaml
spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          issuer-uri:  ${SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI:http://poc-keycloak.poc-keycloak.svc.cluster.local:8080/realms/poc-realm}
          jwk-set-uri: ${SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_JWK_SET_URI:${spring.security.oauth2.resourceserver.jwt.issuer-uri}/protocol/openid-connect/certs}
```

The double-injection of `issuer-uri` into `jwk-set-uri` makes both override
points work via env vars; the deployment manifest sets the env explicitly.

---

## 6.3 Realm-setup script

[`scripts/04-setup-poc-realm.sh`](../scripts/04-setup-poc-realm.sh)

A pure-bash, REST-API-driven realm bootstrap. Highlights:

| Section | Lines | What it does |
|---|---|---|
| Admin login | 17–28 | `curl POST /realms/master/.../token` with `admin/admin` |
| Realm | 33–43 | `POST /admin/realms` with `accessTokenLifespan=300` |
| Roles | 47–58 | `POST /admin/realms/poc-realm/roles` for `data-reader` + `data-writer` |
| `pod-b` client | 62–82 | Confidential, secret `pod-b-secret`, no flows enabled |
| `pod-a` client | 86–110 | Confidential, `serviceAccountsEnabled=true`, secret `pod-a-secret` |
| Audience mapper | 119–143 | `oidc-audience-mapper` on pod-a → `aud=pod-b` |
| SA-user roles | 147–166 | Assign realm roles to `service-account-pod-a` user |

Each step uses `case "${HTTP}"` to handle 201 (created) / 409 (already
exists) idempotently — re-running the script after `kubectl delete realm`
or against a half-applied realm is safe.

---

## 6.4 Kubernetes manifests

```
k8s-manifests/
├── 00-jwks-rbac.yaml            # ClusterRoleBinding (system:unauthenticated)
├── poc-keycloak/
│   ├── 01-namespace.yaml
│   ├── 02-deployment.yaml       # 1 replica, KC_FEATURES=token-exchange:v1,…
│   └── 03-service.yaml          # NodePort 30888
└── poc/
    ├── 01-namespace.yaml
    ├── 02-service-accounts.yaml # SA pod-a, SA pod-b
    ├── 03-pod-a-deployment.yaml # +projected SA token (audience=keycloak-poc)
    ├── 04-pod-a-service.yaml    # NodePort 30810
    ├── 05-pod-b-deployment.yaml # +SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_… env
    └── 06-pod-b-service.yaml    # NodePort 30820
```

Key snippets worth noting:

[`k8s-manifests/poc-keycloak/02-deployment.yaml:25-33`](../k8s-manifests/poc-keycloak/02-deployment.yaml#L25-L33)
```yaml
- name: KC_FEATURES
  value: "token-exchange:v1,admin-fine-grained-authz:v1"
- name: KC_HTTP_ENABLED
  value: "true"
- name: KC_HOSTNAME_STRICT
  value: "false"
- name: KC_HOSTNAME_STRICT_HTTPS
  value: "false"
```

[`k8s-manifests/poc-keycloak/02-deployment.yaml:37-41`](../k8s-manifests/poc-keycloak/02-deployment.yaml#L37-L41)
```yaml
# Trust the in-cluster Kubernetes API CA so the OIDC IdP can fetch
# JWKS from https://kubernetes.default.svc.cluster.local
- name: KC_TRUSTSTORE_PATHS
  value: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
```

[`k8s-manifests/poc/03-pod-a-deployment.yaml:62-72`](../k8s-manifests/poc/03-pod-a-deployment.yaml#L62-L72)
```yaml
volumes:
  - name: oidc-token
    projected:
      sources:
        - serviceAccountToken:
            audience: keycloak-poc
            expirationSeconds: 3600
            path: jwt.token
```

---

## 6.5 Test code

| File | Purpose |
|---|---|
| [`e2e-tests/playwright.config.ts`](../e2e-tests/playwright.config.ts) | 3 browsers, html/json/junit reporters, retains video on failure |
| [`e2e-tests/utils/api-client.ts`](../e2e-tests/utils/api-client.ts) | Reusable `PodAApiClient` + `PodBApiClient` |
| [`e2e-tests/utils/jwt-helper.ts`](../e2e-tests/utils/jwt-helper.ts) | `decodeJwt`, `audiences`, `rolesFromKeycloakJwt` |
| [`e2e-tests/tests/01-token-exchange.spec.ts`](../e2e-tests/tests/01-token-exchange.spec.ts) | Health + happy-path exchange + S2S |
| [`e2e-tests/tests/02-authorization.spec.ts`](../e2e-tests/tests/02-authorization.spec.ts) | Public/protected endpoints, RBAC |
| [`e2e-tests/tests/03-token-refresh.spec.ts`](../e2e-tests/tests/03-token-refresh.spec.ts) | TTL, cache, concurrency |
| [`e2e-tests/tests/04-failure-recovery.spec.ts`](../e2e-tests/tests/04-failure-recovery.spec.ts) | Tampered tokens, **kubectl logs grep for AUDIT** |
| [`e2e-tests/tests/05-service-integration.spec.ts`](../e2e-tests/tests/05-service-integration.spec.ts) | Identity preservation across S2S |
| [`e2e-tests/tests/06-oidc-binding.spec.ts`](../e2e-tests/tests/06-oidc-binding.spec.ts) | Token mount + Keycloak claims |
| [`e2e-tests/tests/07-performance.spec.ts`](../e2e-tests/tests/07-performance.spec.ts) | Latency SLAs, concurrency, sustained burst |

Total: **45 tests**, all passing on a fresh `poc-cluster`.

---

## 6.6 Where to make common changes

| Need | Edit |
|---|---|
| Add a new role | [`scripts/04-setup-poc-realm.sh`](../scripts/04-setup-poc-realm.sh) (`for ROLE in …` loop) + assign to SA user |
| Add a new pod-b endpoint | [`pod-b/.../controller/DataController.java`](../pod-b/src/main/java/com/example/podb/controller/DataController.java) + add `@PreAuthorize` |
| Change the access token TTL | `accessTokenLifespan` in realm `POST` body **and** the per-client `access.token.lifespan` attribute |
| Change pod-a refresh cadence | `token.refresh.interval-ms` env var (default 240_000 ms) |
| Add a new e2e test | drop a `.spec.ts` in [`e2e-tests/tests/`](../e2e-tests/tests/) using the existing api-client helpers |

---

Next → [07-troubleshooting.md](./07-troubleshooting.md)
