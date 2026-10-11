import type { AuthUser, Env, Profile } from '../env';
import { rpc } from './supabaseRest';

export async function getProfile(env: Env, authUserId: string): Promise<Profile | null> {
  const rows = await rpc<Profile[]>(env, 'get_auth_profile', { p_auth_user_id: authUserId });
  return rows[0] ?? null;
}

interface LoginAuditArgs {
  authUserId: string;
  ip: string | null;
  userAgent: string | null;
  requestId: string;
  emailMasked: string;
  resetKey: string;
}

/** Profile lookup + audit row + throttle reset in one round trip (used by login only). */
export async function loginProfileAndAudit(env: Env, a: LoginAuditArgs): Promise<Profile | null> {
  return rpc<Profile | null>(env, 'login_profile_and_audit', {
    p_auth_user_id: a.authUserId,
    p_ip: a.ip,
    p_user_agent: a.userAgent,
    p_request_id: a.requestId,
    p_email_masked: a.emailMasked,
    p_reset_key: a.resetKey,
  });
}

export function toAuthUser(p: Profile): AuthUser {
  return {
    id: p.auth_user_id,
    employeeId: p.employee_id,
    name: p.name,
    email: p.login_email,
    role: p.role,
    permissions: p.role === 'sub_admin' ? p.permissions : [],
  };
}

export const redirectFor = (role: Profile['role']): string => (role === 'worker' ? '/home' : '/admin');
