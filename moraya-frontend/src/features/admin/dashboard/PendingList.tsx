import { EmptyState } from '../../../components/ui/EmptyState';
import type { Column } from '../../../components/ui/DataTable';
import { Money } from '../../../components/ui/Money';
import { ResponsiveList } from '../../../components/ui/ResponsiveList';
import { useI18n } from '../../../i18n';
import { formatDateTime } from '../../../lib/format';
import { Section } from './Section';
import type { PendingItem } from './schema';

export function PendingList({ total, items }: { total: number; items: PendingItem[] }) {
  const { t } = useI18n();
  const rows = items.slice(0, 5);

  const columns: Column<PendingItem>[] = [
    { key: 'employee', header: t('col.employee'), primary: true, render: (r) => r.employeeName },
    { key: 'type', header: t('col.type'), render: (r) => t(r.kind === 'work' ? 'kind.work' : 'kind.expense') },
    { key: 'site', header: t('col.site'), render: (r) => r.siteName },
    { key: 'submitted', header: t('col.submitted'), render: (r) => formatDateTime(r.submittedAt) },
    {
      key: 'amount',
      header: t('col.amount'),
      align: 'end',
      render: (r) => (r.amountPaise === null ? '—' : <Money paise={r.amountPaise} />),
    },
  ];

  return (
    <Section title={t('section.pendingVerification')} count={total} viewAllTo="/admin/verification">
      {rows.length === 0 ? (
        <EmptyState message={t('empty.pending')} />
      ) : (
        <ResponsiveList
          columns={columns}
          rows={rows}
          getKey={(r) => r.id}
          caption={t('section.pendingVerification')}
        />
      )}
    </Section>
  );
}
