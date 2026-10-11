import { NavLink } from 'react-router-dom';
import { ChevronLeftIcon, ChevronRightIcon } from '../../components/icons';
import { Logo } from '../../components/Logo';
import { useI18n } from '../../i18n';
import type { NavItem } from './navConfig';

interface SidebarNavProps {
  items: NavItem[];
  collapsed?: boolean;
  onNavigate?: () => void;
}

/** Nav list shared by the desktop sidebar and the mobile drawer. NavLink sets aria-current="page". */
export function SidebarNav({ items, collapsed = false, onNavigate }: SidebarNavProps) {
  const { t } = useI18n();
  return (
    <nav aria-label={t('nav.label')} className="flex-1 overflow-y-auto px-2 py-3">
      <ul className="space-y-1">
        {items.map((item) => {
          const Icon = item.icon;
          const label = t(item.labelKey);
          return (
            <li key={item.path}>
              <NavLink
                to={item.path}
                end={item.path === '/admin'}
                onClick={onNavigate}
                title={collapsed ? label : undefined}
                className={`nav-link ${collapsed ? 'justify-center !px-0' : ''}`}
              >
                <Icon className="shrink-0" />
                <span className={collapsed ? 'sr-only' : 'min-w-0 flex-1 break-words'}>{label}</span>
              </NavLink>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}

interface SidebarProps {
  items: NavItem[];
  collapsed: boolean;
  onToggle: () => void;
}

/** Fixed sidebar for desktop (1024px and up). Collapses to icons. */
export function Sidebar({ items, collapsed, onToggle }: SidebarProps) {
  const { t } = useI18n();
  const ToggleIcon = collapsed ? ChevronRightIcon : ChevronLeftIcon;
  return (
    <aside
      className={`fixed inset-y-0 left-0 z-30 hidden flex-col border-r border-border bg-surface transition-[width] duration-150 lg:flex ${
        collapsed ? 'w-16' : 'w-60'
      }`}
    >
      <div className={`flex h-14 shrink-0 items-center border-b border-border ${collapsed ? 'justify-center' : 'px-4'}`}>
        <Logo className={collapsed ? 'w-8' : 'w-10'} />
      </div>
      <SidebarNav items={items} collapsed={collapsed} />
      <div className="border-t border-border p-2">
        <button
          type="button"
          onClick={onToggle}
          aria-expanded={!collapsed}
          aria-label={collapsed ? t('nav.expand') : t('nav.collapse')}
          title={collapsed ? t('nav.expand') : t('nav.collapse')}
          className={`nav-link w-full ${collapsed ? 'justify-center !px-0' : ''}`}
        >
          <ToggleIcon className="shrink-0" />
          <span className={collapsed ? 'sr-only' : ''}>{t('nav.collapse')}</span>
        </button>
      </div>
    </aside>
  );
}
