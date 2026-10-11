import { Suspense, lazy, type ComponentType, type ReactNode } from 'react';
import { Navigate, Outlet, useParams, type RouteObject } from 'react-router-dom';
import { Skeleton } from '../../../components/ui/Skeleton';
import { useI18n, type DictKey } from '../../../i18n';
import { useSession } from '../../auth/useSession';
import { NotFoundInShell } from '../pages/NotFoundInShell';
import { hasPermission } from '../permissions';

// Each page is lazy-loaded.
const ListPage = lazy(() => import('./pages/EmployeesListPage'));
const CreatePage = lazy(() => import('./pages/CreateEmployeePage'));
const DetailPage = lazy(() => import('./pages/EmployeeDetailPage'));
const EditPage = lazy(() => import('./pages/EditEmployeePage'));

// Dev-only dialog harness. The condition is written inline so a production build drops the branch and the import.
const DialogHarness =
  import.meta.env.DEV && import.meta.env.VITE_USE_MOCK_EMPLOYEES === 'true'
    ? lazy(() => import('./dev/DialogHarness'))
    : null;

const UUID_LIKE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function RouteFallback() {
  const { t } = useI18n();
  return (
    <div role="status" aria-busy="true" className="space-y-4">
      <span className="sr-only">{t('common.loading')}</span>
      <Skeleton className="h-8 w-1/3" />
      <Skeleton className="h-40 w-full" />
    </div>
  );
}

function Lazy({ children }: { children: ReactNode }) {
  return <Suspense fallback={<RouteFallback />}>{children}</Suspense>;
}

/** UX guard only (the API enforces access): main_admin, or sub_admin with employee_management. */
function RequireEmployeeManagement() {
  const { data: user } = useSession();
  if (!user) return null; // AdminLayout only renders for a signed-in user
  const isAdmin = user.role === 'main_admin' || user.role === 'sub_admin';
  if (!isAdmin || !hasPermission(user, 'employee_management')) return <Navigate to="/admin" replace />;
  return <Outlet />;
}

/** A malformed :id never reaches the API: it gets the in-shell not-found page. */
function RequireValidId({ children }: { children: ReactNode }) {
  const { id } = useParams();
  if (!id || !UUID_LIKE.test(id)) return <NotFoundInShell />;
  return <>{children}</>;
}

// The pages take no props; a component without props also fits `ComponentType<{ titleKey }>`.
function Page({ titleKey, Component }: { titleKey: DictKey; Component: ComponentType<{ titleKey: DictKey }> }) {
  return (
    <Lazy>
      <Component titleKey={titleKey} />
    </Lazy>
  );
}

/** Children of the `/admin` AdminLayout route. */
export const employeeRoutes: RouteObject[] = [
  {
    path: 'employees',
    element: <RequireEmployeeManagement />,
    children: [
      { index: true, element: <Page titleKey="nav.employees" Component={ListPage} /> },
      { path: 'new', element: <Page titleKey="emp.route.new" Component={CreatePage} /> },
      ...(DialogHarness
        ? [
            {
              path: '__dialogs',
              element: (
                <Lazy>
                  <DialogHarness />
                </Lazy>
              ),
            },
          ]
        : []),
      {
        path: ':id',
        element: (
          <RequireValidId>
            <Page titleKey="emp.route.detail" Component={DetailPage} />
          </RequireValidId>
        ),
      },
      {
        path: ':id/edit',
        element: (
          <RequireValidId>
            <Page titleKey="emp.route.edit" Component={EditPage} />
          </RequireValidId>
        ),
      },
    ],
  },
];
