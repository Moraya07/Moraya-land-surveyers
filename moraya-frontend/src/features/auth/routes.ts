import type { Role } from './authApi';

export const ADMIN_ROLES: Role[] = ['main_admin', 'sub_admin'];

/** UX-only mapping. The server's redirectTo wins on login; the backend enforces access. */
export function homeFor(role: Role): string {
  return role === 'worker' ? '/home' : '/admin';
}

/** Accept only same-origin absolute paths from the server; otherwise fall back by role. */
export function safeRedirect(target: string | undefined, role: Role): string {
  if (target && target.startsWith('/') && !target.startsWith('//') && !target.startsWith('/login')) return target;
  return homeFor(role);
}
