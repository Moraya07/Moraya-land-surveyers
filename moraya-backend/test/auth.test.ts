import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ANON_KEY, FakeSupabase, SERVICE_KEY, api, flush } from './helpers';

let fake: FakeSupabase;
let logs: string[];

beforeEach(() => {
  fake = new FakeSupabase();
  fake.install();
  logs = [];
  for (const m of ['log', 'warn', 'error', 'info'] as const) {
    vi.spyOn(console, m).mockImplementation((...a: unknown[]) => void logs.push(a.map(String).join(' ')));
  }
});
afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

const PASSWORD = 'Sup3r-Secret-Pass!';
const login = (email = 'a@x.com', password = PASSWORD) => api('/api/auth/login', { body: { email, password } });
const cookiesOf = (res: Response) => res.headers.getSetCookie();

describe('login', () => {
  it.each([
    ['main_admin', '/admin'],
    ['sub_admin', '/admin'],
    ['worker', '/home'],
  ] as const)('%s logs in and is sent to %s', async (role, redirectTo) => {
    fake.addUser('a@x.com', PASSWORD, { role, permissions: role === 'sub_admin' ? ['verification'] : [] });
    const res = await login();
    expect(res.status).toBe(200);
    const body = (await res.json()) as { user: { role: string; permissions: string[]; email: string }; redirectTo: string };
    expect(body.redirectTo).toBe(redirectTo);
    expect(body.user.role).toBe(role);
    expect(body.user.permissions).toEqual(role === 'sub_admin' ? ['verification'] : []);
    expect(JSON.stringify(body)).not.toMatch(/access_token|refresh_token|rt-1|eyJ/);
  });

  it('normalises the email (trim + lowercase)', async () => {
    fake.addUser('a@x.com', PASSWORD);
    expect((await login('  A@X.com ')).status).toBe(200);
  });

  it('sets cookies with exactly the specified attributes', async () => {
    fake.addUser('a@x.com', PASSWORD);
    const c = cookiesOf(await login());
    expect(c).toHaveLength(2);
    const at = c.find((x) => x.startsWith('__Host-moraya_at='))!;
    const rt = c.find((x) => x.startsWith('__Host-moraya_rt='))!;
    for (const x of [at, rt]) {
      expect(x).toContain('HttpOnly');
      expect(x).toContain('Secure');
      expect(x).toContain('SameSite=Strict');
      expect(x).toContain('Path=/');
      expect(x).not.toMatch(/Domain=/i);
    }
    expect(at).toContain('Max-Age=3600');
    expect(rt).toContain(`Max-Age=${7 * 86400}`);
  });

  it('dev mode drops Secure and the __Host- prefix', async () => {
    fake.addUser('a@x.com', PASSWORD);
    const res = await api('/api/auth/login', { body: { email: 'a@x.com', password: PASSWORD }, env: { DEV_INSECURE_COOKIES: 'true' } });
    const c = cookiesOf(res);
    expect(c[0]).toMatch(/^moraya_at=/);
    expect(c.join(';')).not.toContain('Secure');
  });

  it('uses at most 3 subrequests on success', async () => {
    fake.addUser('a@x.com', PASSWORD);
    await login();
    await flush();
    expect(fake.calls).toHaveLength(3);
  });

  it('wrong password and unknown email are indistinguishable', async () => {
    fake.addUser('a@x.com', PASSWORD);
    const wrong = await login('a@x.com', 'nope');
    const unknown = await login('ghost@x.com', 'nope');
    expect(wrong.status).toBe(401);
    expect(unknown.status).toBe(401);
    const a = (await wrong.json()) as { error: { code: string; message: string } };
    const b = (await unknown.json()) as { error: { code: string; message: string } };
    expect(a).toEqual(b);
    expect(a.error.code).toBe('INVALID_CREDENTIALS');
    expect(cookiesOf(wrong)).toHaveLength(0);
  });

  it.each([
    ['inactive', 'ACCOUNT_INACTIVE'],
    ['revoked', 'ACCOUNT_REVOKED'],
  ] as const)('%s account: 403, no cookies, session revoked', async (account_status, code) => {
    fake.addUser('a@x.com', PASSWORD, { account_status });
    const res = await login();
    expect(res.status).toBe(403);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe(code);
    expect(cookiesOf(res)).toHaveLength(0);
    await flush();
    expect(fake.signOuts).toBe(1);
  });

  it('missing employee row answers like a wrong password and is audited', async () => {
    fake.addUser('a@x.com', PASSWORD, null);
    const res = await login();
    expect(res.status).toBe(401);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('INVALID_CREDENTIALS');
    expect(fake.audits).toContainEqual(expect.objectContaining({ action: 'LOGIN_FAILED', reason: 'NO_EMPLOYEE_RECORD' }));
    await flush();
    expect(fake.signOuts).toBe(1);
  });

  it('throttles after 5 attempts and reports retryAfterSeconds', async () => {
    fake.addUser('a@x.com', PASSWORD);
    for (let i = 0; i < 5; i++) expect((await login('a@x.com', 'bad')).status).toBe(401);
    const res = await login('a@x.com', 'bad');
    expect(res.status).toBe(429);
    const body = (await res.json()) as { error: { code: string; retryAfterSeconds: number } };
    expect(body.error.code).toBe('RATE_LIMITED');
    expect(body.error.retryAfterSeconds).toBeGreaterThan(0);
    expect(fake.audits.filter((a) => a.action === 'LOGIN_BLOCKED')).toHaveLength(1); // once per window
  });

  it('audits failures with a masked email only', async () => {
    await login('alice@example.com', 'bad');
    await flush();
    const row = fake.audits.find((a) => a.action === 'LOGIN_FAILED')!;
    expect(JSON.stringify(row)).toContain('al***@example.com');
    expect(JSON.stringify(row)).not.toContain('alice@example.com');
  });
});

describe('request hardening', () => {
  it('rejects a missing X-Requested-With header', async () => {
    const res = await api('/api/auth/login', { body: { email: 'a@x.com', password: 'x' }, headers: { 'X-Requested-With': '' } });
    expect(res.status).toBe(403);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('FORBIDDEN');
  });
  it('rejects an Origin mismatch', async () => {
    const res = await api('/api/auth/login', { body: { email: 'a@x.com', password: 'x' }, headers: { Origin: 'https://evil.test' } });
    expect(res.status).toBe(403);
  });
  it('accepts a matching Referer when Origin is absent', async () => {
    fake.addUser('a@x.com', PASSWORD);
    const res = await api('/api/auth/login', {
      body: { email: 'a@x.com', password: PASSWORD },
      noCsrf: true,
      headers: { 'X-Requested-With': 'moraya-web', Referer: 'https://app.test/login' },
    });
    expect(res.status).toBe(200);
  });
  it.each([
    ['invalid JSON', { rawBody: '{nope' }],
    ['unknown field', { body: { email: 'a@x.com', password: 'x', role: 'main_admin' } }],
    ['bad email', { body: { email: 'not-an-email', password: 'x' } }],
    ['empty password', { body: { email: 'a@x.com', password: '' } }],
    ['129-char password', { body: { email: 'a@x.com', password: 'p'.repeat(129) } }],
    ['oversized body', { rawBody: JSON.stringify({ email: 'a@x.com', password: 'p'.repeat(5000) }) }],
    ['wrong content type', { rawBody: '{}', headers: { 'Content-Type': 'text/plain' } }],
  ] as const)('400 VALIDATION_ERROR for %s', async (_name, opts) => {
    const res = await api('/api/auth/login', { method: 'POST', ...opts });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('VALIDATION_ERROR');
  });
  it('sets security headers and a request id', async () => {
    const res = await api('/api/auth/me');
    expect(res.headers.get('Cache-Control')).toBe('no-store');
    expect(res.headers.get('X-Content-Type-Options')).toBe('nosniff');
    expect(res.headers.get('X-Frame-Options')).toBe('DENY');
    expect(res.headers.get('Referrer-Policy')).toBe('same-origin');
    expect(res.headers.get('X-Request-Id')).toBeTruthy();
  });
  it('sends HSTS only in production', async () => {
    const prod = await api('/api/auth/me', { env: { ENVIRONMENT: 'production', ALLOWED_ORIGIN: 'https://app.test' } });
    expect(prod.headers.get('Strict-Transport-Security')).toContain('max-age=');
    expect((await api('/api/auth/me')).headers.get('Strict-Transport-Security')).toBeNull();
  });
  it('refuses insecure cookies in production and returns a generic 500', async () => {
    const res = await api('/api/auth/me', { env: { ENVIRONMENT: 'production', DEV_INSECURE_COOKIES: 'true' } });
    expect(res.status).toBe(500);
    expect(await res.text()).not.toContain('DEV_INSECURE');
    expect(logs.join('\n')).toContain('DEV_INSECURE_COOKIES'); // detail only in server logs
  });
  it('fails fast on missing config without leaking values', async () => {
    const res = await api('/api/auth/me', { env: { SUPABASE_URL: '' } });
    expect(res.status).toBe(500);
    expect(await res.text()).not.toContain('SUPABASE_URL');
  });
});

describe('session', () => {
  it('/me: 401 without a cookie', async () => {
    const res = await api('/api/auth/me');
    expect(res.status).toBe(401);
  });
  it('/me: returns the user for a valid cookie', async () => {
    const id = fake.addUser('a@x.com', PASSWORD, { role: 'sub_admin', permissions: ['export'] });
    const res = await api('/api/auth/me', { cookies: { '__Host-moraya_at': await fake.issueToken(id) } });
    expect(res.status).toBe(200);
    expect(((await res.json()) as { user: { id: string; permissions: string[] } }).user).toMatchObject({ id, permissions: ['export'] });
  });
  it('/me: 401 for an expired token', async () => {
    const id = fake.addUser('a@x.com', PASSWORD);
    const res = await api('/api/auth/me', { cookies: { '__Host-moraya_at': await fake.issueToken(id, -60) } });
    expect(res.status).toBe(401);
  });
  it('/me: 401 for a user who became inactive', async () => {
    const id = fake.addUser('a@x.com', PASSWORD, { account_status: 'inactive' });
    const res = await api('/api/auth/me', { cookies: { '__Host-moraya_at': await fake.issueToken(id) } });
    expect(res.status).toBe(401);
  });

  it('refresh: rotates both cookies; the old refresh token then fails cleanly', async () => {
    fake.addUser('a@x.com', PASSWORD);
    const rt = cookiesOf(await login()).find((c) => c.startsWith('__Host-moraya_rt='))!.split(';')[0]!.split('=')[1]!;
    const ok = await api('/api/auth/refresh', { method: 'POST', cookies: { '__Host-moraya_rt': rt } });
    expect(ok.status).toBe(204);
    expect(cookiesOf(ok)).toHaveLength(2);
    const replay = await api('/api/auth/refresh', { method: 'POST', cookies: { '__Host-moraya_rt': rt } });
    expect(replay.status).toBe(401);
    expect(cookiesOf(replay).every((c) => c.includes('Max-Age=0'))).toBe(true);
  });
  it('refresh: a revoked user cannot refresh', async () => {
    const id = fake.addUser('a@x.com', PASSWORD);
    const rt = cookiesOf(await login()).find((c) => c.startsWith('__Host-moraya_rt='))!.split(';')[0]!.split('=')[1]!;
    fake.profiles.get(id)!.account_status = 'revoked';
    const res = await api('/api/auth/refresh', { method: 'POST', cookies: { '__Host-moraya_rt': rt } });
    expect(res.status).toBe(401);
    expect(cookiesOf(res).some((c) => c.includes('Max-Age=0'))).toBe(true);
  });
  it('refresh: 401 without a cookie', async () => {
    expect((await api('/api/auth/refresh', { method: 'POST' })).status).toBe(401);
  });

  it('logout: always 204 and clears both cookies, even with no session', async () => {
    const res = await api('/api/auth/logout', { method: 'POST' });
    expect(res.status).toBe(204);
    const c = cookiesOf(res);
    expect(c).toHaveLength(2);
    expect(c.every((x) => x.includes('Max-Age=0') && x.includes('HttpOnly'))).toBe(true);
  });
  it('logout: revokes the session and audits LOGOUT', async () => {
    const id = fake.addUser('a@x.com', PASSWORD);
    const res = await api('/api/auth/logout', { method: 'POST', cookies: { '__Host-moraya_at': await fake.issueToken(id) } });
    expect(res.status).toBe(204);
    await flush();
    expect(fake.signOuts).toBe(1);
    expect(fake.audits).toContainEqual(expect.objectContaining({ action: 'LOGOUT' }));
  });
});

describe('forgot-password', () => {
  const forgot = (email: string) => api('/api/auth/forgot-password', { body: { email } });

  it('answers 202 { ok: true } for known and unknown emails alike', async () => {
    fake.addUser('a@x.com', PASSWORD);
    const known = await forgot('a@x.com');
    const unknown = await forgot('ghost@x.com');
    expect(known.status).toBe(202);
    expect(unknown.status).toBe(202);
    expect(await known.json()).toEqual({ ok: true });
    expect(await unknown.json()).toEqual({ ok: true });
  });
  it('400 for an invalid email', async () => {
    expect((await forgot('nope')).status).toBe(400);
  });
  it('throttles per email', async () => {
    for (let i = 0; i < 3; i++) expect((await forgot('a@x.com')).status).toBe(202);
    const res = await forgot('a@x.com');
    expect(res.status).toBe(429);
  });
});

describe('secrets', () => {
  it('no password, key or token appears in responses, logs or audit rows', async () => {
    fake.addUser('a@x.com', PASSWORD);
    const texts: string[] = [];
    for (const res of [await login(), await login('a@x.com', PASSWORD + 'x'), await api('/api/auth/me'), await api('/api/nope')]) {
      texts.push(await res.text(), [...res.headers.entries()].filter(([k]) => k !== 'set-cookie').join('|'));
    }
    await flush();
    const everything = [...texts, ...logs, JSON.stringify(fake.audits)].join('\n');
    for (const secret of [PASSWORD, SERVICE_KEY, ANON_KEY]) expect(everything).not.toContain(secret);
    expect(everything).not.toMatch(/eyJ[A-Za-z0-9_-]{10,}/);
  });
});
