import { test, expect, request as pwRequest } from '@playwright/test';
import { PodAApiClient, POD_A_URL } from '../utils/api-client';
import { decodeJwt } from '../utils/jwt-helper';

test.describe('03 Token Refresh & Cache', () => {
  let podA: PodAApiClient;

  test.beforeAll(async () => {
    const ctx = await pwRequest.newContext();
    podA = new PodAApiClient(ctx, POD_A_URL);
  });

  test('Token has 5-minute expiry', async () => {
    const r = await podA.exchangeToken();
    expect(r.expiresIn).toBe(300);
  });

  test('Cached token endpoint returns the most recently issued token', async () => {
    const fresh = await podA.exchangeToken();
    const cached = await podA.getCurrentToken();
    expect(cached).not.toBeNull();
    // Cached token should match (the controller seeds the cache after exchange)
    expect(cached!.accessToken).toBe(fresh.accessToken);
  });

  test('Token metadata (issuedAt) is recent', async () => {
    const t = await podA.exchangeToken();
    const issuedAt = new Date(t.issuedAt).getTime();
    expect(Math.abs(Date.now() - issuedAt)).toBeLessThan(10_000);
  });

  test('Five concurrent token exchanges all succeed', async () => {
    const results = await Promise.all(Array.from({ length: 5 }, () => podA.exchangeToken()));
    for (const r of results) {
      expect(r.accessToken.split('.')).toHaveLength(3);
    }
  });

  test('Token exp claim matches issuedAt + expiresIn (±30s)', async () => {
    const r = await podA.exchangeToken();
    const claims = decodeJwt<any>(r.accessToken);
    const expSeconds = claims.exp;
    const issuedAtSeconds = Math.floor(new Date(r.issuedAt).getTime() / 1000);
    expect(Math.abs((expSeconds - issuedAtSeconds) - r.expiresIn)).toBeLessThan(30);
  });

  test('Cached token is non-expired', async () => {
    await podA.exchangeToken();
    const cached = await podA.getCurrentToken();
    expect(cached).not.toBeNull();
    const claims = decodeJwt<any>(cached!.accessToken);
    expect(claims.exp * 1000).toBeGreaterThan(Date.now());
  });
});
