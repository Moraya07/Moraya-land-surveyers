import { useEffect } from 'react';
import { Link, useLocation, useParams } from 'react-router-dom';
import { ErrorState } from '../../../../components/ui/ErrorState';
import { Skeleton } from '../../../../components/ui/Skeleton';
import { useI18n } from '../../../../i18n';
import { ApiError } from '../../../../lib/errors';
import { useSession } from '../../../auth/useSession';
import { EmployeeHeader } from '../detail/EmployeeHeader';
import { EmployeeTabs } from '../detail/EmployeeTabs';
import { useEmployee } from '../hooks';
import { readListSearch } from '../list/listReturn';

const LIST_PATH = '/admin/employees';

function DetailSkeleton() {
  const { t } = useI18n();
  return (
    <div role="status" aria-busy="true" className="space-y-5">
      <span className="sr-only">{t('common.loading')}</span>
      <div className="space-y-3">
        <Skeleton className="h-5 w-40" />
        <Skeleton className="h-8 w-2/3 max-w-sm" />
        <Skeleton className="h-5 w-56 max-w-full" />
      </div>
      <Skeleton className="h-11 w-full max-w-md" />
      <div className="grid gap-4 lg:grid-cols-2">
        <Skeleton className="h-64 w-full" />
        <Skeleton className="h-64 w-full" />
        <Skeleton className="h-24 w-full" />
        <Skeleton className="h-36 w-full" />
      </div>
    </div>
  );
}

/** A message with a way back to the list (not found / no access). */
function Message({ text, listSearch }: { text: string; listSearch: string }) {
  const { t } = useI18n();
  return (
    <div role="alert" className="rounded-lg border border-border bg-surface px-4 py-8 text-center">
      <p className="text-text">{text}</p>
      <Link to={{ pathname: LIST_PATH, search: listSearch }} className="link-action mt-3 inline-flex min-h-11 items-center">
        {t('detail.back')}
      </Link>
    </div>
  );
}

/** `/admin/employees/:id`. The employee is fetched once here; tabs and the profile only read it. */
export function EmployeeDetailPage() {
  const { t } = useI18n();
  const { id } = useParams();
  const location = useLocation();
  const { data: user } = useSession();
  const query = useEmployee(id);
  const employee = query.data;
  const listSearch = readListSearch(location.state);

  // "{name} · Employees". Built from the name only: the title never carries Aadhaar or any other identifier.
  const name = employee?.name;
  const sectionTitle = t('emp.title');
  useEffect(() => {
    if (!name) return;
    const previous = document.title;
    document.title = `${name} · ${sectionTitle}`;
    return () => {
      document.title = previous;
    };
  }, [name, sectionTitle]);

  const error = query.error;
  // These also win over cached data: a refetch that says "gone" or "not allowed" is the truth.
  if (error instanceof ApiError && error.status === 404) {
    return <Message text={t('detail.notFound')} listSearch={listSearch} />;
  }
  if (error instanceof ApiError && error.status === 403) {
    return <Message text={t('err.noAccess')} listSearch={listSearch} />;
  }
  if (!employee) {
    if (query.isError) {
      return <ErrorState message={t('err.load')} onRetry={() => void query.refetch()} retrying={query.isFetching} />;
    }
    return <DetailSkeleton />;
  }

  return (
    <div className="min-w-0 space-y-5">
      <EmployeeHeader employee={employee} listSearch={listSearch} />
      <EmployeeTabs employee={employee} user={user} />
    </div>
  );
}

export default EmployeeDetailPage;
