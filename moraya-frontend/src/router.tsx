import { Navigate, createBrowserRouter, type RouteObject } from 'react-router-dom';
import { AdminLayout } from './features/admin/AdminLayout';
import { DashboardPage } from './features/admin/dashboard/DashboardPage';
import { NAV_ITEMS } from './features/admin/navConfig';
import { ComingSoonPage } from './features/admin/pages/ComingSoonPage';
import { NotFoundInShell } from './features/admin/pages/NotFoundInShell';
import { ForgotPasswordPage } from './features/auth/ForgotPasswordPage';
import { LoginPage } from './features/auth/LoginPage';
import { RequireAuth, RootRedirect } from './features/auth/RequireAuth';
import { ADMIN_ROLES } from './features/auth/routes';
import { HomePlaceholder } from './pages/HomePlaceholder';

// Every nav destination except the dashboard is a placeholder until its phase is built.
const placeholderRoutes: RouteObject[] = NAV_ITEMS.filter((item) => item.path !== '/admin').map((item) => ({
  path: item.path.replace('/admin/', ''),
  element: <ComingSoonPage titleKey={item.labelKey} />,
}));

export const router = createBrowserRouter([
  { path: '/', element: <RootRedirect /> },
  { path: '/login', element: <LoginPage /> },
  { path: '/forgot-password', element: <ForgotPasswordPage /> },
  {
    path: '/admin',
    element: (
      <RequireAuth allow={ADMIN_ROLES}>
        <AdminLayout />
      </RequireAuth>
    ),
    children: [
      { index: true, element: <DashboardPage /> },
      ...placeholderRoutes,
      { path: '*', element: <NotFoundInShell /> },
    ],
  },
  {
    path: '/home',
    element: (
      <RequireAuth allow={['worker']}>
        <HomePlaceholder />
      </RequireAuth>
    ),
  },
  { path: '*', element: <Navigate to="/" replace /> },
]);
