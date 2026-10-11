import { useEffect, useRef } from 'react';
import { Link } from 'react-router-dom';
import { Alert } from '../../../../components/ui/Alert';
import { Button } from '../../../../components/ui/Button';
import { EmptyState } from '../../../../components/ui/EmptyState';
import { ErrorState } from '../../../../components/ui/ErrorState';
import { PageHeader } from '../../../../components/ui/PageHeader';
import { Pagination } from '../../../../components/ui/Pagination';
import { Skeleton } from '../../../../components/ui/Skeleton';
import { useI18n } from '../../../../i18n';
import { ApiError } from '../../../../lib/errors';
import { useMediaQuery } from '../../../../lib/useMediaQuery';
import { useEmployees } from '../hooks';
import { EmployeeCardList, EmployeeCardListSkeleton } from '../list/EmployeeCardList';
import { EmployeeTable, EmployeeTableSkeleton } from '../list/EmployeeTable';
import { EmployeeToolbar } from '../list/EmployeeToolbar';
import { PlusIcon } from '../list/listIcons';
import { PAGE_SIZE, useEmployeeListParams } from '../list/useEmployeeListParams';
import type { EmployeeListResponse, StatusFilter } from '../types';

/** Table from 1280px up (sidebar included); cards below, so a row never has to scroll sideways. */
const WIDE = '(min-width: 1280px)';

function AddEmployeeLink() {
  const { t } = useI18n();
  return (
    <Link to="/admin/employees/new" className="btn-primary !h-11 !w-auto gap-2 px-5 text-sm">
      <PlusIcon width={16} height={16} />
      {t('emp.add')}
    </Link>
  );
}

/** "Active 18 · Inactive 2 · Revoked 1": each count is a real link that sets the Status filter. */
function StatusSummary({
  totals,
  current,
  hrefFor,
}: {
  totals: EmployeeListResponse['totals'];
  current: StatusFilter;
  hrefFor: (patch: { status: StatusFilter }) => string;
}) {
  const { t } = useI18n();
  const parts: ReadonlyArray<{ status: StatusFilter; label: string; count: number }> = [
    { status: 'active', label: t('acct.active'), count: totals.active },
    { status: 'inactive', label: t('acct.inactive'), count: totals.inactive },
    { status: 'revoked', label: t('acct.revoked'), count: totals.revoked },
  ];
  return (
    <div
      role="group"
      aria-label={t('emp.summary', { a: totals.active, i: totals.inactive, r: totals.revoked })}
      className="mt-1 flex flex-wrap items-center gap-x-1 text-sm text-text-muted"
    >
      {parts.map((p, i) => (
        <span key={p.status} className="inline-flex items-center gap-x-1">
          {i > 0 && <span aria-hidden="true">·</span>}
          <Link
            to={{ search: hrefFor({ status: p.status }) }}
            aria-current={current === p.status ? 'true' : undefined}
            className={`inline-flex min-h-11 items-center rounded px-1 hover:text-text hover:underline sm:min-h-8 ${
              current === p.status ? 'font-semibold text-text' : ''
            }`}
          >
            {p.label} <span className="ms-1 tabular-nums">{p.count}</span>
          </Link>
        </span>
      ))}
    </div>
  );
}

export function EmployeesListPage() {
  const { t } = useI18n();
  const list = useEmployeeListParams();
  const query = useEmployees(list.apiParams);
  const wide = useMediaQuery(WIDE);
  const tableTopRef = useRef<HTMLDivElement>(null);

  const { state, setPage } = list;
  const data = query.data;
  const placeholder = query.isPlaceholderData; // the next page is loading; the old rows stay on screen
  const canCreate = data?.capabilities.canCreate === true;

  // A URL such as ?page=9 on a list with 2 pages: move to the last page instead of showing nothing.
  const outOfRange = data !== undefined && data.total > 0 && data.items.length === 0;
  useEffect(() => {
    if (!data || placeholder || !outOfRange) return;
    setPage(Math.max(1, Math.ceil(data.total / PAGE_SIZE)), true);
  }, [data, placeholder, outOfRange, setPage]);

  const goToPage = (page: number) => {
    setPage(page);
    tableTopRef.current?.scrollIntoView({ block: 'start' });
  };

  // 403: a friendly in-shell state. (401 is handled by the shared api wrapper.)
  if (query.error instanceof ApiError && query.error.status === 403 && !data) {
    return (
      <div className="space-y-5">
        <PageHeader title={t('emp.title')} />
        <div role="alert" className="rounded-lg border border-border bg-surface px-4 py-8 text-center">
          <p className="text-text">{t('err.noAccess')}</p>
          <Link to="/admin" className="link-action mt-3 inline-flex min-h-11 items-center">
            {t('admin.goDashboard')}
          </Link>
        </div>
      </div>
    );
  }

  const systemEmpty = data !== undefined && data.totals.active + data.totals.inactive + data.totals.revoked === 0;

  const renderBody = () => {
    if (query.isError && !data) {
      return <ErrorState message={t('err.load')} onRetry={() => void query.refetch()} retrying={query.isFetching} />;
    }
    if (!data || outOfRange) {
      return (
        <div aria-busy="true">
          <span role="status" className="sr-only">
            {t('common.loading')}
          </span>
          {wide ? <EmployeeTableSkeleton /> : <EmployeeCardListSkeleton />}
        </div>
      );
    }
    if (data.items.length === 0) {
      if (systemEmpty) {
        return <EmptyState message={t('emp.emptyNew')} action={canCreate ? <AddEmployeeLink /> : undefined} />;
      }
      return (
        <EmptyState
          message={t('emp.empty')}
          action={
            <Button variant="secondary" onClick={() => (list.filtersActive ? list.clearFilters() : list.setStatus('all'))}>
              {t('filter.clear')}
            </Button>
          }
        />
      );
    }
    return (
      <>
        {query.isError && (
          <Alert variant="danger" role="status">
            {t('list.refreshFailed')}{' '}
            <button type="button" onClick={() => void query.refetch()} className="link-action underline">
              {t('act.retry')}
            </button>
          </Alert>
        )}
        {wide ? (
          <EmployeeTable rows={data.items} sort={state.sort} onSort={list.toggleSort} busy={placeholder} />
        ) : (
          <EmployeeCardList rows={data.items} busy={placeholder} />
        )}
        <Pagination page={data.page} pageSize={data.pageSize} total={data.total} onPageChange={goToPage} busy={placeholder} />
        {!placeholder && (
          <p role="status" className="sr-only">
            {t('emp.showing', {
              from: (data.page - 1) * data.pageSize + 1,
              to: Math.min(data.total, data.page * data.pageSize),
              total: data.total,
            })}
          </p>
        )}
      </>
    );
  };

  return (
    <div className="space-y-5">
      <div>
        <PageHeader title={t('emp.title')} actions={canCreate ? <AddEmployeeLink /> : undefined} />
        {data ? (
          <StatusSummary totals={data.totals} current={state.status} hrefFor={list.hrefFor} />
        ) : (
          !query.isError && <Skeleton className="mt-2 h-5 w-64 max-w-full" />
        )}
      </div>

      <EmployeeToolbar
        q={state.q}
        status={state.status}
        role={state.role}
        filtersActive={list.filtersActive}
        onQuery={list.setQuery}
        onStatus={list.setStatus}
        onRole={list.setRole}
        onClear={list.clearFilters}
      />

      <div ref={tableTopRef} className="scroll-mt-16 space-y-4">
        {renderBody()}
      </div>
    </div>
  );
}

export default EmployeesListPage;
