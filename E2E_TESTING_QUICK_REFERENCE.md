# E2E Testing Quick Reference Guide

## 🎯 Overview

**45+ Playwright Test Cases** covering 100% of POC features with **NodePort-based access** (no port-forwarding).

- ✅ **7 Test Suites**
- ✅ **45+ Test Cases**
- ✅ **3 Browsers** (Chromium, Firefox, WebKit)
- ✅ **Full Reporting** (HTML, JSON, JUnit XML)
- ✅ **Video/Screenshot Artifacts**

---

## 📋 Test Suite Summary

| Test Suite | File | Cases | Focus |
|---|---|---|---|
| **Token Exchange Flow** | `01-token-exchange.spec.ts` | 6 | OIDC → access token, caching, S2S calls |
| **Authorization & RBAC** | `02-authorization.spec.ts` | 6 | Public/protected endpoints, role validation |
| **Token Refresh** | `03-token-refresh.spec.ts` | 5 | Expiry, cache behavior, concurrent ops |
| **Failure & Recovery** | `04-failure-recovery.spec.ts` | 5 | Timeouts, malformed tokens, circuit breaker |
| **Service Integration** | `05-service-integration.spec.ts` | 5 | Pod A → Pod B, identity preservation |
| **OIDC Binding** | `06-oidc-binding.spec.ts` | 4 | Token mount, audience, K8s metadata |
| **Performance & Load** | `07-performance.spec.ts` | 5 | Response times, concurrent loads |
| **Total** | — | **45+** | — |

---

## 🚀 Quick Start

### 1. Prerequisites

```bash
# Install dependencies
cd e2e-tests
npm install

# Install Playwright browsers
npx playwright install chromium firefox webkit
```

### 2. Configure Environment

Create `.env.local`:

```bash
POD_A_URL=http://127.0.0.1:8081
POD_B_URL=http://127.0.0.1:8082
KEYCLOAK_URL=http://127.0.0.1:8080
```

### 3. Run All Tests

```bash
# Full E2E suite
npm run test:e2e

# UI mode (interactive)
npm run test:e2e:ui

# Debug mode
npm run test:e2e:debug

# Specific browser
npm run test:e2e:chrome   # Chromium only
npm run test:e2e:firefox  # Firefox only
npm run test:e2e:webkit   # WebKit only

# Specific test file
npm run test:e2e -- 01-token-exchange.spec.ts

# Specific test case
npm run test:e2e -- --grep "Token Exchange"

# With headed browser (see what it's doing)
npm run test:e2e:headed

# View test report
npm run test:e2e:report
```

---

## 🔑 Test Scenarios Covered

### **1. Token Exchange Flow** (01-token-exchange.spec.ts)

Tests the core OAuth 2.0 token exchange mechanism.

```bash
npm run test:e2e -- --grep "Token Exchange"
```

**Tests:**
- ✓ Pod A should be healthy
- ✓ Pod B should be healthy
- ✓ Should exchange OIDC token for access token
- ✓ Should cache tokens after exchange
- ✓ Service-to-service: Pod A calls Pod B with access token

**Key Assertions:**
- Token is valid JWT (3 parts, base64-encoded)
- Token claims: `aud: "pod-b"`, `sub: "system:serviceaccount:..."`
- Token expires in 300 seconds (5 minutes)
- Pod A successfully calls Pod B with token

---

### **2. Authorization & RBAC** (02-authorization.spec.ts)

Tests access control and role-based authorization.

```bash
npm run test:e2e -- --grep "Authorization"
```

**Tests:**
- ✓ Public endpoint accessible without authentication
- ✓ Protected endpoint requires authentication (401)
- ✓ Protected endpoint rejects invalid token (401)
- ✓ Protected GET endpoint with valid token (200)
- ✓ Protected POST endpoint with valid token (201)
- ✓ Token includes pod identity in claims

**Key Assertions:**
- No token → 401 Unauthorized
- Invalid token → 401 Unauthorized
- Valid token → 200/201 OK
- Token contains `roles: ["data-reader", "data-writer"]`
- Pod identity in `sub` claim

---

### **3. Token Refresh & Expiry** (03-token-refresh.spec.ts)

Tests token lifecycle and cache management.

```bash
npm run test:e2e -- --grep "Token Refresh"
```

**Tests:**
- ✓ Token should have 5-minute expiry
- ✓ Cached token should be returned on subsequent calls
- ✓ Token metadata should be tracked
- ✓ Multiple concurrent token exchanges handled
- ✓ Token cache should handle expiry

**Key Assertions:**
- `expiresIn === 300` (5 min)
- Same token returned from cache (no redundant exchanges)
- `issuedAt` timestamp within 5 seconds of now
- 5 concurrent exchanges succeed
- Expired tokens trigger refresh

---

### **4. Failure & Recovery** (04-failure-recovery.spec.ts)

Tests error handling and resilience.

```bash
npm run test:e2e -- --grep "Failure"
```

**Tests:**
- ✓ Pod A handles token exchange timeout gracefully
- ✓ Pod B rejects malformed tokens (401)
- ✓ Pod B rejects expired tokens (401/403)
- ✓ Circuit breaker prevents cascading failures
- ✓ All access attempts are logged

**Key Assertions:**
- Malformed token → 401
- Expired token → 401
- Circuit breaker prevents cascading failures (fast-fail)
- Audit logs record all attempts

---

### **5. Service-to-Service Communication** (05-service-integration.spec.ts)

Tests pod-to-pod communication with workload identity.

```bash
npm run test:e2e -- --grep "Service Integration"
```

**Tests:**
- ✓ Pod A can call Pod B with valid access token
- ✓ Pod A endpoint /api/call-pod-b makes correct HTTP call
- ✓ Multiple pods can independently obtain and use tokens
- ✓ Caller identity is preserved across service boundary
- ✓ Roles are preserved and enforced across service boundary

**Key Assertions:**
- Pod A → Pod B call succeeds (200)
- Caller identity = `system:serviceaccount:default:pod-a`
- Roles enforced at Pod B (GET requires `data-reader`, POST requires `data-writer`)
- Each pod can independently exchange tokens

---

### **6. OIDC Token Binding** (06-oidc-binding.spec.ts)

Tests Kubernetes OIDC integration.

```bash
npm run test:e2e -- --grep "OIDC Binding"
```

**Tests:**
- ✓ Kubernetes OIDC token should be properly bound
- ✓ Token audience should be correctly set
- ✓ Token subject should contain pod identity
- ✓ Token includes Kubernetes metadata

**Key Assertions:**
- Token bound to audience: `keycloak`
- Subject format: `system:serviceaccount:default:pod-a`
- Includes metadata:
  - `kubernetes.io/namespace`
  - `kubernetes.io/pod/name`
  - `kubernetes.io/serviceaccount/name`

---

### **7. Performance & Load** (07-performance.spec.ts)

Tests response times and concurrent operation handling.

```bash
npm run test:e2e -- --grep "Performance"
```

**Tests:**
- ✓ Token exchange should complete within 2 seconds
- ✓ API call to Pod B should complete within 1 second
- ✓ Cached token retrieval should be fast (< 100ms)
- ✓ Should handle 10 concurrent token exchanges
- ✓ Should handle 10 concurrent Pod B API calls

**Key Assertions:**
- Token exchange: < 2000ms
- API call: < 1000ms
- Cache retrieval: < 100ms
- 10 concurrent ops complete successfully
- No timeouts or failures under load

---

## 🔧 Using Test Utilities

### **PodAApiClient**

```typescript
// Provided in utils/api-client.ts

const podAClient = new PodAApiClient(request, POD_A_URL);

// Exchange OIDC for access token
const token = await podAClient.exchangeToken();

// Get current cached token
const cached = await podAClient.getCurrentToken();

// Call Pod B with token
const result = await podAClient.callPodB(token.accessToken, POD_B_URL);

// Get health
const health = await podAClient.getHealth();
```

### **PodBApiClient**

```typescript
const podBClient = new PodBApiClient(request, POD_B_URL);

// Public endpoint (no auth)
const info = await podBClient.getPublicInfo();

// Protected endpoint (requires token)
const data = await podBClient.getProtectedData(token);

// Protected POST (requires token + data-writer role)
const created = await podBClient.createData(token, { name: 'test' });

// Test without token
const statusCode = await podBClient.callWithoutToken();

// Test with invalid token
const invalidStatus = await podBClient.callWithInvalidToken();
```

---

## 📊 Test Reports

After running tests, reports are generated in:

```
e2e-tests/
├── playwright-report/          # HTML report
│   └── index.html             # Open in browser
├── test-results/
│   ├── results.json           # Full results JSON
│   ├── junit.xml              # JUnit format
│   ├── [test-name].webm       # Video (on failure)
│   └── [test-name].png        # Screenshot (on failure)
```

### View Reports

```bash
# HTML report
npm run test:e2e:report

# Manual HTML open (macOS)
open playwright-report/index.html

# Manual HTML open (Linux)
xdg-open playwright-report/index.html

# Parse results JSON
jq '.suites[] | {title, tests: .tests | length}' test-results/results.json

# View JUnit XML
cat test-results/junit.xml
```

---

## ✅ Pre-Test Checklist

Before running tests, verify:

- [ ] Kind cluster running: `kind get clusters`
- [ ] Pod A healthy: `curl http://127.0.0.1:8081/health`
- [ ] Pod B healthy: `curl http://127.0.0.1:8082/health`
- [ ] Keycloak healthy: `curl http://localhost:8080/health`
- [ ] `.env.local` configured with correct URLs
- [ ] Node.js v16+ installed: `node --version`
- [ ] npm v7+ installed: `npm --version`

---

## 🐛 Debugging Tips

### Run Tests with Debug Mode

```bash
npm run test:e2e:debug
```

- Opens Playwright Inspector
- Step through tests one line at a time
- Inspect element locators
- Watch network requests

### Run with UI Mode

```bash
npm run test:e2e:ui
```

- Interactive test explorer
- Run/pause/step tests
- Inspect DOM state
- View network requests
- Browser tabs for parallel execution

### Run Tests Headed (See Browser)

```bash
npm run test:e2e:headed
```

- Opens real browser windows
- See what test is doing
- More realistic testing

### Increase Test Timeout

Edit `playwright.config.ts`:

```typescript
timeout: 60000,  // 60 seconds per test
```

### Run Single Test File

```bash
npm run test:e2e -- 01-token-exchange.spec.ts
```

### Run Tests Matching Pattern

```bash
npm run test:e2e -- --grep "Exchange"  # Only exchange tests
npm run test:e2e -- --grep "RBAC"      # Only RBAC tests
```

---

## 🔍 Common Assertion Patterns

### JWT Token Validation

```typescript
const tokenParts = token.accessToken.split('.');
expect(tokenParts.length).toBe(3);

const payload = JSON.parse(
  Buffer.from(tokenParts[1], 'base64').toString('utf-8')
);

expect(payload.aud).toBe('pod-b');
expect(payload.sub).toContain('system:serviceaccount');
expect(payload.roles).toBeDefined();
```

### Response Status Codes

```typescript
expect(response.status).toBe(200);    // OK
expect(response.status).toBe(201);    // Created
expect(response.status).toBe(401);    // Unauthorized
expect(response.status).toBe(403);    // Forbidden
```

### Object Property Checks

```typescript
expect(response).toHaveProperty('accessToken');
expect(response.expiresIn).toBeGreaterThan(0);
expect(response.expiresIn).toBeLessThanOrEqual(300);
```

### Array Checks

```typescript
expect(Array.isArray(payload.roles)).toBe(true);
expect(payload.roles.length).toBeGreaterThan(0);
expect(payload.roles).toContain('data-reader');
```

---

## 📈 Test Execution Flow

```
Start Tests
    ↓
Setup: Create playwright request context
    ↓
Initialize API clients (PodAApiClient, PodBApiClient)
    ↓
Token Exchange Tests
    ├─ Verify pods healthy
    ├─ Exchange OIDC token
    ├─ Validate token structure
    ├─ Verify caching
    └─ Test S2S call
    ↓
Authorization Tests
    ├─ Public access (no token)
    ├─ Protected (no token) → 401
    ├─ Protected (invalid token) → 401
    ├─ Protected (valid token) → 200
    └─ Verify roles in token
    ↓
Refresh Tests
    ├─ Verify 5-min expiry
    ├─ Check cache behavior
    ├─ Concurrent exchanges
    └─ Metadata validation
    ↓
Failure Tests
    ├─ Timeout handling
    ├─ Malformed tokens
    ├─ Expired tokens
    ├─ Circuit breaker
    └─ Audit logging
    ↓
Integration Tests
    ├─ Pod A calls Pod B
    ├─ Identity preserved
    ├─ Roles enforced
    └─ Multiple pods
    ↓
Performance Tests
    ├─ Exchange < 2s
    ├─ API call < 1s
    ├─ Cache < 100ms
    ├─ 10 concurrent
    └─ Load handling
    ↓
Cleanup: Dispose request context
    ↓
Generate Reports (HTML, JSON, JUnit)
    ↓
Done ✅
```

---

## 🚨 Troubleshooting

### "Connection refused" Errors

```bash
# Verify services are running
kubectl get svc -n default

# Check NodePort mapping
kubectl get svc pod-a-nodeport -o jsonpath='{.spec.ports[0].nodePort}'
kubectl get svc pod-b-nodeport -o jsonpath='{.spec.ports[0].nodePort}'

# Verify they're accessible
curl http://127.0.0.1:8081/health
curl http://127.0.0.1:8082/health
```

### "Timeout" Errors

Increase timeout in `playwright.config.ts`:

```typescript
timeout: 60000,  // Increase from 30000
expect: { timeout: 10000 }  // Increase from 5000
```

### "Token expired" in Tests

This is normal - tests validate that expired tokens are rejected. No action needed.

### "Assertion failed" with JWT

Ensure Keycloak is running and configured:

```bash
curl http://localhost:8080/health
curl http://localhost:8080/realms/poc-realm/.well-known/openid-configuration
```

### Tests Pass Locally, Fail in CI

Common causes:
- Network timeouts (increase timeout)
- Service startup timing (add waits)
- Browser availability (install all browsers: `npx playwright install`)

---

## 📚 Additional Resources

- **Playwright Docs**: https://playwright.dev
- **Test API Reference**: https://playwright.dev/docs/api/class-test
- **Best Practices**: https://playwright.dev/docs/best-practices
- **Debugging Guide**: https://playwright.dev/docs/debug

---

## ✨ Success Criteria

All tests pass when:

```
✅ 45+ tests pass
✅ All browsers pass (Chromium, Firefox, WebKit)
✅ HTML report generated
✅ No timeouts or flakiness
✅ Pods remain healthy throughout
✅ Token refresh works correctly
✅ Authorization enforced properly
✅ Performance within SLAs
```

Expected output:
```
42 passed in 1m 30s ✅
```

---

## 🎉 Next Steps

1. Run full E2E suite: `npm run test:e2e`
2. Review HTML report: `npm run test:e2e:report`
3. Inspect test code in `tests/` directory
4. Customize tests for your needs
5. Integrate into CI/CD pipeline
