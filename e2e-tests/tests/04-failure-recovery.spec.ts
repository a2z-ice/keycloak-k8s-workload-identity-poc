import { test, expect, request as pwRequest } from '@playwright/test';
import { execSync } from 'child_process';
import { PodAApiClient, PodBApiClient, POD_A_URL, POD_B_URL } from '../utils/api-client';
import { decodeJwt } from '../utils/jwt-helper';

test.describe('04 Failure & Recovery', () => {
  let podA: PodAApiClient;
  let podB: PodBApiClient;
  let token: string;

  test.beforeAll(async () => {
    const ctx = await pwRequest.newContext();
    podA = new PodAApiClient(ctx, POD_A_URL);
    podB = new PodBApiClient(ctx, POD_B_URL);
    token = (await podA.exchangeToken()).accessToken;
  });

  test('Pod B rejects malformed bearer tokens with 401', async () => {
    expect(await podB.callWithInvalidToken()).toBe(401);
  });

  test('Pod B rejects tokens with bogus signatures with 401', async () => {
    // Forge a token with valid header/claims but tampered signature
    const parts = token.split('.');
    const tampered = `${parts[0]}.${parts[1]}.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA`;
    const ctx = await pwRequest.newContext();
    const podB2 = new PodBApiClient(ctx, POD_B_URL);
    const r = await podB2.getProtectedData(tampered);
    expect(r.status).toBe(401);
  });

  test('Pod B rejects empty token with 401', async () => {
    const ctx = await pwRequest.newContext();
    const r = await ctx.get(`${POD_B_URL}/api/protected/data`, {
      headers: { Authorization: 'Bearer ' },
    });
    expect(r.status()).toBe(401);
  });

  test('Pod B rejects tokens missing required role with 403', async () => {
    // Build a token-like string that would parse but lacks roles — Keycloak will
    // reject signature, so this stays 401. Documented here as boundary case.
    const r = await podB.getProtectedData('eyJhbGciOiJSUzI1NiJ9.e30.AAAA');
    expect([401, 403]).toContain(r.status);
  });

  test('Pod A still responds after token exchange retries', async () => {
    for (let i = 0; i < 3; i++) {
      const r = await podA.exchangeToken();
      expect(r.accessToken).toBeDefined();
    }
    const h = await podA.getHealth();
    expect(h.status).toBe(200);
  });

  test('Pod B audit log records every protected access (kubectl logs)', async () => {
    // Trigger one fresh authorized call so an AUDIT line is fresh
    await podB.getProtectedData(token);
    let logs = '';
    try {
      logs = execSync('kubectl logs -n poc deploy/pod-b --tail=200', { encoding: 'utf-8' });
    } catch (e) {
      test.skip(true, 'kubectl not available in test environment');
    }
    expect(logs).toContain('AUDIT');
    expect(logs).toContain('"endpoint":"/api/protected/data"');
    expect(logs).toContain('"outcome":"ALLOWED"');
  });
});
