import { SignJWT } from 'jose';
import { vi } from 'vitest';
import app from '../src/index';
import type { Env, Profile } from '../src/env';

export const JWT_SECRET = 'test-jwt-secret-test-jwt-secret-0123456789';
export const SERVICE_KEY = 'SERVICE-ROLE-KEY-do-not-leak';
export const ANON_KEY = 'ANON-KEY-do-not-leak';

export const baseEnv: Env = {
  ENVIRONMENT: 'development',
  SUPABASE_URL: 'https://proj.supabase.co',
  ALLOWED_ORIGIN: 'https://app.test',
  REFRESH_COOKIE_DAYS: '7',
  PASSWORD_RESET_REDIRECT_URL: 'https://app.test/reset-password',
  DEV_INSECURE_COOKIES: 'false',
  SUPABASE_ANON_KEY: ANON_KEY,
  SUPABASE_SERVICE_ROLE_KEY: SERVICE_KEY,
  SUPABASE_JWT_SECRET: JWT_SECRET,
};

interface Call {
  path: string;
  method: string;
  body: Record<string, unknown> | undefined;
}

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } });

/** In-memory stand-in for Supabase Auth + PostgREST RPCs used by the Worker. */
export class FakeSupabase {
  users = new Map<string, { id: string; password: string }>();
  profiles = new Map<string, Profile>();
  refreshTokens = new Map<string, string>();
  counters = new Map<string, number>();
  calls: Call[] = [];
  audits: Record<string, unknown>[] = [];
  signOuts = 0;
  recovered: string[] = [];
  private seq = 0;

  addUser(email: string, password: string, profile: Partial<Profile> | null = {}): string {
    const id = crypto.randomUUID();
    this.users.set(email, { id, password });
    if (profile !== null) {
      this.profiles.set(id, {
        id: `emp-${id}`,
        auth_user_id: id,
        employee_id: `EMP-${this.users.size}`,
        name: 'Test User',
        login_email: email,
        role: 'worker',
        account_status: 'active',
        permissions: [],
        ...profile,
      });
    }
    return id;
  }

  async issueToken(authUserId: string, expiresInSeconds = 3600): Promise<string> {
    return new SignJWT({ role: 'authenticated' })
      .setProtectedHeader({ alg: 'HS256' })
      .setSubject(authUserId)
      .setIssuer(`${baseEnv.SUPABASE_URL}/auth/v1`)
      .setAudience('authenticated')
      .setIssuedAt()
      .setExpirationTime(Math.floor(Date.now() / 1000) + expiresInSeconds)
      .sign(new TextEncoder().encode(JWT_SECRET));
  }

  private async session(authUserId: string) {
    const rt = `rt-${++this.seq}`;
    this.refreshTokens.set(rt, authUserId);
    return {
      access_token: await this.issueToken(authUserId),
      refresh_token: rt,
      expires_in: 3600,
      user: { id: authUserId },
    };
  }

  install(): void {
    vi.stubGlobal('fetch', this.handle);
  }

  handle = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url);
    const method = init?.method ?? 'GET';
    const body = init?.body ? (JSON.parse(String(init.body)) as Record<string, unknown>) : undefined;
    this.calls.push({ path: url.pathname, method, body });

    switch (url.pathname) {
      case '/auth/v1/token': {
        if (url.searchParams.get('grant_type') === 'password') {
          const u = this.users.get(String(body?.email));
          return u && u.password === body?.password ? json(await this.session(u.id)) : json({ error_code: 'invalid_credentials' }, 400);
        }
        const owner = this.refreshTokens.get(String(body?.refresh_token));
        if (!owner) return json({ error_code: 'refresh_token_not_found' }, 400);
        this.refreshTokens.delete(String(body?.refresh_token)); // rotation: old token is dead
        return json(await this.session(owner));
      }
      case '/auth/v1/logout':
        this.signOuts++;
        return new Response(null, { status: 204 });
      case '/auth/v1/recover':
        this.recovered.push(String(body?.email));
        return json({});
      case '/rest/v1/audit_logs':
        this.audits.push(body ?? {});
        return new Response(null, { status: 201 });
      case '/rest/v1/rpc/get_auth_profile': {
        const p = this.profiles.get(String(body?.p_auth_user_id));
        return json(p ? [p] : []);
      }
      case '/rest/v1/rpc/login_profile_and_audit': {
        const p = this.profiles.get(String(body?.p_auth_user_id));
        const ok = p?.account_status === 'active';
        this.audits.push({
          action: !p ? 'LOGIN_FAILED' : ok ? 'LOGIN_SUCCESS' : 'LOGIN_FAILED',
          reason: !p ? 'NO_EMPLOYEE_RECORD' : ok ? null : `ACCOUNT_${p.account_status.toUpperCase()}`,
          email_masked: body?.p_email_masked,
        });
        if (ok) this.counters.delete(String(body?.p_reset_key));
        return json(p ?? null);
      }
      case '/rest/v1/rpc/auth_throttle_hit': {
        const keys = body?.p_keys as string[];
        const limits = body?.p_limits as number[];
        let blocked = false;
        keys.forEach((k, i) => {
          const n = (this.counters.get(k) ?? 0) + 1;
          this.counters.set(k, n);
          const limit = limits[i] ?? 0;
          if (n > limit) blocked = true;
          if (n === limit + 1) this.audits.push({ action: body?.p_audit_action });
        });
        return json([{ blocked, retry_after_seconds: blocked ? 600 : 0 }]);
      }
      default:
        return json({ error: 'unexpected call' }, 500);
    }
  };
}

export interface ApiOptions {
  method?: string;
  body?: unknown;
  rawBody?: string;
  headers?: Record<string, string>;
  cookies?: Record<string, string>;
  env?: Partial<Env>;
  noCsrf?: boolean;
}

export async function api(path: string, o: ApiOptions = {}): Promise<Response> {
  const headers: Record<string, string> = { 'CF-Connecting-IP': '203.0.113.7', ...o.headers };
  const hasBody = o.body !== undefined || o.rawBody !== undefined;
  if (hasBody && !('Content-Type' in headers)) headers['Content-Type'] = 'application/json';
  if (!o.noCsrf) {
    headers['Origin'] ??= baseEnv.ALLOWED_ORIGIN;
    headers['X-Requested-With'] ??= 'moraya-web';
  }
  if (o.cookies) headers['Cookie'] = Object.entries(o.cookies).map(([k, v]) => `${k}=${v}`).join('; ');
  const method = o.method ?? (hasBody ? 'POST' : 'GET');
  return app.request(
    path,
    { method, headers, body: o.rawBody ?? (o.body !== undefined ? JSON.stringify(o.body) : undefined) },
    { ...baseEnv, ...o.env },
  );
}

export const flush = () => new Promise((r) => setTimeout(r, 0));
