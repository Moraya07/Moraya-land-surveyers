# Moraya API: authentication backend (login phase)

Cloudflare Worker (Hono + Zod + jose) on Supabase Auth + PostgreSQL.
Endpoints: `POST /api/auth/login`, `GET /api/auth/me`, `POST /api/auth/refresh`, `POST /api/auth/logout`, `POST /api/auth/forgot-password`,
plus sample guarded routes `GET /api/worker/ping`, `GET /api/admin/ping`, `GET /api/admin/report-ping`.
No sign-up endpoint exists. Matches the frontend contract (`Moraya-frontend`).

## Layout
```
src/            index.ts, env.ts, routes/{auth,ping}.ts, middleware/{csrf,auth,rbac,rateLimit,requestId,security}.ts,
                services/{supabaseAuth,supabaseRest,profile,audit,cookies,jwt}.ts, lib/{errors,validation,mask,request}.ts
supabase/migrations/001..007_*.sql      run in order (idempotent where practical)
supabase/tests/main_admin_and_audit.sql manual SQL test (rolls back)
seed/001_main_admin.sql                 first Main Admin
test/                                   Vitest (Supabase mocked with fetch stubs)
```

## Prerequisites
Node 20+, a Supabase project, a Cloudflare account, `npm install`.

## Supabase setup
1. **Authentication > Sign In / Providers: turn OFF "Allow new users to sign up"** (otherwise anyone with the public anon key can call Supabase's own signup endpoint). Keep email provider enabled.
2. **Authentication > Sessions**: set *JWT expiry* (e.g. 3600 s; shorter = faster revocation, more refresh calls). Keep refresh-token rotation on. The refresh cookie lives `REFRESH_COOKIE_DAYS` (default 7).
3. **Authentication > URL Configuration**: add your `PASSWORD_RESET_REDIRECT_URL` to the redirect allow-list.
4. Run migrations `001` to `007` in order (SQL editor, or `supabase db push`). `citext` and `pgcrypto` are enabled by 001.
5. Create the first admin: Dashboard > Authentication > Users > add user (email + strong password chosen by the owner). Copy its UUID into `seed/001_main_admin.sql` (email must match, lowercase) and run it.
6. Optional: run `supabase/tests/main_admin_and_audit.sql` in the SQL editor. Expect only `PASS ...` notices.

## Local development
```bash
cp .dev.vars.example .dev.vars        # fill SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY
# edit SUPABASE_URL in wrangler.toml
npm run dev                           # http://127.0.0.1:8787 (DEV_INSECURE_COOKIES=true over http)
npm test                              # no Supabase needed
```
Frontend: `npm run dev` in `Moraya-frontend` proxies `/api` to port 8787. `ALLOWED_ORIGIN` (default `http://localhost:5173`) must equal the browser origin.

## Deploy
```bash
wrangler secret put SUPABASE_ANON_KEY --env production
wrangler secret put SUPABASE_SERVICE_ROLE_KEY --env production
# only for legacy HS256 projects:  wrangler secret put SUPABASE_JWT_SECRET --env production
# edit [env.production.vars] in wrangler.toml, uncomment [env.production.assets] to serve the built frontend
npm run deploy
```
The Worker refuses to run if `ENVIRONMENT=production` and `DEV_INSECURE_COOKIES=true`, or if a required variable is missing.

## Decisions
- **Throttling storage: Postgres, not the Workers Rate Limiting binding.** Checked in the Cloudflare docs: the binding only accepts a 10 or 60 second period and counts per Cloudflare location, so it cannot express "5 per 15 minutes" or return an accurate `retryAfterSeconds`. Counters live in `auth_login_attempts`, updated by one atomic RPC (`auth_throttle_hit`) that also audits `LOGIN_BLOCKED` once per window. No Workers KV.
- **JWT verification:** default is the project JWKS (asymmetric keys), fetched once per isolate and cached by jose; no per-request subrequest. If `SUPABASE_JWT_SECRET` is set (legacy HS256 projects) tokens are verified locally with it instead. Checks `exp`, `iss`, `aud`.
- **Subrequests:** successful login = 3 (throttle RPC, password grant, `login_profile_and_audit` RPC which loads the profile, writes the audit row and resets the counter in one trip). Failure paths add one deferred audit or sign-out call.
- **Profile is read on every protected request** (no cache), so revocation and role changes apply immediately.
- **`/me` answers 401 (not 403) for an inactive/revoked user**, so the SPA treats them as signed out. Guarded routes answer 403 `ACCOUNT_INACTIVE` / `ACCOUNT_REVOKED`.
- `Cache-Control: no-store` is applied to all `/api/*`, a superset of `/api/auth/*`. CSRF checks also apply to refresh and logout.

## curl examples (dev, http; cookies in a jar)
```bash
H='-H Content-Type:application/json -H X-Requested-With:moraya-web -H Origin:http://localhost:5173'
# login ok
curl -i -c jar.txt $H -d '{"email":"owner@example.com","password":"<password>"}' http://127.0.0.1:8787/api/auth/login
# wrong password / unknown email: identical 401
curl -i $H -d '{"email":"owner@example.com","password":"wrong"}' http://127.0.0.1:8787/api/auth/login
# validation error (400), CSRF failure (403: no header/origin), rate limit (429 after 5 bad tries)
curl -i -H Content-Type:application/json -d '{"email":"x","password":"y"}' http://127.0.0.1:8787/api/auth/login
# me / guarded routes
curl -i -b jar.txt http://127.0.0.1:8787/api/auth/me
curl -i -b jar.txt http://127.0.0.1:8787/api/admin/ping
# refresh (204, rotated cookies), logout (204, cleared cookies)
curl -i -b jar.txt -c jar.txt $H -X POST http://127.0.0.1:8787/api/auth/refresh
curl -i -b jar.txt -c jar.txt $H -X POST http://127.0.0.1:8787/api/auth/logout
# forgot password: always 202 {"ok":true}
curl -i $H -d '{"email":"anyone@example.com"}' http://127.0.0.1:8787/api/auth/forgot-password
```

## Threat model
| Threat | Mitigation in this build |
|---|---|
| Credential stuffing / brute force | Per IP+email (5 / 15 min) and per IP (20 / 15 min) throttle in Postgres, `429` + `retryAfterSeconds`; Supabase hashes passwords; blocked attempts audited once per window |
| Account enumeration | Wrong email, wrong password and missing employee row all return the same `401 INVALID_CREDENTIALS`; 403 status codes only after the password is verified; forgot-password always `202`; audit stores masked email only |
| CSRF | httpOnly `SameSite=Strict` cookies, mandatory `X-Requested-With: moraya-web` and Origin/Referer equal to `ALLOWED_ORIGIN` on every state-changing route |
| Token theft (XSS, logs) | Tokens only in `HttpOnly; Secure; __Host-` cookies, never in bodies; no secrets, tokens or passwords logged; short access token lifetime |
| Privilege escalation | Role and permissions come only from the database on every request; `requireRole` / `requirePermission` return 403; partial unique index allows exactly one Main Admin; RLS on all tables, no client writes |
| Replay by a revoked user | Profile re-read per request; refresh re-checks `account_status`; Supabase session revoked on inactive login/refresh; refresh-token rotation makes replay fail with 401 |
| Audit tampering | Triggers block UPDATE, DELETE and TRUNCATE; privileges revoked from every role including `service_role`; no RLS policies for clients |
| Misconfiguration | `assertEnv()` fails fast; production refuses insecure cookies and non-https origin |

## Assumptions & open questions
- Access-token lifetime comes from Supabase's `expires_in`; set it in the dashboard (default 1 hour).
- Fixed 15-minute windows (not sliding) for throttling; limits are constants in `middleware/rateLimit.ts`. Successful login resets only the IP+email counter.
- `login_email` is checked against `auth.users.email` at write time; later email changes in Auth must update `employees` too (a later phase).
- Reset-password completion endpoint is not built; the reset link lands on `PASSWORD_RESET_REDIRECT_URL`, which the frontend does not have yet.
- Main Admin transfer is intentionally impossible until a dedicated atomic function exists (see comment in migration 002).
- The JWKS path is verified by design but not covered by unit tests (tests use the HS256 path); smoke-test it against your project.
- Static assets binding (`run_worker_first`) is configured but commented out; confirm with your Wrangler version when deploying.
- Nothing in this repo has been executed against a real Supabase project.
