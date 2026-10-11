import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from 'jose';
import { supabaseUrl, type Env } from '../env';

// Verification strategy (see README):
//  - default: asymmetric signing keys via the project's JWKS. The key set is fetched once per isolate
//    and cached in memory by jose, so steady-state verification costs no subrequest.
//  - if SUPABASE_JWT_SECRET is set (legacy HS256 projects): verify locally with the shared secret.
let cachedJwks: { url: string; getKey: JWTVerifyGetKey } | null = null;

function getJwks(url: string): JWTVerifyGetKey {
  if (!cachedJwks || cachedJwks.url !== url) cachedJwks = { url, getKey: createRemoteJWKSet(new URL(url)) };
  return cachedJwks.getKey;
}

/** Throws on any invalid, expired or mismatched token. Returns the auth user id (sub). */
export async function verifyAccessToken(env: Env, token: string): Promise<string> {
  const base = supabaseUrl(env);
  const options = { issuer: `${base}/auth/v1`, audience: 'authenticated', clockTolerance: 5 } as const;

  const { payload } = env.SUPABASE_JWT_SECRET
    ? await jwtVerify(token, new TextEncoder().encode(env.SUPABASE_JWT_SECRET), { ...options, algorithms: ['HS256'] })
    : await jwtVerify(token, getJwks(`${base}/auth/v1/.well-known/jwks.json`), {
        ...options,
        algorithms: ['ES256', 'RS256', 'EdDSA'],
      });

  if (typeof payload.sub !== 'string' || payload.sub.length === 0) throw new Error('missing sub');
  return payload.sub;
}
