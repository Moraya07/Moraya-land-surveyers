import type { AuthUser } from '../auth/authApi';

/** Names follow the Updated Tech Stack list. */
export type Permission =
  | 'employee_management'
  | 'site_management'
  | 'verification'
  | 'income_management'
  | 'salary_management'
  | 'report_view'
  | 'export';

/** main_admin implicitly has every permission. UX only: the backend enforces access. */
export function hasPermission(user: Pick<AuthUser, 'role' | 'permissions'>, permission: Permission): boolean {
  return user.role === 'main_admin' || user.permissions.includes(permission);
}
