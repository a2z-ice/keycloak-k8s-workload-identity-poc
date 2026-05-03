import { test, expect, request as pwRequest } from '@playwright/test';
import { PodAApiClient, PodBApiClient, POD_A_URL, POD_B_URL } from '../utils/api-client';
import { decodeJwt, rolesFromKeycloakJwt } from '../utils/jwt-helper';

test.describe('02 Authorization & RBAC', () => {
  let podA: PodAApiClient;
  let podB: PodBApiClient;
  let token: string;

  test.beforeAll(async () => {
    const ctx = await pwRequest.newContext();
    podA = new PodAApiClient(ctx, POD_A_URL);
    podB = new PodBApiClient(ctx, POD_B_URL);
    token = (await podA.exchangeToken()).accessToken;
  });

  test('Public endpoint accessible without authentication', async () => {
    const r = await podB.getPublicInfo();
    expect(r.status).toBe(200);
    expect(r.body).toHaveProperty('app', 'pod-b');
  });

  test('Protected endpoint without token returns 401', async () => {
    expect(await podB.callWithoutToken()).toBe(401);
  });

  test('Protected endpoint with malformed token returns 401', async () => {
    expect(await podB.callWithInvalidToken()).toBe(401);
  });

  test('Protected GET with valid token returns 200', async () => {
    const r = await podB.getProtectedData(token);
    expect(r.status).toBe(200);
    expect(r.body).toHaveProperty('callerIdentity');
  });

  test('Protected POST with valid token returns 201', async () => {
    const r = await podB.createData(token, { name: 'e2e-payload' });
    expect(r.status).toBe(201);
    expect(r.body).toHaveProperty('status', 'created');
    expect(r.body.data.payload).toMatchObject({ name: 'e2e-payload' });
  });

  test('Token includes data-reader and data-writer roles', async () => {
    const claims = decodeJwt<any>(token);
    const roles = rolesFromKeycloakJwt(claims);
    expect(roles).toContain('data-reader');
    expect(roles).toContain('data-writer');
  });

  test('Token sub is populated', async () => {
    const claims = decodeJwt<any>(token);
    expect(claims.sub).toBeDefined();
    expect(typeof claims.sub).toBe('string');
    expect(claims.sub.length).toBeGreaterThan(0);
  });
});
