import { test, expect, request as pwRequest } from '@playwright/test';
import { PodAApiClient, PodBApiClient, POD_A_URL, POD_B_URL } from '../utils/api-client';

test.describe('07 Performance & Load', () => {
  let podA: PodAApiClient;
  let podB: PodBApiClient;

  test.beforeAll(async () => {
    const ctx = await pwRequest.newContext();
    podA = new PodAApiClient(ctx, POD_A_URL);
    podB = new PodBApiClient(ctx, POD_B_URL);
  });

  test('Token exchange completes under 3 seconds', async () => {
    const start = Date.now();
    await podA.exchangeToken();
    expect(Date.now() - start).toBeLessThan(3_000);
  });

  test('Pod B health under 1 second', async () => {
    const start = Date.now();
    await podB.getHealth();
    expect(Date.now() - start).toBeLessThan(1_000);
  });

  test('Pod B protected GET under 2 seconds', async () => {
    const t = await podA.exchangeToken();
    const start = Date.now();
    await podB.getProtectedData(t.accessToken);
    expect(Date.now() - start).toBeLessThan(2_000);
  });

  test('Cached token retrieval under 250 ms', async () => {
    await podA.exchangeToken();
    const start = Date.now();
    await podA.getCurrentToken();
    expect(Date.now() - start).toBeLessThan(250);
  });

  test('10 concurrent token exchanges all succeed', async () => {
    const results = await Promise.all(Array.from({ length: 10 }, () => podA.exchangeToken()));
    for (const r of results) expect(r.accessToken.split('.')).toHaveLength(3);
  });

  test('10 concurrent Pod B protected calls all succeed', async () => {
    const t = await podA.exchangeToken();
    const results = await Promise.all(
      Array.from({ length: 10 }, () => podB.getProtectedData(t.accessToken)),
    );
    for (const r of results) expect(r.status).toBe(200);
  });

  test('Sustained 30-call burst remains healthy', async () => {
    const t = await podA.exchangeToken();
    let ok = 0;
    for (let i = 0; i < 30; i++) {
      const r = await podB.getProtectedData(t.accessToken);
      if (r.status === 200) ok += 1;
    }
    expect(ok).toBe(30);
  });
});
