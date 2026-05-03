import { APIRequestContext } from '@playwright/test';

export interface TokenExchangeResponse {
  accessToken: string;
  tokenType: string;
  expiresIn: number;
  issuedAt: string;
}

export class PodAApiClient {
  constructor(private request: APIRequestContext, private baseUrl: string) {}

  async getHealth(): Promise<{ status: number; body: any }> {
    const r = await this.request.get(`${this.baseUrl}/api/health`);
    return { status: r.status(), body: r.status() < 500 ? await r.json() : null };
  }

  async exchangeToken(): Promise<TokenExchangeResponse> {
    const r = await this.request.post(`${this.baseUrl}/api/exchange`);
    if (!r.ok()) throw new Error(`exchange failed: ${r.status()} ${await r.text()}`);
    return await r.json();
  }

  async getCurrentToken(): Promise<TokenExchangeResponse | null> {
    const r = await this.request.get(`${this.baseUrl}/api/tokens/current`);
    if (r.status() === 204) return null;
    if (!r.ok()) throw new Error(`tokens/current failed: ${r.status()}`);
    const body = await r.json();
    return {
      accessToken: body.token,
      tokenType: 'Bearer',
      expiresIn: body.expiresIn,
      issuedAt: body.issuedAt,
    };
  }

  async callPodB(): Promise<{ status: number; body: any }> {
    const r = await this.request.get(`${this.baseUrl}/api/call-pod-b`);
    return { status: r.status(), body: await r.json() };
  }

  async oidcTokenInfo(): Promise<{ status: number; body: any }> {
    const r = await this.request.get(`${this.baseUrl}/api/oidc/token-info`);
    return { status: r.status(), body: await r.json() };
  }
}

export class PodBApiClient {
  constructor(private request: APIRequestContext, private baseUrl: string) {}

  async getHealth(): Promise<{ status: number; body: any }> {
    const r = await this.request.get(`${this.baseUrl}/api/health`);
    return { status: r.status(), body: await r.json() };
  }

  async getPublicInfo(): Promise<{ status: number; body: any }> {
    const r = await this.request.get(`${this.baseUrl}/api/public/info`);
    return { status: r.status(), body: await r.json() };
  }

  async getProtectedData(token: string): Promise<{ status: number; body: any }> {
    const r = await this.request.get(`${this.baseUrl}/api/protected/data`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    const ct = r.headers()['content-type'] || '';
    return { status: r.status(), body: ct.includes('json') ? await r.json() : await r.text() };
  }

  async createData(token: string, payload: Record<string, string>): Promise<{ status: number; body: any }> {
    const r = await this.request.post(`${this.baseUrl}/api/protected/create`, {
      headers: { Authorization: `Bearer ${token}` },
      data: payload,
    });
    const ct = r.headers()['content-type'] || '';
    return { status: r.status(), body: ct.includes('json') ? await r.json() : await r.text() };
  }

  async callWithoutToken(): Promise<number> {
    const r = await this.request.get(`${this.baseUrl}/api/protected/data`);
    return r.status();
  }

  async callWithInvalidToken(): Promise<number> {
    const r = await this.request.get(`${this.baseUrl}/api/protected/data`, {
      headers: { Authorization: `Bearer not-a-real-jwt` },
    });
    return r.status();
  }
}

export const POD_A_URL = process.env.POD_A_URL ?? 'http://127.0.0.1:30810';
export const POD_B_URL = process.env.POD_B_URL ?? 'http://127.0.0.1:30820';
export const KEYCLOAK_URL = process.env.KEYCLOAK_URL ?? 'http://127.0.0.1:30888';
