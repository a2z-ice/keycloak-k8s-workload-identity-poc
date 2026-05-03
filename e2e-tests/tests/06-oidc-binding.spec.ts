import { test, expect, request as pwRequest } from '@playwright/test';
import { PodAApiClient, POD_A_URL } from '../utils/api-client';
import { decodeJwt, audiences } from '../utils/jwt-helper';

test.describe('06 OIDC Token Binding', () => {
  let podA: PodAApiClient;

  test.beforeAll(async () => {
    const ctx = await pwRequest.newContext();
    podA = new PodAApiClient(ctx, POD_A_URL);
  });

  test('OIDC token mount is reachable inside Pod A', async () => {
    const r = await podA.oidcTokenInfo();
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ namespace: 'poc' });
  });

  test('OIDC token has 3 JWT parts (header.payload.signature)', async () => {
    const r = await podA.oidcTokenInfo();
    expect(r.body.parts).toBe(3);
  });

  test('OIDC token has reasonable length (>200 bytes)', async () => {
    const r = await podA.oidcTokenInfo();
    expect(r.body.length).toBeGreaterThan(200);
  });

  test('Exchanged access token has aud=pod-b', async () => {
    const t = await podA.exchangeToken();
    const claims = decodeJwt<any>(t.accessToken);
    expect(audiences(claims.aud)).toContain('pod-b');
  });

  test('Exchanged access token has issuer = poc-realm', async () => {
    const t = await podA.exchangeToken();
    const claims = decodeJwt<any>(t.accessToken);
    expect(typeof claims.iss).toBe('string');
    expect(claims.iss).toContain('poc-realm');
  });

  test('Exchanged token identifies pod-a as the workload (azp/client_id)', async () => {
    const t = await podA.exchangeToken();
    const claims = decodeJwt<any>(t.accessToken);
    // With client_credentials, the sub is Keycloak's service-account UUID;
    // the actual workload identity is in azp / client_id.
    expect(claims.azp).toBe('pod-a');
    expect(claims.client_id).toBe('pod-a');
    expect(typeof claims.sub).toBe('string');
    expect(claims.sub.length).toBeGreaterThan(0);
  });

  test('Pod A reports its hostname (Kubernetes downward API)', async () => {
    const r = await podA.oidcTokenInfo();
    expect(r.body.pod).toMatch(/^pod-a/);
    expect(r.body.hostname).toMatch(/^pod-a/);
  });
});
