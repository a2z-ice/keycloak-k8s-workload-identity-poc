/** Decode a JWT payload (no verification — testing only). */
export function decodeJwt<T = Record<string, any>>(token: string): T {
  const parts = token.split('.');
  if (parts.length !== 3) throw new Error(`Not a JWT: got ${parts.length} parts`);
  const payload = parts[1];
  const padded = payload + '='.repeat((4 - (payload.length % 4)) % 4);
  const decoded = Buffer.from(padded.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf-8');
  return JSON.parse(decoded) as T;
}

/** Keycloak `aud` may be a string or string[]. Normalise to a string[]. */
export function audiences(claim: any): string[] {
  if (claim === undefined || claim === null) return [];
  if (Array.isArray(claim)) return claim.map(String);
  return [String(claim)];
}

/** Pull all role names out of a Keycloak JWT (realm + resource + flat). */
export function rolesFromKeycloakJwt(payload: any): string[] {
  const out = new Set<string>();
  const realm = payload?.realm_access?.roles;
  if (Array.isArray(realm)) realm.forEach((r: string) => out.add(r));
  const resource = payload?.resource_access;
  if (resource && typeof resource === 'object') {
    for (const v of Object.values(resource)) {
      const roles = (v as any)?.roles;
      if (Array.isArray(roles)) roles.forEach((r: string) => out.add(r));
    }
  }
  if (Array.isArray(payload?.roles)) payload.roles.forEach((r: string) => out.add(r));
  return [...out];
}
