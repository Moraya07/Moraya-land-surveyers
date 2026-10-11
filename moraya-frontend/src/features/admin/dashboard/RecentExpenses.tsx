import type { Column } from '../../../components/ui/DataTable';
import { EmptyState } from '../../../components/ui/EmptyState';
import { Money } from '../../../components/ui/Money';
import { ResponsiveList } from '../../../components/ui/ResponsiveList';
import { StatusBadge } from '../../../components/ui/StatusBadge';
import { useI18n } from '../../../i18n';
import { formatDate } from '../../../lib/format';
import { Section } from './Section';
import type { ExpenseItem } from './schema';

export function RecentExpenses({ items }: { items: ExpenseItem[] }) {
  const { t } = useI18n();
  const rows = items.slice(0, 5);

  const columns: Column<ExpenseItem>[] = [
    { key: 'employee', header: t('col.employee'), primary: true, render: (r) => r.employeeName },
    { key: 'site', header: t('col.site'), render: (r) => r.siteName },
    { key: 'date', header: t('col.date'), render: (r) => formatDate(r.date) },
    { key: 'category', header: t('col.category'), render: (r) => r.category },
    { key: 'amount', header: t('col.amount'), align: 'end', render: (r) => <Money paise={r.amountPaise} /> },
    { key: 'status', header: t('col.status'), render: (r) => <StatusBadge status={r.status} /> },
  ];

  return (
    <Section title={t('section.recentExpenses')} viewAllTo="/admin/expenses">
      {rows.length === 0 ? (
        <EmptyState message={t('empty.expenses')} />
      ) : (
        <ResponsiveList columns={columns} rows={rows} getKey={(r) => r.id} caption={t('section.recentExpenses')} />
      )}
    </Section>
  );
}
