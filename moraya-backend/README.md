# Moraya API: backend (authentication + database layer)

Cloudflare Worker (Hono + Zod + jose) on Supabase Auth + PostgreSQL.

**Status**
- Worker: authentication only. Endpoints: `POST /api/auth/login`, `GET /api/auth/me`, `POST /api/auth/refresh`, `POST /api/auth/logout`, `POST /api/auth/forgot-password`, plus sample guarded routes `GET /api/worker/ping`, `GET /api/admin/ping`, `GET /api/admin/report-ping`. No sign-up endpoint exists.
- Database: the full business layer is written as SQL migrations `001` to `026` (employees, sites, work entries, expenses, income, salary, financial formulas, 14 reports, client bill, dashboards, audit queries, hardening) plus a read-only RLS check (`027`).
- **Not built yet:** Worker routes that call the new SQL functions. Each function is meant to be called by the Worker through RPC with the actor's `auth_user_id`, using the service role key.

## Layout
```
src/            index.ts, env.ts, routes/{auth,ping}.ts, middleware/{csrf,auth,rbac,rateLimit,requestId,security}.ts,
                services/{supabaseAuth,supabaseRest,profile,audit,cookies,jwt}.ts, lib/{errors,validation,mask,request}.ts
supabase/migrations/001..026_*.sql      run in order (see table below)
supabase/checks/027_rls_coverage_check.sql   read-only verification, NOT a migration
supabase/tests/moraya_all_tests.sql     full SQL test suite (rolls back; empty dev DB only)
supabase/tests/main_admin_and_audit.sql older manual test for 001-007 (rolls back)
seed/001_main_admin.sql                 first Main Admin (production and dev)
seed/002_dev_test_users.sql             fake dev data (dev only, never production)
test/                                   Vitest (Supabase mocked with fetch stubs)
```

## Migrations
| File | What it does |
|---|---|
| 001 to 007 | Extensions and enums, employees, sub-admin permissions, audit log, login throttle, profile functions, RLS and grants |
| 008 | `write_audit` helper, audit action catalogue, human-readable summary |
| 009 | Main Admin protection (one active main admin, last-admin triggers), `transfer_main_admin` |
| 010 | `app_settings` (company, bank details, bill prefix, `workers_can_see_salary`) and its functions |
| 011 | Own profile functions, password-change audit |
| 012 | Employee columns, Aadhaar encryption, masking, `reveal_aadhaar` |
| 013 | Employee create, update, status, promote, revoke, permissions, get, list |
| 014 | Sites and site functions |
| 015 | Work entries, `WE-YYYY-NNNNN` counter, no-future-date trigger (Asia/Kolkata) |
| 016 | Expenses and history tables |
| 017 | Work entry state machine: submit, resubmit, approve, request changes, reject, cancel, lists |
| 018 | Income |
| 019 | Salary |
| 020 | Financial formulas, the single source of truth for all money totals |
| 021 to 023 | Reports 1 to 14 |
| 024 | Client bill (financial-year counter, generate, get) |
| 025 | Admin and worker dashboards |
| 026 | Audit log queries, delete blocking on financial tables, extra constraints and indexes |
| checks/027 | Read-only RLS and grants coverage check |

Conventions: money is bigint paise; enum and status values are lowercase snake_case; every function is `SECURITY DEFINER`, `search_path = public, pg_temp`, executable by `service_role` only, re-checks role, permission and active status, writes an audit record, and raises stable codes (`MORAYA_FORBIDDEN`, `MORAYA_NOT_FOUND`, `MORAYA_INVALID_STATE`, `MORAYA_VALIDATION`). Financial tables have no DELETE grant and a trigger that blocks DELETE.

## Prerequisites
Node 20+, a Supabase project, a Cloudflare account, `npm install`.

## Supabase setup
1. **Authentication > Sign In / Providers: turn OFF "Allow new users to sign up"** (otherwise anyone with the public anon key can call Supabase's own signup endpoint). Keep email provider enabled.
2. **Authentication > Sessions**: set *JWT expiry* (e.g. 3600 s; shorter = faster revocation, more refresh calls). Keep refresh-token rotation on. The refresh cookie lives `REFRESH_COOKIE_DAYS` (default 7).
3. **Authentication > URL Configuration**: add your `PASSWORD_RESET_REDIRECT_URL` to the redirect allow-list.
4. `citext` and `pgcrypto` are enabled by 001.

## Database setup
Use a **dev or test project first**, never production.
1. Run migrations `001` to `026` in order (SQL editor one file at a time, or `supabase db push`). Stop at the first error and fix it before continuing. Never edit an applied migration; add a new numbered one instead.
2. **Tests (empty database only).** Run `supabase/tests/moraya_all_tests.sql`. It aborts if `employees` has any rows, creates its own fake data and rolls back. Every line must say `PASS` and the end must say `ALL n CHECKS PASSED`.
3. **Seed one of these (after the tests):**
   - Production or real use: create the first admin in Dashboard > Authentication > Users (strong password chosen by the owner), copy its UUID into `seed/001_main_admin.sql` (email must match, lowercase) and run it.
   - Dev screens with sample data: create four Auth users first (`dev-main@`, `dev-sub@`, `dev-worker1@`, `dev-worker2@moraya.test`, auto-confirmed), then run `seed/002_dev_test_users.sql`. It replaces seed 001 and aborts if `employees` already has rows. **Never run it on production.**
4. **Coverage check.** Run `supabase/checks/027_rls_coverage_check.sql`. Every SUMMARY row must say PASS and there must be no FINDING rows.
5. Optional: `supabase/tests/main_admin_and_audit.sql` (older test for 001-007, expects only `PASS` notices).

## Aadhaar encryption key
Aadhaar numbers are stored encrypted with pgcrypto, with a separate `last4` column. The key is never stored in the database. The Worker must pass it per call (suggested secret name `AADHAAR_ENC_KEY`, 32 random characters or more).
- Production: `wrangler secret put AADHAAR_ENC_KEY --env production`. Back it up safely; losing it makes stored Aadhaar numbers unreadable.
- Dev: the seed uses a fake key (see the top of `seed/002_dev_test_users.sql`); put the same value in `.dev.vars` as `AADHAAR_ENC_KEY`.
- The Worker does not read this variable yet; add it to `env.ts` when the employee routes are built.

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
wrangler secret put AADHAAR_ENC_KEY --env production        # once employee routes exist
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
- **Money logic lives only in migration 020.** Reports, the client bill and dashboards read from it, so the same number appears everywhere. Official totals count VERIFIED work only; pending is shown separately.
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
- Main Admin transfer is done only by `transfer_main_admin` (migration 009); no Worker endpoint calls it yet.
- The JWKS path is verified by design but not covered by unit tests (tests use the HS256 path); smoke-test it against your project.
- Static assets binding (`run_worker_first`) is configured but commented out; confirm with your Wrangler version when deploying.
- Migrations 008-027, the seed and the tests have not been executed against a real Supabase project yet. Run them as described in "Database setup" and fix anything that fails.