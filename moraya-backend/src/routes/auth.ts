import { Hono } from 'hono';
import type { AppEnv } from '../env';
import { AppError, jsonError } from '../lib/errors';
import { maskEmail, sha256Hex } from '../lib/mask';
import { clientIp, defer, userAgent } from '../lib/request';
import { forgotPasswordSchema, loginSchema, readJson } from '../lib/validation';
import { authenticate } from '../middleware/auth';
import {
  FORGOT_LIMIT_PER_EMAIL,
  FORGOT_LIMIT_PER_IP,
  LOGIN_LIMIT_PER_IP,
  LOGIN_LIMIT_PER_IP_EMAIL,
  LOGIN_WINDOW_SECONDS,
  throttle,
} from '../middleware/rateLimit';
import { writeAudit } from '../services/audit';
import { clearSessionCookies, cookieNames, readCookie, setSessionCookies } from '../services/cookies';
import { verifyAccessToken } from '../services/jwt';
import { getProfile, loginProfileAndAudit, redirectFor, toAuthUser } from '../services/profile';
import { passwordGrant, recover, refreshGrant, signOut } from '../services/supabaseAuth';

export const auth = new Hono<AppEnv>();

// POST /api/auth/login  (subrequests on success: throttle, password grant, profile+audit = 3)
auth.post('/login', async (c) => {
  const { email, password } = await readJson(c, loginSchema);
  const requestId = c.get('requestId');
  const ip = clientIp(c);
  const ua = userAgent(c);
  const emailMasked = maskEmail(email);
  const ipPart = ip ?? 'unknown';
  const pairKey = `login:ip-email:${ipPart}:${(await sha256Hex(email)).slice(0, 32)}`;

  const t = await throttle(c.env, {
    keys: [pairKey, `login:ip:${ipPart}`],
    limits: [LOGIN_LIMIT_PER_IP_EMAIL, LOGIN_LIMIT_PER_IP],
    windowSeconds: LOGIN_WINDOW_SECONDS,
    blockAction: 'LOGIN_BLOCKED',
    ip,
    userAgent: ua,
    requestId,
    emailMasked,
  });
  if (t.blocked) throw new AppError(429, 'RATE_LIMITED', t.retryAfterSeconds);

  // Wrong email and wrong password are indistinguishable here (both: null).
  const session = await passwordGrant(c.env, email, password);
  if (!session) {
    defer(
      c,
      writeAudit(c.env, {
        action: 'LOGIN_FAILED',
        ip,
        userAgent: ua,
        reason: 'INVALID_CREDENTIALS',
        newValue: { email_masked: emailMasked },
        requestId,
      }),
    );
    throw new AppError(401, 'INVALID_CREDENTIALS');
  }

  const profile = await loginProfileAndAudit(c.env, {
    authUserId: session.authUserId,
    ip,
    userAgent: ua,
    requestId,
    emailMasked,
    resetKey: pairKey,
  });

  if (!profile) {
    defer(c, signOut(c.env, session.accessToken));
    throw new AppError(401, 'INVALID_CREDENTIALS'); // no employee row: same answer as a wrong password
  }
  if (profile.account_status !== 'active') {
    defer(c, signOut(c.env, session.accessToken)); // no cookies, and the new session is revoked
    throw new AppError(403, profile.account_status === 'revoked' ? 'ACCOUNT_REVOKED' : 'ACCOUNT_INACTIVE');
  }

  setSessionCookies(c, c.env, session);
  return c.json({ user: toAuthUser(profile), redirectTo: redirectFor(profile.role) });
});

// GET /api/auth/me
auth.get('/me', async (c) => {
  const a = await authenticate(c, 'unauthenticated');
  return c.json({ user: toAuthUser(a.employee) });
});

// POST /api/auth/refresh
auth.post('/refresh', async (c) => {
  const unauthenticated = () => {
    clearSessionCookies(c, c.env);
    return jsonError(c, new AppError(401, 'UNAUTHENTICATED'));
  };

  const refreshToken = readCookie(c.req.header('Cookie'), cookieNames(c.env).rt);
  if (!refreshToken) return unauthenticated();

  // A rotated/reused refresh token is rejected by Supabase (null) and ends here as a clean 401.
  const session = await refreshGrant(c.env, refreshToken);
  if (!session) return unauthenticated();

  const profile = await getProfile(c.env, session.authUserId);
  if (!profile || profile.account_status !== 'active') {
    defer(c, signOut(c.env, session.accessToken)); // a revoked user must not keep a session
    return unauthenticated();
  }

  setSessionCookies(c, c.env, session);
  return c.body(null, 204);
});

// POST /api/auth/logout : always clears cookies and answers 204
auth.post('/logout', async (c) => {
  const token = readCookie(c.req.header('Cookie'), cookieNames(c.env).at);
  let authUserId: string | null = null;
  if (token) {
    defer(c, signOut(c.env, token));
    authUserId = await verifyAccessToken(c.env, token).catch(() => null);
  }
  if (authUserId) {
    defer(
      c,
      writeAudit(c.env, {
        action: 'LOGOUT',
        entityType: 'auth_user',
        entityId: authUserId,
        ip: clientIp(c),
        userAgent: userAgent(c),
        requestId: c.get('requestId'),
      }),
    );
  }
  clearSessionCookies(c, c.env);
  return c.body(null, 204);
});

// POST /api/auth/forgot-password : identical 202 whether or not the email exists
auth.post('/forgot-password', async (c) => {
  const { email } = await readJson(c, forgotPasswordSchema);
  const requestId = c.get('requestId');
  const ip = clientIp(c);
  const ua = userAgent(c);
  const emailMasked = maskEmail(email);

  const t = await throttle(c.env, {
    keys: [`forgot:email:${(await sha256Hex(email)).slice(0, 32)}`, `forgot:ip:${ip ?? 'unknown'}`],
    limits: [FORGOT_LIMIT_PER_EMAIL, FORGOT_LIMIT_PER_IP],
    windowSeconds: LOGIN_WINDOW_SECONDS,
    blockAction: 'PASSWORD_RESET_BLOCKED',
    ip,
    userAgent: ua,
    requestId,
    emailMasked,
  });
  if (t.blocked) throw new AppError(429, 'RATE_LIMITED', t.retryAfterSeconds);

  await recover(c.env, email); // only a network failure throws (-> generic 500)
  defer(
    c,
    writeAudit(c.env, {
      action: 'PASSWORD_RESET_REQUESTED',
      ip,
      userAgent: ua,
      newValue: { email_masked: emailMasked },
      requestId,
    }),
  );
  return c.json({ ok: true }, 202);
});
