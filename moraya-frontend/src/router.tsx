import { Navigate, createBrowserRouter } from 'react-router-dom';
import { ForgotPasswordPage } from './features/auth/ForgotPasswordPage';
import { LoginPage } from './features/auth/LoginPage';
import { RequireAuth, RootRedirect } from './features/auth/RequireAuth';
import { ADMIN_ROLES } from './features/auth/routes';
import { AdminPlaceholder } from './pages/AdminPlaceholder';
import { HomePlaceholder } from './pages/HomePlaceholder';

export const router = createBrowserRouter([
  { path: '/', element: <RootRedirect /> },
  { path: '/login', element: <LoginPage /> },
  { path: '/forgot-password', element: <ForgotPasswordPage /> },
  {
    path: '/admin',
    element: (
      <RequireAuth allow={ADMIN_ROLES}>
        <AdminPlaceholder />
      </RequireAuth>
    ),
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
