import type { Env } from '../env';
import { rpc } from '../services/supabaseRest';

export const LOGIN_WINDOW_SECONDS = 15 * 60;
export const LOGIN_LIMIT_PER_IP_EMAIL = 5;
export const LOGIN_LIMIT_PER_IP = 20;
export const FORGOT_LIMIT_PER_EMAIL = 3;
export const FORGOT_LIMIT_PER_IP = 10;

export interface ThrottleOptions {
  keys: string[];
  limits: number[];
  windowSeconds: number;
  /** Audit action written ONCE per window when a key first crosses its limit. */
  blockAction: string;
  ip: string | null;
  userAgent: string | null;
  requestId: string;
  emailMasked: string;
}

export interface ThrottleResult {
  blocked: boolean;
  retryAfterSeconds: number;
}

/** One atomic Postgres call (counters live in auth_login_attempts). Errors surface as 500: fail closed. */
export async function throttle(env: Env, o: ThrottleOptions): Promise<ThrottleResult> {
  const rows = await rpc<{ blocked: boolean; retry_after_seconds: number }[]>(env, 'auth_throttle_hit', {
    p_keys: o.keys,
    p_limits: o.limits,
    p_window_seconds: o.windowSeconds,
    p_audit_action: o.blockAction,
    p_ip: o.ip,
    p_user_agent: o.userAgent,
    p_request_id: o.requestId,
    p_email_masked: o.emailMasked,
  });
  const row = rows[0];
  return { blocked: row?.blocked ?? false, retryAfterSeconds: row?.retry_after_seconds ?? 0 };
}
