import type { ReactNode } from 'react';
import { Navigate } from 'react-router-dom';
import { PageSkeleton } from '../../components/PageSkeleton';
import { Button } from '../../components/ui/Button';
import { useI18n } from '../../i18n';
import type { Role } from './authApi';
import { homeFor } from './routes';
import { useSession } from './useSession';

/** UX guard only. The Worker API is what actually enforces access. */
export function RequireAuth({ allow, children }: { allow?: Role[]; children: ReactNode }) {
  const { data: user, isPending, isError, refetch } = useSession();
  const { t } = useI18n();

  if (isPending) return <PageSkeleton />;
  if (isError) {
    return (
      <div className="flex min-h-dvh flex-col items-center justify-center gap-4 px-6 text-center">
        <p className="text-text">{t('err.network')}</p>
        <Button onClick={() => void refetch()}>{t('common.retry')}</Button>
      </div>
    );
  }
  if (!user) return <Navigate to="/login" replace />;
  if (allow && !allow.includes(user.role)) return <Navigate to={homeFor(user.role)} replace />;
  return <>{children}</>;
}

export function RootRedirect() {
  const { data: user, isPending } = useSession();
  if (isPending) return <PageSkeleton />;
  return <Navigate to={user ? homeFor(user.role) : '/login'} replace />;
}
