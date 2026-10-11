import {
  ArrowDownCircleIcon,
  BanknoteIcon,
  ClipboardIcon,
  DashboardIcon,
  FileTextIcon,
  HistoryIcon,
  KeyIcon,
  MapPinIcon,
  ReceiptIcon,
  ShieldCheckIcon,
  SlidersIcon,
  UsersIcon,
} from '../../components/icons';
import type { DictKey } from '../../i18n';
import type { AuthUser } from '../auth/authApi';
import { hasPermission, type Permission } from './permissions';

/**
 * The single place that decides which admin screens appear in the navigation.
 * This is UX only: hiding an item never grants or removes access, the backend enforces every permission.
 * (To change who sees an item, edit its `access` below.)
 *
 *   'any_admin'          main_admin and sub_admin
 *   'main_admin'         main_admin only
 *   { permission }       main_admin, or a sub_admin holding that permission
 */
export type NavAccess = 'any_admin' | 'main_admin' | { permission: Permission };

export interface NavItem {
  path: string;
  labelKey: DictKey;
  icon: typeof DashboardIcon;
  access: NavAccess;
}

export const NAV_ITEMS: readonly NavItem[] = [
  { path: '/admin', labelKey: 'nav.dashboard', icon: DashboardIcon, access: 'any_admin' },
  { path: '/admin/employees', labelKey: 'nav.employees', icon: UsersIcon, access: { permission: 'employee_management' } },
  { path: '/admin/sites', labelKey: 'nav.sites', icon: MapPinIcon, access: { permission: 'site_management' } },
  { path: '/admin/verification', labelKey: 'nav.verification', icon: ShieldCheckIcon, access: { permission: 'verification' } },
  { path: '/admin/work', labelKey: 'nav.work', icon: ClipboardIcon, access: { permission: 'verification' } },
  { path: '/admin/expenses', labelKey: 'nav.expenses', icon: ReceiptIcon, access: { permission: 'verification' } },
  { path: '/admin/income', labelKey: 'nav.income', icon: ArrowDownCircleIcon, access: { permission: 'income_management' } },
  { path: '/admin/salary', labelKey: 'nav.salary', icon: BanknoteIcon, access: { permission: 'salary_management' } },
  { path: '/admin/reports', labelKey: 'nav.reports', icon: FileTextIcon, access: { permission: 'report_view' } },
  { path: '/admin/users', labelKey: 'nav.users', icon: KeyIcon, access: 'main_admin' },
  { path: '/admin/audit', labelKey: 'nav.audit', icon: HistoryIcon, access: 'main_admin' },
  { path: '/admin/settings', labelKey: 'nav.settings', icon: SlidersIcon, access: 'main_admin' },
];

export function canSee(user: AuthUser, item: NavItem): boolean {
  if (user.role !== 'main_admin' && user.role !== 'sub_admin') return false;
  if (item.access === 'any_admin') return true;
  if (item.access === 'main_admin') return user.role === 'main_admin';
  return hasPermission(user, item.access.permission);
}

export function visibleNavItems(user: AuthUser): NavItem[] {
  return NAV_ITEMS.filter((item) => canSee(user, item));
}

/** True when `path` is a known nav destination this user may open. */
export function canAccessPath(user: AuthUser, path: string): boolean {
  const item = NAV_ITEMS.find((i) => i.path === path);
  return item ? canSee(user, item) : false;
}

/** Matches the current URL to a nav item (the dashboard only matches exactly). */
export function findNavItem(pathname: string): NavItem | undefined {
  const p = pathname.length > 1 && pathname.endsWith('/') ? pathname.slice(0, -1) : pathname;
  return NAV_ITEMS.find((i) => i.path === p || (i.path !== '/admin' && p.startsWith(`${i.path}/`)));
}
