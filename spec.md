# From Pods to Permissions: Token Exchange meets Kubernetes Service Identity
## Complete Proof-of-Concept Specification

**Version**: 1.0  
**Last Updated**: May 2026  
**Scope**: Local kind cluster with Keycloak OIDC token exchange and Spring Boot workload identity

---

## 1. Executive Overview

This POC demonstrates a **production-grade zero-trust identity pattern** for Kubernetes workloads:

1. **Pod Identity**: A Kubernetes pod mounts a cryptographically-signed OIDC token (JWT)
2. **Token Exchange**: The pod exchanges its OIDC token with Keycloak for a scoped access token (RFC 8693)
3. **Service-to-Service**: Pod A uses the access token to call Pod B's REST API with proof of identity
4. **Authorization**: Pod B validates the token, extracts the calling pod's identity and roles, and enforces RBAC

**Key Properties**:
- ✅ **No shared secrets stored in pods** — OIDC token is ephemeral, cryptographically verified
- ✅ **Audience binding** — Tokens are scoped to specific resource audiences
- ✅ **Short-lived tokens** — 5-minute lifespan forces continuous refresh, limits blast radius
- ✅ **Fully auditable** — Every exchange logged with pod identity and outcome
- ✅ **Scalable** — Same pattern works across clusters, clouds, and multi-tenant scenarios

---

## 2. Architecture & Components

### 2.1 System Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                       KIND Cluster (Local)                       │
│                                                                   │
│  ┌──────────────────────────────┐    ┌──────────────────────┐   │
│  │  Pod A (Token Exchanger)     │    │  Pod B (API Server)  │   │
│  │  Spring Boot Application     │    │  Spring Boot Service │   │
│  │                              │    │                      │   │
│  │  1. Read OIDC token from:   │    │  - Resource Server   │   │
│  │     /var/run/secrets/tokens/ │    │  - Validates Bearer  │   │
│  │                              │    │    token             │   │
│  │  2. POST to Keycloak Token  │    │  - Enforces RBAC     │   │
│  │     Exchange endpoint        ├───>│    based on roles    │   │
│  │                              │    │  - Returns protected │   │
│  │  3. Receive access token    │<───┤    data              │   │
│  │                              │    │                      │   │
│  │  4. Call Pod B with token   │    │                      │   │
│  └──────────────────────────────┘    └──────────────────────┘   │
│         △              │                        △                │
│         │              └────────────────────────┘                │
│  ┌──────┴──────────────────────────────────┐                    │
│  │  Kubernetes OIDC Provider                │                    │
│  │  (Signed JWT: aud=keycloak, sub=pod)    │                    │
│  └───────────────────────────────────────────┘                   │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
                             │
                             │ HTTPS
                             ▼
                 ┌──────────────────────┐
                 │     Keycloak         │
                 │  (External to kind)  │
                 │                      │
                 │  - OIDC Provider     │
                 │    (validate JWTs)   │
                 │  - Token Exchange    │
                 │    (RFC 8693)        │
                 │  - Role Mapper       │
                 │  - Signature issuer  │
                 └──────────────────────┘
```

### 2.2 Component Breakdown

#### **2.2.1 Kind Cluster**
- **Purpose**: Local Kubernetes environment (replicates prod cluster)
- **Versions**: 
  - Kubernetes: 1.28+ (supports Kubernetes OIDC)
  - Container runtime: Docker/containerd (auto-configured by kind)
- **Features**:
  - OIDC service account tokens enabled by default
  - Service discovery via DNS (coredns)
  - Network policies (optional, for prod-like isolation)

#### **2.2.2 Pod A: Token Exchanger (Spring Boot)**
**Responsibility**: Demonstrate OIDC → access token flow

- **Framework**: Spring Boot 3.2+ with Spring Cloud Kubernetes
- **Key Components**:
  - `TokenExchangeService`: Reads OIDC token, calls Keycloak
  - `TokenCacheManager`: Caches tokens, refreshes on expiry
  - REST endpoints:
    - `GET /health` — health check
    - `GET /api/tokens/current` — returns current access token (for debugging)
    - `POST /api/exchange` — triggers token exchange (manual)
    - `GET /api/call-pod-b` — calls Pod B with cached token
  - `RestTemplate` configured with mutual TLS for Keycloak communication
  - Scheduled task that refreshes tokens every 4 minutes (before expiry)

#### **2.2.3 Pod B: Resource Server (Spring Boot)**
**Responsibility**: Validate incoming tokens and enforce authorization

- **Framework**: Spring Boot 3.2+ with Spring Security OAuth2 Resource Server
- **Key Components**:
  - `SecurityConfig`: Configures JWT validator, authority extraction
  - `JwtAuthenticationConverter`: Extracts roles/scopes from token claims
  - Protected REST endpoints:
    - `GET /health` — unprotected health check
    - `GET /api/public/info` — unprotected data
    - `GET /api/protected/data` — requires `ROLE_data-reader`
    - `POST /api/protected/create` — requires `ROLE_data-writer`
  - Logs every request with: pod identity, roles, action, outcome
  - Returns 403 Forbidden if token invalid or insufficient roles

#### **2.2.4 Keycloak (Standalone)**
**Responsibility**: Token exchange, JWT validation, role mapping

- **Deployment**: Docker container on host (not in kind; accessed via network)
- **Configuration**:
  - Realm: `poc-realm`
  - OIDC Provider: Kubernetes (configured to trust `https://kubernetes.default.svc`)
  - Clients:
    - `pod-a` (Pod A's identity; public client)
    - `pod-b` (Pod B's resource audience)
  - Users: `pod-a` (linked to Kubernetes service account)
  - Roles: `data-reader`, `data-writer` (mapped to pods via Kubernetes namespace/name)
  - Token Mappers: Script mapper that assigns roles based on pod identity

#### **2.2.5 Kubernetes OIDC Provider**
**Responsibility**: Issue signed JWTs for pods

- **Built-in**: Kubernetes API server auto-provides OIDC discovery
- **Endpoint**: `https://kubernetes.default.svc/.well-known/openid-configuration`
- **Discovery Document** lists:
  - `issuer`: cluster ID
  - `jwks_uri`: public key endpoint
  - Supported response types, claim types
- **Token Claims**:
  ```json
  {
    "iss": "https://kubernetes.default.svc",
    "sub": "system:serviceaccount:default:pod-a",
    "aud": ["keycloak"],
    "iat": 1234567890,
    "exp": 1234571490,
    "kubernetes.io/namespace": "default",
    "kubernetes.io/pod/name": "pod-a-xxx",
    "kubernetes.io/pod/uid": "abc123",
    "kubernetes.io/serviceaccount/name": "pod-a",
    "kubernetes.io/serviceaccount/uid": "def456"
  }
  ```

---

## 3. Prerequisites & Setup

### 3.1 Local Environment Requirements

```bash
# Required
- Docker Desktop or Docker daemon running
- kind CLI (v0.20+)
- kubectl (v1.28+)
- Java 17+ (for local development)
- Maven 3.9+ or Gradle 8+
- curl / httpie (for testing)

# Optional but recommended
- jq (JSON parsing in shell scripts)
- kubectx / kubens (cluster switching)
- k9s (Kubernetes TUI)
- Postman / Insomnia (API testing)
```

### 3.2 Initial Setup Script

```bash
#!/bin/bash
set -e

# 1. Create kind cluster with OIDC enabled (built-in)
kind create cluster --name poc-cluster --image kindest/node:v1.28.0

# 2. Verify OIDC discovery endpoint
kubectl get --raw /.well-known/openid-configuration | jq .

# 3. Start Keycloak (Docker on host; kind will access via host.docker.internal)
docker run -d \
  --name keycloak \
  -p 8080:8080 \
  -e KEYCLOAK_ADMIN=admin \
  -e KEYCLOAK_ADMIN_PASSWORD=admin \
  quay.io/keycloak/keycloak:23.0.0 \
  start-dev

# 4. Wait for Keycloak readiness
echo "Waiting for Keycloak startup..."
until curl -s http://localhost:8080/health | jq -e '.status == "UP"' > /dev/null; do
  sleep 2
done

echo "✅ Kind cluster ready"
echo "✅ Keycloak running on http://localhost:8080"
```

### 3.3 Keycloak Initial Configuration (via Admin Console)

1. **Access Admin Console**: http://localhost:8080/admin (admin/admin)

2. **Create Realm**: `poc-realm`

3. **Configure Kubernetes OIDC Provider**:
   - Realm Settings → Identity Providers → OpenID Connect v1.0
   - Name: `kubernetes`
   - Authorization URL: `https://kubernetes.default.svc/.well-known/openid-configuration`
   - Client ID: `keycloak`
   - Client Secret: [leave empty]
   - Use JWKS URL: ✅ enabled
   - **Important**: Configure HTTP client to trust kind cluster's CA
     - Realm Settings → General → HTTP Client
     - Truststore: Point to kind's CA cert (extracted from kubeconfig)

4. **Create Client**: `pod-a`
   - Client ID: `pod-a`
   - Name: Pod A (Token Exchanger)
   - Access Type: **public**
   - Valid Redirect URIs: `http://localhost:8081/*`
   - Advanced → Token Lifespan: `300` seconds (5 min)
   - Advanced → Access Token Format: `JWT`

5. **Create Client**: `pod-b`
   - Client ID: `pod-b`
   - Name: Pod B (Resource Server)
   - Access Type: **confidential**
   - Valid Redirect URIs: `http://localhost:8082/*`
   - Advanced → Token Lifespan: `300` seconds

6. **Create Realm Roles**:
   - `data-reader`
   - `data-writer`

7. **Create User**: `pod-a`
   - Username: `pod-a`
   - Email: `pod-a@example.com`
   - Role Mappings → Realm Roles: `data-reader`, `data-writer`

8. **Create Role Mapper** (Kubernetes → Keycloak):
   - Realm Settings → User Account → Token Mappers
   - Create Mapper: **Script Mapper**
   ```javascript
   // Maps Kubernetes service account to Keycloak user
   // If you need fine-grained role assignment based on pod identity
   if (user.name.startsWith('system:serviceaccount:default:pod-a')) {
     token.setRoles(['data-reader', 'data-writer']);
   } else {
     token.setRoles(['data-reader']);
   }
   ```

---

## 4. Project Structure

```
poc-keycloak-k8s/
├── spec.md                          # This file
├── README.md                        # Quick start guide
├── scripts/
│   ├── setup-kind.sh               # Create kind cluster
│   ├── setup-keycloak.sh           # Start Keycloak container
│   ├── deploy-pods.sh              # Build and deploy Spring apps
│   ├── test-flow.sh                # End-to-end test script
│   ├── cleanup.sh                  # Tear down everything
│   └── k8s-ca-to-keycloak.sh       # Extract kind CA for Keycloak
├── docker-compose.yml              # (Alternative) Run everything with compose
│
├── pod-a/                          # Token Exchanger (Spring Boot)
│   ├── pom.xml                    # Maven config (Spring Boot 3.2, Cloud K8s)
│   ├── src/main/java/
│   │   └── com/example/poda/
│   │       ├── PodAApplication.java
│   │       ├── config/
│   │       │   ├── SecurityConfig.java
│   │       │   └── RestTemplateConfig.java  # Keycloak HTTP client setup
│   │       ├── service/
│   │       │   ├── OidcTokenProvider.java   # Read OIDC token from filesystem
│   │       │   ├── TokenExchangeService.java # Exchange with Keycloak
│   │       │   └── TokenCacheManager.java    # Cache + refresh logic
│   │       ├── controller/
│   │       │   └── TokenController.java      # REST endpoints
│   │       └── scheduler/
│   │           └── TokenRefreshScheduler.java # Background refresh (every 4 min)
│   ├── src/main/resources/
│   │   ├── application.yml         # Spring Boot config
│   │   ├── application-local.yml   # Local dev overrides
│   │   └── logback-spring.xml      # Structured logging
│   └── Dockerfile
│
├── pod-b/                          # Resource Server (Spring Boot)
│   ├── pom.xml                    # Maven config (Spring Security OAuth2)
│   ├── src/main/java/
│   │   └── com/example/podb/
│   │       ├── PodBApplication.java
│   │       ├── config/
│   │       │   └── SecurityConfig.java       # OAuth2 Resource Server
│   │       ├── service/
│   │       │   ├── TokenValidationService.java
│   │       │   └── DataService.java          # Business logic
│   │       ├── controller/
│   │       │   └── DataController.java       # Protected REST endpoints
│   │       ├── auth/
│   │       │   ├── JwtAuthenticationConverter.java
│   │       │   └── PodIdentityExtractor.java # Extract caller identity
│   │       └── audit/
│   │           └── AuditLogger.java          # Log every request
│   ├── src/main/resources/
│   │   ├── application.yml
│   │   ├── application-local.yml
│   │   └── logback-spring.xml
│   └── Dockerfile
│
├── k8s-manifests/
│   ├── 01-namespaces.yaml          # default namespace (or create new)
│   ├── 02-service-accounts.yaml    # pod-a, pod-b service accounts
│   ├── 03-configmaps.yaml          # Spring Boot configs (app props)
│   ├── 04-pod-a-deployment.yaml    # Pod A deployment + service
│   ├── 05-pod-b-deployment.yaml    # Pod B deployment + service
│   ├── 06-keycloak-configmap.yaml  # Keycloak CA cert for kind validation
│   └── 07-rbac.yaml                # (Optional) RBAC roles
│
├── test-scenarios/
│   ├── e2e-flow.http               # REST Client file (VS Code extension)
│   ├── postman-collection.json     # Postman export
│   └── load-test.sh                # Load testing script
│
└── docs/
    ├── ARCHITECTURE.md             # Detailed architecture & flows
    ├── TROUBLESHOOTING.md          # Common issues
    ├── SECURITY.md                 # Security hardening checklist
    ├── SCALING.md                  # Multi-cluster federation
    └── MIGRATION.md                # Moving from secrets to OIDC
```

---

## 5. Spring Boot Implementation Details

### 5.1 Pod A: Token Exchanger

#### **5.1.1 Dependencies (pom.xml)**
```xml
<dependencies>
  <!-- Spring Boot -->
  <dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-web</artifactId>
    <version>3.2.0</version>
  </dependency>
  
  <!-- Spring Cloud Kubernetes -->
  <dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-kubernetes-client</artifactId>
    <version>3.1.0</version>
  </dependency>
  
  <!-- OAuth2 Client (for token exchange) -->
  <dependency>
    <groupId>org.springframework.security</groupId>
    <artifactId>spring-security-oauth2-client</artifactId>
    <version>6.2.0</version>
  </dependency>
  
  <!-- Resilience4j (for circuit breaker on Keycloak calls) -->
  <dependency>
    <groupId>io.github.resilience4j</groupId>
    <artifactId>resilience4j-spring-boot3</artifactId>
    <version>2.1.0</version>
  </dependency>
  
  <!-- Micrometer (metrics) -->
  <dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-core</artifactId>
    <version>1.12.0</version>
  </dependency>
  
  <!-- Logging -->
  <dependency>
    <groupId>net.logstash.logback</groupId>
    <artifactId>logstash-logback-encoder</artifactId>
    <version>7.4</version>
  </dependency>
</dependencies>
```

#### **5.1.2 OidcTokenProvider.java**
```java
package com.example.poda.service;

import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Optional;

/**
 * Reads Kubernetes OIDC token from mounted secret volume.
 * Token location: /var/run/secrets/tokens/jwt.token
 * Token audience: 'keycloak'
 */
@Slf4j
@Service
public class OidcTokenProvider {

  @Value("${oidc.token.path:/var/run/secrets/tokens/jwt.token}")
  private String tokenPath;

  @Value("${kubernetes.namespace:default}")
  private String namespace;

  @Value("${kubernetes.pod.name:unknown}")
  private String podName;

  /**
   * Reads and returns the OIDC token.
   * In local dev, returns a mock token (override with @ActiveProfiles("local"))
   */
  public String getOidcToken() throws IOException {
    Path path = Paths.get(tokenPath);
    
    if (!Files.exists(path)) {
      log.warn("OIDC token not found at {}. Running in non-Kubernetes environment?", tokenPath);
      throw new IllegalStateException("OIDC token not mounted. Ensure pod has serviceAccountToken volume.");
    }

    String token = Files.readString(path).trim();
    log.info("Read OIDC token for pod={}/{}, length={}", namespace, podName, token.length());
    
    return token;
  }

  /**
   * Extracts pod metadata from environment.
   * Used for audit logging.
   */
  public PodMetadata getPodMetadata() {
    return PodMetadata.builder()
      .namespace(namespace)
      .podName(podName)
      .hostname(System.getenv().getOrDefault("HOSTNAME", "unknown"))
      .build();
  }

  // DTO
  @lombok.Data
  @lombok.Builder
  public static class PodMetadata {
    private String namespace;
    private String podName;
    private String hostname;
  }
}
```

#### **5.1.3 TokenExchangeService.java**
```java
package com.example.poda.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.github.resilience4j.circuitbreaker.annotation.CircuitBreaker;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Service;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.client.RestTemplate;

import java.io.IOException;
import java.time.Instant;
import java.util.Optional;

/**
 * Exchanges Kubernetes OIDC token for Keycloak access token.
 * Implements RFC 8693: OAuth 2.0 Token Exchange.
 */
@Slf4j
@Service
public class TokenExchangeService {

  private final RestTemplate restTemplate;
  private final OidcTokenProvider oidcTokenProvider;
  private final ObjectMapper objectMapper;

  @Value("${keycloak.token-exchange-endpoint}")
  private String tokenExchangeUrl;

  @Value("${keycloak.audience:pod-b}")
  private String targetAudience;

  @Value("${keycloak.client-id:pod-a}")
  private String clientId;

  public TokenExchangeService(RestTemplate restTemplate, 
                              OidcTokenProvider oidcTokenProvider,
                              ObjectMapper objectMapper) {
    this.restTemplate = restTemplate;
    this.oidcTokenProvider = oidcTokenProvider;
    this.objectMapper = objectMapper;
  }

  /**
   * Exchange OIDC token for access token.
   * 
   * Request:
   *   grant_type=urn:ietf:params:oauth:grant-type:token-exchange
   *   subject_token=<oidc-jwt>
   *   subject_token_type=urn:ietf:params:oauth:token-type:jwt
   *   audience=pod-b
   *   requested_token_use=access
   */
  @CircuitBreaker(name = "keycloak", fallbackMethod = "exchangeFallback")
  public TokenExchangeResponse exchange() throws IOException {
    String oidcToken = oidcTokenProvider.getOidcToken();
    OidcTokenProvider.PodMetadata podMetadata = oidcTokenProvider.getPodMetadata();

    log.info("Exchanging OIDC token for audience={}, pod={}/{}", 
      targetAudience, podMetadata.getNamespace(), podMetadata.getPodName());

    // Prepare request body
    MultiValueMap<String, String> body = new LinkedMultiValueMap<>();
    body.add("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange");
    body.add("subject_token", oidcToken);
    body.add("subject_token_type", "urn:ietf:params:oauth:token-type:jwt");
    body.add("audience", targetAudience);
    body.add("requested_token_use", "access");
    body.add("client_id", clientId);

    HttpHeaders headers = new HttpHeaders();
    headers.setContentType(MediaType.APPLICATION_FORM_URLENCODED);

    HttpEntity<MultiValueMap<String, String>> request = new HttpEntity<>(body, headers);

    try {
      String responseBody = restTemplate.postForObject(
        tokenExchangeUrl,
        request,
        String.class
      );

      JsonNode responseJson = objectMapper.readTree(responseBody);
      
      TokenExchangeResponse response = TokenExchangeResponse.builder()
        .accessToken(responseJson.get("access_token").asText())
        .tokenType(responseJson.get("token_type").asText())
        .expiresIn(responseJson.get("expires_in").asInt())
        .issuedAt(Instant.now())
        .build();

      log.info("Token exchange successful, token expires in {} seconds", response.getExpiresIn());
      return response;

    } catch (Exception e) {
      log.error("Token exchange failed: {}", e.getMessage(), e);
      throw new RuntimeException("Token exchange failed", e);
    }
  }

  /**
   * Fallback if Keycloak is unavailable.
   */
  public TokenExchangeResponse exchangeFallback(IOException e) {
    log.error("Keycloak token exchange fallback triggered: {}", e.getMessage());
    throw new RuntimeException("Token exchange unavailable (circuit breaker open)", e);
  }

  // DTO
  @lombok.Data
  @lombok.Builder
  public static class TokenExchangeResponse {
    private String accessToken;
    private String tokenType;
    private int expiresIn;
    private Instant issuedAt;

    public boolean isExpired() {
      Instant expiryTime = issuedAt.plusSeconds(expiresIn - 30); // 30-sec buffer
      return Instant.now().isAfter(expiryTime);
    }
  }
}
```

#### **5.1.4 TokenCacheManager.java**
```java
package com.example.poda.service;

import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.util.Optional;
import java.util.concurrent.locks.ReentrantReadWriteLock;

/**
 * Caches access tokens and manages refresh.
 * Thread-safe with read/write locks.
 */
@Slf4j
@Service
public class TokenCacheManager {

  private final TokenExchangeService tokenExchangeService;
  private final ReentrantReadWriteLock lock = new ReentrantReadWriteLock();
  
  private TokenExchangeService.TokenExchangeResponse cachedToken;

  public TokenCacheManager(TokenExchangeService tokenExchangeService) {
    this.tokenExchangeService = tokenExchangeService;
  }

  /**
   * Returns valid token, refreshing if necessary.
   */
  public String getAccessToken() throws IOException {
    lock.readLock().lock();
    try {
      if (cachedToken != null && !cachedToken.isExpired()) {
        log.debug("Returning cached token (expires in {} seconds remaining)",
          cachedToken.getExpiresIn());
        return cachedToken.getAccessToken();
      }
    } finally {
      lock.readLock().unlock();
    }

    // Token expired or not present; refresh with write lock
    lock.writeLock().lock();
    try {
      // Double-check pattern
      if (cachedToken != null && !cachedToken.isExpired()) {
        return cachedToken.getAccessToken();
      }

      log.info("Token expired or missing; refreshing...");
      cachedToken = tokenExchangeService.exchange();
      return cachedToken.getAccessToken();

    } finally {
      lock.writeLock().unlock();
    }
  }

  public Optional<TokenExchangeService.TokenExchangeResponse> getCachedToken() {
    lock.readLock().lock();
    try {
      return Optional.ofNullable(cachedToken);
    } finally {
      lock.readLock().unlock();
    }
  }
}
```

#### **5.1.5 TokenController.java**
```java
package com.example.poda.controller;

import com.example.poda.service.OidcTokenProvider;
import com.example.poda.service.TokenCacheManager;
import com.example.poda.service.TokenExchangeService;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.client.RestTemplate;

import java.io.IOException;
import java.util.HashMap;
import java.util.Map;
import java.util.Optional;

@Slf4j
@RestController
@RequestMapping("/api")
public class TokenController {

  private final TokenCacheManager tokenCacheManager;
  private final TokenExchangeService tokenExchangeService;
  private final OidcTokenProvider oidcTokenProvider;
  private final RestTemplate restTemplate;

  public TokenController(TokenCacheManager tokenCacheManager,
                        TokenExchangeService tokenExchangeService,
                        OidcTokenProvider oidcTokenProvider,
                        RestTemplate restTemplate) {
    this.tokenCacheManager = tokenCacheManager;
    this.tokenExchangeService = tokenExchangeService;
    this.oidcTokenProvider = oidcTokenProvider;
    this.restTemplate = restTemplate;
  }

  @GetMapping("/health")
  public ResponseEntity<Map<String, String>> health() {
    return ResponseEntity.ok(Map.of("status", "UP", "pod", "pod-a"));
  }

  /**
   * Returns current cached access token (debugging).
   */
  @GetMapping("/tokens/current")
  public ResponseEntity<Map<String, Object>> getCurrentToken() {
    Optional<TokenExchangeService.TokenExchangeResponse> token = tokenCacheManager.getCachedToken();
    
    Map<String, Object> response = new HashMap<>();
    if (token.isPresent()) {
      response.put("token", token.get().getAccessToken());
      response.put("expiresIn", token.get().getExpiresIn());
      response.put("issuedAt", token.get().getIssuedAt());
      response.put("expired", token.get().isExpired());
      return ResponseEntity.ok(response);
    }
    
    response.put("message", "No token cached");
    return ResponseEntity.noContent().build();
  }

  /**
   * Manually trigger token exchange (debugging).
   */
  @PostMapping("/exchange")
  public ResponseEntity<Map<String, Object>> exchangeToken() throws IOException {
    TokenExchangeService.TokenExchangeResponse response = tokenExchangeService.exchange();
    
    Map<String, Object> result = new HashMap<>();
    result.put("accessToken", response.getAccessToken());
    result.put("expiresIn", response.getExpiresIn());
    result.put("issuedAt", response.getIssuedAt());
    
    return ResponseEntity.ok(result);
  }

  /**
   * Call Pod B's protected endpoint with token.
   * Demonstrates service-to-service communication with workload identity.
   */
  @GetMapping("/call-pod-b")
  public ResponseEntity<Map<String, Object>> callPodB(
    @RequestParam(defaultValue = "http://pod-b:8082") String podBUrl
  ) throws IOException {
    
    String accessToken = tokenCacheManager.getAccessToken();
    String url = podBUrl + "/api/protected/data";
    
    log.info("Calling Pod B at {} with access token", url);
    
    try {
      // Note: RestTemplate is configured in RestTemplateConfig to handle Bearer tokens
      org.springframework.http.HttpHeaders headers = 
        new org.springframework.http.HttpHeaders();
      headers.setBearerAuth(accessToken);
      
      org.springframework.http.HttpEntity<Void> request = 
        new org.springframework.http.HttpEntity<>(headers);
      
      String responseBody = restTemplate.getForObject(url, String.class);
      
      Map<String, Object> response = new HashMap<>();
      response.put("message", "Successfully called Pod B");
      response.put("response", responseBody);
      response.put("url", url);
      
      return ResponseEntity.ok(response);
      
    } catch (Exception e) {
      log.error("Failed to call Pod B: {}", e.getMessage(), e);
      
      Map<String, Object> error = new HashMap<>();
      error.put("error", e.getMessage());
      error.put("url", url);
      
      return ResponseEntity.status(500).body(error);
    }
  }
}
```

#### **5.1.6 application.yml**
```yaml
spring:
  application:
    name: pod-a
  
  cloud:
    kubernetes:
      client:
        namespace: default
      config:
        enabled: true

server:
  port: 8081
  servlet:
    context-path: /

keycloak:
  server-url: https://host.docker.internal:8443  # Host machine's Keycloak
  realm: poc-realm
  token-exchange-endpoint: https://host.docker.internal:8443/realms/poc-realm/protocol/openid-connect/token
  client-id: pod-a
  audience: pod-b

oidc:
  token:
    path: /var/run/secrets/tokens/jwt.token

kubernetes:
  namespace: default
  pod:
    name: ${HOSTNAME:pod-a}

management:
  endpoints:
    web:
      exposure:
        include: health,metrics,prometheus
  endpoint:
    health:
      show-details: always
  metrics:
    export:
      prometheus:
        enabled: true

logging:
  level:
    com.example.poda: DEBUG
    org.springframework.security: INFO
  pattern:
    console: "%d{yyyy-MM-dd HH:mm:ss} - %logger{36} - %msg%n"
```

### 5.2 Pod B: Resource Server

#### **5.2.1 SecurityConfig.java**
```java
package com.example.podb.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.web.SecurityFilterChain;

/**
 * OAuth2 Resource Server configuration.
 * Validates JWT tokens from Keycloak.
 */
@Configuration
@EnableWebSecurity
@EnableMethodSecurity(prePostEnabled = true)
public class SecurityConfig {

  private final JwtAuthenticationConverter jwtAuthenticationConverter;

  public SecurityConfig(JwtAuthenticationConverter jwtAuthenticationConverter) {
    this.jwtAuthenticationConverter = jwtAuthenticationConverter;
  }

  @Bean
  public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
    http
      .sessionManagement()
        .sessionCreationPolicy(SessionCreationPolicy.STATELESS)
        .and()
      .authorizeHttpRequests((authz) -> authz
        .requestMatchers("/health", "/api/public/**").permitAll()
        .requestMatchers(HttpMethod.GET, "/api/protected/data")
          .hasRole("data-reader")
        .requestMatchers(HttpMethod.POST, "/api/protected/create")
          .hasRole("data-writer")
        .anyRequest().authenticated()
      )
      .oauth2ResourceServer((oauth2) -> oauth2
        .jwt((jwt) -> jwt
          .jwtAuthenticationConverter(jwtAuthenticationConverter)
        )
      )
      .cors()
        .and()
      .csrf().disable();

    return http.build();
  }
}
```

#### **5.2.2 JwtAuthenticationConverter.java**
```java
package com.example.podb.auth;

import lombok.extern.slf4j.Slf4j;
import org.springframework.core.convert.converter.Converter;
import org.springframework.security.authentication.AbstractAuthenticationToken;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.security.oauth2.server.resource.authentication.JwtGrantedAuthoritiesConverter;
import org.springframework.stereotype.Component;

import java.util.Collection;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Converts JWT to Spring Authentication.
 * Extracts roles from token claims.
 */
@Slf4j
@Component
public class JwtAuthenticationConverter implements Converter<Jwt, AbstractAuthenticationToken> {

  private final JwtGrantedAuthoritiesConverter authoritiesConverter;

  public JwtAuthenticationConverter() {
    this.authoritiesConverter = new JwtGrantedAuthoritiesConverter();
    this.authoritiesConverter.setAuthorityPrefix("ROLE_");
    this.authoritiesConverter.setAuthoritiesClaimName("roles");
  }

  @Override
  public AbstractAuthenticationToken convert(Jwt jwt) {
    Collection<GrantedAuthority> authorities = extractAuthorities(jwt);
    String principalClaimValue = jwt.getClaimAsString("sub"); // Pod identity
    
    log.info("JWT Authentication: subject={}, authorities={}", 
      principalClaimValue, authorities);
    
    return new JwtAuthenticationToken(jwt, authorities, principalClaimValue);
  }

  /**
   * Extract roles from JWT claims.
   * Looks for 'roles' array in JWT.
   */
  private Collection<GrantedAuthority> extractAuthorities(Jwt jwt) {
    Set<GrantedAuthority> authorities = new HashSet<>(
      authoritiesConverter.convert(jwt)
    );

    // Also check for roles claim directly
    if (jwt.hasClaim("roles")) {
      @SuppressWarnings("unchecked")
      List<String> roles = jwt.getClaimAsStringList("roles");
      for (String role : roles) {
        authorities.add(new SimpleGrantedAuthority("ROLE_" + role));
      }
    }

    return authorities;
  }
}
```

#### **5.2.3 DataController.java**
```java
package com.example.podb.controller;

import com.example.podb.audit.AuditLogger;
import com.example.podb.service.DataService;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

import java.util.HashMap;
import java.util.Map;

@Slf4j
@RestController
@RequestMapping("/api")
public class DataController {

  private final DataService dataService;
  private final AuditLogger auditLogger;

  public DataController(DataService dataService, AuditLogger auditLogger) {
    this.dataService = dataService;
    this.auditLogger = auditLogger;
  }

  @GetMapping("/health")
  public ResponseEntity<Map<String, String>> health() {
    return ResponseEntity.ok(Map.of("status", "UP", "pod", "pod-b"));
  }

  /**
   * Public endpoint (no auth required).
   */
  @GetMapping("/public/info")
  public ResponseEntity<Map<String, String>> getPublicInfo() {
    return ResponseEntity.ok(Map.of(
      "app", "pod-b",
      "type", "resource-server",
      "version", "1.0.0"
    ));
  }

  /**
   * Protected endpoint: requires ROLE_data-reader.
   */
  @PreAuthorize("hasRole('data-reader')")
  @GetMapping("/protected/data")
  public ResponseEntity<Map<String, Object>> getProtectedData(Authentication auth) {
    auditLogger.logAccess("GET", "/api/protected/data", auth, "ALLOWED");
    
    String callerIdentity = auth.getName(); // Pod identity from JWT
    log.info("Caller identity: {}", callerIdentity);

    Map<String, Object> data = dataService.getProtectedData();
    data.put("callerIdentity", callerIdentity);
    data.put("roles", auth.getAuthorities());

    return ResponseEntity.ok(data);
  }

  /**
   * Protected endpoint: requires ROLE_data-writer.
   */
  @PreAuthorize("hasRole('data-writer')")
  @PostMapping("/protected/create")
  public ResponseEntity<Map<String, Object>> createData(
    @RequestBody Map<String, String> payload,
    Authentication auth
  ) {
    auditLogger.logAccess("POST", "/api/protected/create", auth, "ALLOWED");
    
    String result = dataService.createData(payload);

    Map<String, Object> response = new HashMap<>();
    response.put("status", "created");
    response.put("data", result);
    response.put("callerIdentity", auth.getName());

    return ResponseEntity.status(201).body(response);
  }
}
```

#### **5.2.4 AuditLogger.java**
```java
package com.example.podb.audit;

import lombok.extern.slf4j.Slf4j;
import org.springframework.security.core.Authentication;
import org.springframework.stereotype.Component;

import java.time.Instant;
import java.util.HashMap;
import java.util.Map;

/**
 * Structured audit logging for all access attempts.
 */
@Slf4j
@Component
public class AuditLogger {

  public void logAccess(String method, String endpoint, Authentication auth, String outcome) {
    Map<String, Object> auditEvent = new HashMap<>();
    auditEvent.put("timestamp", Instant.now());
    auditEvent.put("method", method);
    auditEvent.put("endpoint", endpoint);
    auditEvent.put("caller", auth.getName());
    auditEvent.put("roles", auth.getAuthorities());
    auditEvent.put("outcome", outcome);

    log.info("AUDIT: {}", auditEvent);
  }

  public void logAccessDenied(String method, String endpoint, Authentication auth, String reason) {
    Map<String, Object> auditEvent = new HashMap<>();
    auditEvent.put("timestamp", Instant.now());
    auditEvent.put("method", method);
    auditEvent.put("endpoint", endpoint);
    auditEvent.put("caller", auth.getName());
    auditEvent.put("roles", auth.getAuthorities());
    auditEvent.put("outcome", "DENIED");
    auditEvent.put("reason", reason);

    log.warn("AUDIT: {}", auditEvent);
  }
}
```

---

## 6. Kubernetes Manifests

### 6.1 Service Accounts & OIDC Token Binding

**File**: `k8s-manifests/02-service-accounts.yaml`

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pod-a
  namespace: default

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pod-b
  namespace: default
```

### 6.2 Pod A Deployment

**File**: `k8s-manifests/04-pod-a-deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pod-a
  namespace: default
  labels:
    app: pod-a

spec:
  replicas: 1
  selector:
    matchLabels:
      app: pod-a
  template:
    metadata:
      labels:
        app: pod-a
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8081"
        prometheus.io/path: "/actuator/prometheus"
    spec:
      serviceAccountName: pod-a
      containers:
      - name: app
        image: pod-a:latest
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8081
          name: http
        
        env:
        - name: KUBERNETES_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: KUBERNETES_POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: HOSTNAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        
        # Pod A specific configuration
        - name: KEYCLOAK_SERVER_URL
          value: "https://host.docker.internal:8443"
        - name: KEYCLOAK_REALM
          value: "poc-realm"
        - name: KEYCLOAK_CLIENT_ID
          value: "pod-a"
        - name: KEYCLOAK_AUDIENCE
          value: "pod-b"
        
        livenessProbe:
          httpGet:
            path: /health
            port: 8081
          initialDelaySeconds: 30
          periodSeconds: 10
        
        readinessProbe:
          httpGet:
            path: /health
            port: 8081
          initialDelaySeconds: 10
          periodSeconds: 5
        
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        
        # Mount OIDC token
        volumeMounts:
        - name: oidc-token
          mountPath: /var/run/secrets/tokens
          readOnly: true
      
      volumes:
      # Projected volume with service account token bound to 'keycloak' audience
      - name: oidc-token
        projected:
          sources:
          - serviceAccountToken:
              audience: keycloak
              expirationSeconds: 3600
              path: jwt.token

---
apiVersion: v1
kind: Service
metadata:
  name: pod-a
  namespace: default
spec:
  selector:
    app: pod-a
  ports:
  - port: 8081
    targetPort: 8081
    name: http
  type: ClusterIP
```

### 6.3 Pod B Deployment

**File**: `k8s-manifests/05-pod-b-deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pod-b
  namespace: default
  labels:
    app: pod-b

spec:
  replicas: 1
  selector:
    matchLabels:
      app: pod-b
  template:
    metadata:
      labels:
        app: pod-b
    spec:
      serviceAccountName: pod-b
      containers:
      - name: app
        image: pod-b:latest
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8082
          name: http
        
        env:
        - name: KUBERNETES_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: KUBERNETES_POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        
        # Pod B specific configuration
        - name: SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI
          value: "https://host.docker.internal:8443/realms/poc-realm"
        - name: SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_JWK_SET_URI
          value: "https://host.docker.internal:8443/realms/poc-realm/protocol/openid-connect/certs"
        
        livenessProbe:
          httpGet:
            path: /health
            port: 8082
          initialDelaySeconds: 30
          periodSeconds: 10
        
        readinessProbe:
          httpGet:
            path: /health
            port: 8082
          initialDelaySeconds: 10
          periodSeconds: 5
        
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "500m"

---
apiVersion: v1
kind: Service
metadata:
  name: pod-b
  namespace: default
spec:
  selector:
    app: pod-b
  ports:
  - port: 8082
    targetPort: 8082
    name: http
  type: ClusterIP
```

---

## 7. Testing & Validation

### 7.1 End-to-End Test Script

**File**: `scripts/test-flow.sh`

```bash
#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== Testing Token Exchange Flow ===${NC}\n"

# 1. Get Pod A's service endpoint
echo -e "${YELLOW}Step 1: Get Pod A endpoint...${NC}"
POD_A_POD=$(kubectl get pods -l app=pod-a -o jsonpath='{.items[0].metadata.name}')
echo -e "${GREEN}Pod A: $POD_A_POD${NC}\n"

# 2. Port-forward to Pod A
echo -e "${YELLOW}Step 2: Port-forward to Pod A...${NC}"
kubectl port-forward "pod/$POD_A_POD" 8081:8081 &
PF_PID=$!
sleep 2
echo -e "${GREEN}Port-forward started (PID: $PF_PID)${NC}\n"

# 3. Check Pod A health
echo -e "${YELLOW}Step 3: Check Pod A health...${NC}"
curl -s http://localhost:8081/health | jq .
echo -e ""

# 4. Trigger token exchange
echo -e "${YELLOW}Step 4: Exchange OIDC token for access token...${NC}"
TOKEN_RESPONSE=$(curl -s -X POST http://localhost:8081/api/exchange)
echo "$TOKEN_RESPONSE" | jq .
ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.accessToken')
echo -e "${GREEN}Access token obtained (length: ${#ACCESS_TOKEN})${NC}\n"

# 5. Get Pod B's service endpoint
echo -e "${YELLOW}Step 5: Get Pod B endpoint...${NC}"
POD_B_POD=$(kubectl get pods -l app=pod-b -o jsonpath='{.items[0].metadata.name}')
echo -e "${GREEN}Pod B: $POD_B_POD${NC}\n"

# 6. Call Pod B's protected endpoint with token
echo -e "${YELLOW}Step 6: Call Pod B protected endpoint...${NC}"
curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
  http://pod-b:8082/api/protected/data | jq .
echo -e ""

# 7. Cleanup
echo -e "${YELLOW}Step 7: Cleanup...${NC}"
kill $PF_PID
echo -e "${GREEN}Port-forward closed${NC}\n"

echo -e "${GREEN}✅ End-to-end test completed successfully!${NC}"
```

### 7.2 Manual Testing with curl

```bash
# Terminal 1: Port-forward Pod A
kubectl port-forward svc/pod-a 8081:8081

# Terminal 2: Port-forward Pod B
kubectl port-forward svc/pod-b 8082:8082

# Terminal 3: Test flows
# Exchange token
curl -X POST http://localhost:8081/api/exchange | jq .

# Call Pod B (will fail without valid token)
curl http://localhost:8082/api/protected/data

# Call Pod B with token (will succeed)
TOKEN=$(curl -s -X POST http://localhost:8081/api/exchange | jq -r '.accessToken')
curl -H "Authorization: Bearer $TOKEN" http://localhost:8082/api/protected/data
```

---

## 8. Security Hardening Checklist

- [ ] **Keycloak HTTPS**: Configure TLS certificates (self-signed for local, proper certs for prod)
- [ ] **Mutual TLS**: Pod → Keycloak uses client certificates
- [ ] **Token expiry**: Keep at 5 minutes; force refresh on each use
- [ ] **Audience binding**: Every token scoped to specific resource audience
- [ ] **Role mapping**: Fine-grained policies; least-privilege principle
- [ ] **Network policies**: Restrict pod-to-pod communication in prod
- [ ] **RBAC**: Service accounts with minimal permissions
- [ ] **Audit logging**: Every token exchange logged with pod identity
- [ ] **Secret management**: Keycloak admin password in sealed secrets or vault
- [ ] **Certificate rotation**: Automated renewal for all mTLS certs

---

## 9. Observability & Monitoring

### 9.1 Metrics to Track

- **Token exchange latency**: P50, P95, P99 (histogram)
- **Token exchange failures**: Count by reason (auth failure, network, timeout)
- **Token cache hit rate**: Percentage of requests served from cache
- **Pod B authorization denials**: Count by pod/role
- **Keycloak availability**: Percentage of successful token exchanges

### 9.2 Logging Strategy

```json
{
  "timestamp": "2026-05-03T12:00:00Z",
  "level": "INFO",
  "logger": "com.example.poda.service.TokenExchangeService",
  "pod_namespace": "default",
  "pod_name": "pod-a-xyz",
  "event": "TOKEN_EXCHANGE_SUCCESS",
  "keycloak_url": "https://host.docker.internal:8443",
  "audience": "pod-b",
  "token_expires_in": 300,
  "duration_ms": 145
}
```

---

## 10. Multi-Cluster & Production Deployment

### 10.1 Scaling Considerations

- **Multiple clusters**: Each cluster runs its own Keycloak instance OR federate to central Keycloak
- **High availability**: Keycloak HA setup with persistent storage
- **Token refresh optimization**: Use sidecar pattern to minimize pod restart impact
- **Network segmentation**: Isolate Keycloak on private network; pods access via service mesh (Istio)

### 10.2 Production Checklist

- [ ] Replace `host.docker.internal` with proper DNS names
- [ ] Use production-grade Keycloak deployment (Helm chart recommended)
- [ ] Enable database persistence for Keycloak (PostgreSQL)
- [ ] Implement Keycloak clustering / HA
- [ ] Use proper TLS certificates (Let's Encrypt or corporate CA)
- [ ] Deploy sidecar token manager for automatic refresh
- [ ] Set up centralized logging (ELK, Grafana Loki)
- [ ] Configure alerts for token exchange failures
- [ ] Implement chaos engineering tests (kill Keycloak, test fallback)
- [ ] Documentation for runbook: "Keycloak outage procedure"

---

## 11. Troubleshooting Guide

| Issue | Symptom | Resolution |
|-------|---------|------------|
| **Pod can't reach Keycloak** | Connection timeout to `host.docker.internal:8443` | Ensure Docker daemon runs Keycloak; verify networking in kind config |
| **OIDC token not mounted** | IOException: `/var/run/secrets/tokens/jwt.token` not found | Check `serviceAccountToken` volume in pod spec; verify service account exists |
| **Token validation fails** | "Invalid token signature" in Pod B logs | Keycloak OIDC provider not configured; verify `issuer_uri` matches Kubernetes OIDC endpoint |
| **Role not appearing in token** | 403 Forbidden despite valid token | Check Keycloak role mapper configuration; verify user mapped to roles |
| **Audience mismatch** | Token exchange succeeds but Pod B rejects token | Ensure `audience` claim in token matches Pod B's validation setting |

---

## 12. Implementation Timeline

**Phase 1 (Day 1-2)**: Setup
- [ ] Create kind cluster
- [ ] Deploy Keycloak
- [ ] Configure Kubernetes OIDC provider in Keycloak
- [ ] Test OIDC token generation

**Phase 2 (Day 2-3)**: Spring Boot Implementation
- [ ] Implement Pod A (token exchanger)
- [ ] Implement Pod B (resource server)
- [ ] Test token exchange flow locally

**Phase 3 (Day 3)**: Kubernetes Deployment
- [ ] Build Docker images
- [ ] Deploy manifests to kind
- [ ] Test service-to-service communication

**Phase 4 (Day 4)**: Hardening & Observability
- [ ] Add audit logging
- [ ] Configure metrics/monitoring
- [ ] Security hardening (mTLS, RBAC, network policies)

---

## 13. Appendix: Key Files Generated

After implementation, you'll have:

```
├── pod-a/target/pod-a-1.0.0.jar
├── pod-b/target/pod-b-1.0.0.jar
├── docker-builds/
│   ├── pod-a-latest.tar (Docker image)
│   └── pod-b-latest.tar (Docker image)
├── k8s-manifests/
│   └── all YAML files applied to kind
└── test-results/
    ├── e2e-flow-passed.log
    ├── metrics-export.json
    └── audit-logs.log
```

---

## 14. References & Documentation

- [Kubernetes OIDC Discovery](https://kubernetes.io/docs/reference/access-authn-authz/authentication/)
- [RFC 8693: OAuth 2.0 Token Exchange](https://tools.ietf.org/html/rfc8693)
- [Keycloak Token Exchange](https://www.keycloak.org/docs/latest/server_admin/#token-exchange)
- [Spring Security OAuth2 Resource Server](https://spring.io/projects/spring-security-oauth2-resource-server)
- [kind Documentation](https://kind.sigs.k8s.io/)
- [Spring Cloud Kubernetes](https://spring.io/projects/spring-cloud-kubernetes)

---

**Document Version**: 1.0  
**Last Review**: May 2026  
**Status**: Ready for Implementation  
**Reviewer**: Senior Cloud Architect
