import { useCallback, useEffect, useRef, useState } from 'react';
import { Navigate, Outlet, useLocation } from 'react-router-dom';
import { useI18n } from '../../i18n';
import { useSession } from '../auth/useSession';
import { MobileDrawer } from './MobileDrawer';
import { canSee, findNavItem, visibleNavItems } from './navConfig';
import { Sidebar } from './Sidebar';
import { Topbar } from './Topbar';

// Non-sensitive UI preference, so localStorage is allowed here.
const SIDEBAR_KEY = 'moraya.sidebar';

function readCollapsed(): boolean {
  try {
    return localStorage.getItem(SIDEBAR_KEY) === 'collapsed';
  } catch {
    return false;
  }
}

/** Authenticated admin shell: sidebar (drawer on small screens), top bar and the page outlet. */
export function AdminLayout() {
  const { t } = useI18n();
  const { data: user } = useSession();
  const { pathname } = useLocation();
  const [collapsed, setCollapsed] = useState(readCollapsed);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const mainRef = useRef<HTMLElement>(null);
  const lastPath = useRef(pathname);

  const closeDrawer = useCallback(() => setDrawerOpen(false), []);

  // On navigation: close the drawer and move focus to the page content.
  useEffect(() => {
    setDrawerOpen(false);
    if (lastPath.current === pathname) return;
    lastPath.current = pathname;
    mainRef.current?.focus({ preventScroll: true });
  }, [pathname]);

  const toggleCollapsed = () => {
    const next = !collapsed;
    setCollapsed(next);
    try {
      localStorage.setItem(SIDEBAR_KEY, next ? 'collapsed' : 'expanded');
    } catch {
      /* keep in memory only */
    }
  };

  if (!user) return null;

  // UX-only guard: a nav destination this user can't see goes back to the dashboard.
  const navItem = findNavItem(pathname);
  if (navItem && !canSee(user, navItem)) return <Navigate to="/admin" replace />;

  const items = visibleNavItems(user);
  const title = navItem ? t(navItem.labelKey) : t('admin.notFound');

  return (
    <div className="min-h-dvh bg-background text-text">
      <a
        href="#main"
        className="sr-only focus:not-sr-only focus:fixed focus:left-3 focus:top-3 focus:z-50 focus:rounded-md focus:border focus:border-border focus:bg-surface focus:px-3 focus:py-2 focus:text-sm focus:font-medium"
      >
        {t('nav.skip')}
      </a>
      <Sidebar items={items} collapsed={collapsed} onToggle={toggleCollapsed} />
      <MobileDrawer open={drawerOpen} onClose={closeDrawer} items={items} />
      <div className={`transition-[padding] duration-150 ${collapsed ? 'lg:pl-16' : 'lg:pl-60'}`}>
        <Topbar title={title} menuOpen={drawerOpen} onOpenMenu={() => setDrawerOpen(true)} />
        <main
          id="main"
          ref={mainRef}
          tabIndex={-1}
          className="mx-auto w-full max-w-[1400px] px-4 py-6 outline-none sm:px-6"
        >
          <Outlet />
        </main>
      </div>
    </div>
  );
}
