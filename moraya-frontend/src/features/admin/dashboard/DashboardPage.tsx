import { useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { Alert } from '../../../components/ui/Alert';
import { Button } from '../../../components/ui/Button';
import { ErrorState } from '../../../components/ui/ErrorState';
import { PageHeader } from '../../../components/ui/PageHeader';
import { useI18n } from '../../../i18n';
import { ApiError } from '../../../lib/errors';
import { formatTime } from '../../../lib/format';
import { useSession } from '../../auth/useSession';
import { useNavAccess } from '../useNavAccess';
import { AttentionStrip } from './AttentionStrip';
import { DashboardSkeleton } from './DashboardSkeleton';
import { FinancialOverview } from './FinancialOverview';
import { PERIODS, parsePeriod, useDashboard } from './hooks';
import { KpiGrid } from './KpiGrid';
import { MoreActivityTabs } from './MoreActivityTabs';
import { PendingList } from './PendingList';
import { RecentExpenses } from './RecentExpenses';
import { RecentWork } from './RecentWork';
import type { Period } from './schema';

/** Admin home: one request, one question: "What needs my attention right now?" */
export function DashboardPage() {
  const { t } = useI18n();
  const { data: user } = useSession();
  const { items: navItems } = useNavAccess();
  const [params, setParams] = useSearchParams();
  const period = parsePeriod(params.get('period'));
  const query = useDashboard(period);
  const { data } = query;

  const [refreshing, setRefreshing] = useState(false);
  const [announcement, setAnnouncement] = useState({ id: 0, text: '' });

  const onPeriodChange = (next: Period) => {
    setParams(
      (prev) => {
        const copy = new URLSearchParams(prev);
        copy.set('period', next);
        return copy;
      },
      { replace: true },
    );
  };

  const onRefresh = async () => {
    setRefreshing(true);
    const result = await query.refetch();
    setRefreshing(false);
    setAnnouncement((a) => ({ id: a.id + 1, text: result.isError ? t('err.dashboard') : t('dash.refreshed') }));
  };

  if (!user) return null;

  if (!data) {
    if (query.isPending) return <DashboardSkeleton />;

    if (query.error instanceof ApiError && query.error.status === 403) {
      const firstOpenable = navItems.find((item) => item.path !== '/admin');
      return (
        <div className="space-y-4 rounded-lg border border-border bg-surface px-4 py-8 text-center">
          <p className="text-text">{t('err.noAccess')}</p>
          {firstOpenable && (
            <Link to={firstOpenable.path} className="link-action inline-block text-sm">
              {t('err.noAccessGo', { page: t(firstOpenable.labelKey) })}
            </Link>
          )}
        </div>
      );
    }

    return (
      <ErrorState message={t('err.dashboard')} retrying={query.isFetching} onRetry={() => void query.refetch()} />
    );
  }

  const bothLists = data.recentWork !== null && data.recentExpenses !== null;

  return (
    <div
      className={`space-y-6 transition-opacity ${query.isPlaceholderData ? 'opacity-60' : ''}`}
      aria-busy={query.isPlaceholderData}
    >
      <div role="status" aria-live="polite" className="sr-only">
        <span key={announcement.id}>{announcement.text}</span>
      </div>

      <div>
        <PageHeader
          title={t('dash.welcome', { name: user.name })}
          subtitle={t(`role.${user.role}`)}
          actions={
            <>
              <label htmlFor="dash-period" className="sr-only">
                {t('dash.period')}
              </label>
              <select
                id="dash-period"
                value={period}
                onChange={(e) => onPeriodChange(parsePeriod(e.target.value))}
                className="input !h-11 !w-auto !px-3 !text-sm"
              >
                {PERIODS.map((p) => (
                  <option key={p} value={p}>
                    {t(`period.${p}`)}
                  </option>
                ))}
              </select>
              <Button variant="secondary" loading={refreshing} onClick={() => void onRefresh()}>
                {t('dash.refresh')}
              </Button>
            </>
          }
        />
        <p className="mt-2 text-xs text-text-muted sm:text-right">
          {t('dash.updated', { time: formatTime(data.generatedAt) })}
        </p>
      </div>

      {query.isError && <Alert variant="danger" role="status">{t('dash.stale')}</Alert>}

      <AttentionStrip pending={data.counts.pendingVerification} salaryPendingPaise={data.money.salaryPendingPaise} />
      <KpiGrid counts={data.counts} money={data.money} />
      <FinancialOverview money={data.money} />

      {data.pendingVerification && (
        <PendingList total={data.pendingVerification.total} items={data.pendingVerification.items} />
      )}

      {(data.recentWork || data.recentExpenses) && (
        <div className={`grid gap-6 ${bothLists ? '2xl:grid-cols-2' : ''}`}>
          {data.recentWork && <RecentWork items={data.recentWork} />}
          {data.recentExpenses && <RecentExpenses items={data.recentExpenses} />}
        </div>
      )}

      <MoreActivityTabs data={data} />
    </div>
  );
}
