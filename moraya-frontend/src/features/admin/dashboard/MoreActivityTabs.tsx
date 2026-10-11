import { useId } from 'react';
import type { Column } from '../../../components/ui/DataTable';
import { EmptyState } from '../../../components/ui/EmptyState';
import { Money } from '../../../components/ui/Money';
import { ResponsiveList } from '../../../components/ui/ResponsiveList';
import { StatusBadge } from '../../../components/ui/StatusBadge';
import { Tabs, type TabDef } from '../../../components/ui/Tabs';
import { useI18n } from '../../../i18n';
import { formatDate, formatDateTime, formatNumber } from '../../../lib/format';
import type { ActivityItem, DashboardResponse, IncomeItem, SalaryItem, SiteItem } from './schema';

type Data = Pick<DashboardResponse, 'recentIncome' | 'pendingSalaries' | 'activeSites' | 'employeeActivity'>;

/** One tabbed panel for the secondary lists. Tabs the server returned as null do not exist. */
export function MoreActivityTabs({ data }: { data: Data }) {
  const { t } = useI18n();
  const headingId = useId();

  const tabs: TabDef[] = [];

  if (data.recentIncome) {
    const columns: Column<IncomeItem>[] = [
      { key: 'site', header: t('col.site'), primary: true, render: (r) => r.siteName },
      { key: 'date', header: t('col.date'), render: (r) => formatDate(r.date) },
      { key: 'ref', header: t('col.reference'), render: (r) => r.reference ?? '—' },
      { key: 'amount', header: t('col.amount'), align: 'end', render: (r) => <Money paise={r.amountPaise} /> },
      { key: 'status', header: t('col.status'), render: (r) => <StatusBadge status={r.status} /> },
    ];
    tabs.push({
      id: 'income',
      label: t('section.recentIncome'),
      content:
        data.recentIncome.length === 0 ? (
          <EmptyState message={t('empty.income')} />
        ) : (
          <ResponsiveList
            columns={columns}
            rows={data.recentIncome.slice(0, 5)}
            getKey={(r) => r.id}
            caption={t('section.recentIncome')}
          />
        ),
    });
  }

  if (data.pendingSalaries) {
    const columns: Column<SalaryItem>[] = [
      { key: 'employee', header: t('col.employee'), primary: true, render: (r) => r.employeeName },
      { key: 'period', header: t('col.period'), render: (r) => r.periodLabel },
      { key: 'amount', header: t('col.amount'), align: 'end', render: (r) => <Money paise={r.amountPaise} /> },
      { key: 'status', header: t('col.status'), render: (r) => <StatusBadge status={r.paymentStatus} /> },
    ];
    tabs.push({
      id: 'salaries',
      label: t('section.pendingSalaries'),
      content:
        data.pendingSalaries.length === 0 ? (
          <EmptyState message={t('empty.salaries')} />
        ) : (
          <ResponsiveList
            columns={columns}
            rows={data.pendingSalaries.slice(0, 5)}
            getKey={(r) => r.id}
            caption={t('section.pendingSalaries')}
          />
        ),
    });
  }

  if (data.activeSites) {
    const columns: Column<SiteItem>[] = [
      { key: 'site', header: t('col.site'), primary: true, render: (r) => r.name },
      { key: 'client', header: t('col.client'), render: (r) => r.clientName ?? '—' },
      { key: 'works', header: t('col.works'), align: 'end', render: (r) => formatNumber(r.workCount) },
    ];
    tabs.push({
      id: 'sites',
      label: t('section.activeSites'),
      content:
        data.activeSites.length === 0 ? (
          <EmptyState message={t('empty.sites')} />
        ) : (
          <ResponsiveList
            columns={columns}
            rows={data.activeSites.slice(0, 5)}
            getKey={(r) => r.id}
            caption={t('section.activeSites')}
          />
        ),
    });
  }

  if (data.employeeActivity) {
    const columns: Column<ActivityItem>[] = [
      { key: 'employee', header: t('col.employee'), primary: true, render: (r) => r.employeeName },
      {
        key: 'last',
        header: t('col.lastWork'),
        render: (r) => (r.lastWorkAt ? formatDateTime(r.lastWorkAt) : t('activity.never')),
      },
      { key: 'works', header: t('col.works'), align: 'end', render: (r) => formatNumber(r.workCountInPeriod) },
    ];
    tabs.push({
      id: 'activity',
      label: t('section.employeeActivity'),
      content:
        data.employeeActivity.length === 0 ? (
          <EmptyState message={t('empty.activity')} />
        ) : (
          <ResponsiveList
            columns={columns}
            rows={data.employeeActivity.slice(0, 5)}
            getKey={(r) => r.employeeId}
            caption={t('section.employeeActivity')}
          />
        ),
    });
  }

  if (tabs.length === 0) return null;

  return (
    <section aria-labelledby={headingId}>
      <h2 id={headingId} className="mb-2 text-base font-semibold">
        {t('section.more')}
      </h2>
      <Tabs label={t('section.more')} tabs={tabs} />
    </section>
  );
}
