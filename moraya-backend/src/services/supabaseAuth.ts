import { supabaseUrl, type Env } from '../env';
import { AppError } from '../lib/errors';
import type { SessionTokens } from './cookies';

export interface SupabaseSession extends SessionTokens {
  authUserId: string;
}

interface AuthInit {
  method: 'POST';
  body?: string;
  headers?: Record<string, string>;
}

async function authFetch(env: Env, path: string, init: AuthInit): Promise<Response> {
  try {
    return await fetch(`${supabaseUrl(env)}/auth/v1${path}`, {
      method: init.method,
      body: init.body,
      headers: { apikey: env.SUPABASE_ANON_KEY, 'Content-Type': 'application/json', ...init.headers },
    });
  } catch {
    console.warn('supabase auth: network error');
    throw new AppError(500, 'INTERNAL_ERROR'); // unreachable upstream is a 500, never a 401
  }
}

async function parseSession(res: Response): Promise<SupabaseSession> {
  const body = (await res.json()) as {
    access_token?: unknown;
    refresh_token?: unknown;
    expires_in?: unknown;
    user?: { id?: unknown };
  };
  if (
    typeof body.access_token !== 'string' ||
    typeof body.refresh_token !== 'string' ||
    typeof body.expires_in !== 'number' ||
    typeof body.user?.id !== 'string'
  ) {
    throw new AppError(500, 'INTERNAL_ERROR');
  }
  return {
    accessToken: body.access_token,
    refreshToken: body.refresh_token,
    expiresIn: body.expires_in,
    authUserId: body.user.id,
  };
}

/** Returns null for rejected credentials / tokens; throws AppError for upstream problems. */
async function tokenGrant(env: Env, grant: 'password' | 'refresh_token', body: Record<string, string>) {
  const res = await authFetch(env, `/token?grant_type=${grant}`, { method: 'POST', body: JSON.stringify(body) });
  if (res.ok) return parseSession(res);
  if (res.status === 400 || res.status === 401 || res.status === 403 || res.status === 422) return null;
  if (res.status === 429) throw new AppError(429, 'RATE_LIMITED', 60);
  console.warn(`supabase auth token grant: status ${res.status}`);
  throw new AppError(500, 'INTERNAL_ERROR');
}

export const passwordGrant = (env: Env, email: string, password: string) =>
  tokenGrant(env, 'password', { email, password });

export const refreshGrant = (env: Env, refreshToken: string) =>
  tokenGrant(env, 'refresh_token', { refresh_token: refreshToken });

/** Best-effort revoke of one session. Never throws. */
export async function signOut(env: Env, accessToken: string): Promise<void> {
  try {
    await authFetch(env, '/logout?scope=local', { method: 'POST', headers: { Authorization: `Bearer ${accessToken}` } });
  } catch {
    /* best effort */
  }
}

/** Resolves for any HTTP outcome (so callers cannot leak whether the email exists); throws only on network failure. */
export async function recover(env: Env, email: string): Promise<void> {
  const redirect = encodeURIComponent(env.PASSWORD_RESET_REDIRECT_URL);
  const res = await authFetch(env, `/recover?redirect_to=${redirect}`, { method: 'POST', body: JSON.stringify({ email }) });
  if (!res.ok) console.warn(`supabase recover: status ${res.status}`); // swallowed on purpose
}
