import { test, expect, request as pwRequest } from '@playwright/test';
import { PodAApiClient, PodBApiClient, POD_A_URL, POD_B_URL } from '../utils/api-client';
import { decodeJwt } from '../utils/jwt-helper';

test.describe('05 Service-to-Service Integration', () => {
  let podA: PodAApiClient;
  let podB: PodBApiClient;

  test.beforeAll(async () => {
    const ctx = await pwRequest.newContext();
    podA = new PodAApiClient(ctx, POD_A_URL);
    podB = new PodBApiClient(ctx, POD_B_URL);
  });

  test('Pod A → Pod B (via /api/call-pod-b) succeeds with 200', async () => {
    const r = await podA.callPodB();
    expect(r.status).toBe(200);
    expect(r.body).toHaveProperty('message', 'Successfully called Pod B');
    expect(r.body.status).toBe(200);
  });

  test('Pod A → Pod B response contains the resource payload', async () => {
    const r = await podA.callPodB();
    const inner = typeof r.body.response === 'string' ? JSON.parse(r.body.response) : r.body.response;
    expect(inner).toHaveProperty('source', 'pod-b');
    expect(inner).toHaveProperty('callerIdentity');
  });

  test('Caller identity (sub claim) is preserved across the boundary', async () => {
    const t = await podA.exchangeToken();
    const claims = decodeJwt<any>(t.accessToken);
    const r = await podB.getProtectedData(t.accessToken);
    // pod-b's controller exposes auth.getName() which Spring derives from `sub`
    expect(r.body.callerIdentity).toBe(claims.sub);
    // And the workload identity (client) matches pod-a
    expect(claims.azp).toBe('pod-a');
  });

  test('Roles are preserved across the boundary', async () => {
    const t = await podA.exchangeToken();
    const r = await podB.getProtectedData(t.accessToken);
    const tokenRoles: string[] = (r.body.roles ?? []) as string[];
    expect(tokenRoles.some((r) => r.endsWith('data-reader'))).toBeTruthy();
  });

  test('GET protected requires data-reader role (verified server-side)', async () => {
    const t = await podA.exchangeToken();
    const r = await podB.getProtectedData(t.accessToken);
    expect(r.status).toBe(200);
  });

  test('POST protected requires data-writer role (verified server-side)', async () => {
    const t = await podA.exchangeToken();
    const r = await podB.createData(t.accessToken, { source: 'e2e-05' });
    expect(r.status).toBe(201);
  });
});
