import type { Column } from '../../../components/ui/DataTable';
import { EmptyState } from '../../../components/ui/EmptyState';
import { ResponsiveList } from '../../../components/ui/ResponsiveList';
import { StatusBadge } from '../../../components/ui/StatusBadge';
import { useI18n } from '../../../i18n';
import { formatDate } from '../../../lib/format';
import { Section } from './Section';
import type { WorkItem } from './schema';

export function RecentWork({ items }: { items: WorkItem[] }) {
  const { t } = useI18n();
  const rows = items.slice(0, 5);

  const columns: Column<WorkItem>[] = [
    {
      key: 'employee',
      header: t('col.employee'),
      primary: true,
      render: (r) => (
        <>
          {r.employeeName}
          {r.assistantName && (
            <span className="block text-xs font-normal text-text-muted">
              {t('dash.assistant', { name: r.assistantName })}
            </span>
          )}
        </>
      ),
    },
    { key: 'site', header: t('col.site'), render: (r) => r.siteName },
    { key: 'date', header: t('col.date'), render: (r) => formatDate(r.workedAt) },
    { key: 'status', header: t('col.status'), render: (r) => <StatusBadge status={r.status} /> },
  ];

  return (
    <Section title={t('section.recentWork')} viewAllTo="/admin/work">
      {rows.length === 0 ? (
        <EmptyState message={t('empty.work')} />
      ) : (
        <ResponsiveList columns={columns} rows={rows} getKey={(r) => r.id} caption={t('section.recentWork')} />
      )}
    </Section>
  );
}
