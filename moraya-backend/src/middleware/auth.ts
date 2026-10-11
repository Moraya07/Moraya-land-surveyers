import type { Context, MiddlewareHandler } from 'hono';
import type { AppEnv, AuthContext } from '../env';
import { AppError } from '../lib/errors';
import { cookieNames, readCookie } from '../services/cookies';
import { verifyAccessToken } from '../services/jwt';
import { getProfile } from '../services/profile';

/**
 * Cookie -> verified JWT -> fresh profile from the database (every request, so role changes and
 * revocation apply immediately; no cache). Identity and role come ONLY from the database.
 * inactive: 'forbidden' (guards) or 'unauthenticated' (/me, so the SPA treats it as signed out).
 */
export async function authenticate(
  c: Context<AppEnv>,
  inactive: 'forbidden' | 'unauthenticated' = 'forbidden',
): Promise<AuthContext> {
  const token = readCookie(c.req.header('Cookie'), cookieNames(c.env).at);
  if (!token) throw new AppError(401, 'UNAUTHENTICATED');

  let authUserId: string;
  try {
    authUserId = await verifyAccessToken(c.env, token);
  } catch {
    throw new AppError(401, 'UNAUTHENTICATED'); // expired, bad signature, wrong iss/aud
  }

  const profile = await getProfile(c.env, authUserId);
  if (!profile) throw new AppError(401, 'UNAUTHENTICATED');
  if (profile.account_status !== 'active') {
    if (inactive === 'unauthenticated') throw new AppError(401, 'UNAUTHENTICATED');
    throw new AppError(403, profile.account_status === 'revoked' ? 'ACCOUNT_REVOKED' : 'ACCOUNT_INACTIVE');
  }
  return {
    authUserId,
    employee: profile,
    role: profile.role,
    permissions: profile.role === 'sub_admin' ? profile.permissions : [],
  };
}

export const requireAuth: MiddlewareHandler<AppEnv> = async (c, next) => {
  c.set('auth', await authenticate(c));
  await next();
};
