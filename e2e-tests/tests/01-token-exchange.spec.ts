import { test, expect, request as pwRequest } from '@playwright/test';
import { PodAApiClient, PodBApiClient, POD_A_URL, POD_B_URL } from '../utils/api-client';
import { decodeJwt, audiences, rolesFromKeycloakJwt } from '../utils/jwt-helper';

test.describe('01 Token Exchange Flow', () => {
  let podA: PodAApiClient;
  let podB: PodBApiClient;

  test.beforeAll(async () => {
    const ctx = await pwRequest.newContext();
    podA = new PodAApiClient(ctx, POD_A_URL);
    podB = new PodBApiClient(ctx, POD_B_URL);
  });

  test('Pod A is healthy', async () => {
    const r = await podA.getHealth();
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ status: 'UP', pod: 'pod-a' });
  });

  test('Pod B is healthy', async () => {
    const r = await podB.getHealth();
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ status: 'UP', pod: 'pod-b' });
  });

  test('OIDC SA token is mounted in Pod A', async () => {
    const r = await podA.oidcTokenInfo();
    expect(r.status).toBe(200);
    expect(r.body.parts).toBe(3);
    expect(r.body.length).toBeGreaterThan(100);
    expect(r.body.namespace).toBe('poc');
  });

  test('Pod A exchanges OIDC token for Keycloak access token', async () => {
    const r = await podA.exchangeToken();
    expect(r.accessToken.split('.')).toHaveLength(3);
    expect(r.expiresIn).toBeGreaterThan(0);
    expect(r.expiresIn).toBeLessThanOrEqual(300);
    const claims = decodeJwt<any>(r.accessToken);
    expect(audiences(claims.aud)).toContain('pod-b');
  });

  test('Token exchange yields a JWT carrying data-reader and data-writer roles', async () => {
    const r = await podA.exchangeToken();
    const claims = decodeJwt<any>(r.accessToken);
    const roles = rolesFromKeycloakJwt(claims);
    expect(roles).toEqual(expect.arrayContaining(['data-reader', 'data-writer']));
  });

  test('Pod A can call Pod B using the access token (S2S)', async () => {
    const t = await podA.exchangeToken();
    const r = await podB.getProtectedData(t.accessToken);
    expect(r.status).toBe(200);
    expect(r.body.callerIdentity).toBeDefined();
  });
});
