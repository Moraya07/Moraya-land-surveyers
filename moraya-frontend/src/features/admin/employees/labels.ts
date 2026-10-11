import type { DictKey } from '../../../i18n';
import type { AccountStatus, Permission, Role } from './types';

export const ROLE_LABEL: Record<Role, DictKey> = {
  main_admin: 'role.main_admin',
  sub_admin: 'role.sub_admin',
  worker: 'role.worker',
};

export const STATUS_LABEL: Record<AccountStatus, DictKey> = {
  active: 'acct.active',
  inactive: 'acct.inactive',
  revoked: 'acct.revoked',
};

export const PERMISSION_LABEL: Record<Permission, DictKey> = {
  employee_management: 'perm.employee_management',
  site_management: 'perm.site_management',
  verification: 'perm.verification',
  income_management: 'perm.income_management',
  salary_management: 'perm.salary_management',
  report_view: 'perm.report_view',
  export: 'perm.export',
};

/** Display order wherever permissions are listed or edited. */
export const PERMISSION_ORDER: readonly Permission[] = [
  'employee_management',
  'site_management',
  'verification',
  'income_management',
  'salary_management',
  'report_view',
  'export',
];
