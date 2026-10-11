import { Money } from '../../../components/ui/Money';
import { StatCard } from '../../../components/ui/StatCard';
import { useI18n, type DictKey } from '../../../i18n';
import { formatNumber } from '../../../lib/format';
import { useNavAccess } from '../useNavAccess';
import type { DashboardResponse } from './schema';

interface Entry {
  key: string;
  labelKey: DictKey;
  to: string;
  kind: 'count' | 'money';
  value: number;
}

// Literal class names so Tailwind can see them. Columns are chosen from the card count so the grid never has gaps.
const SM_COLS: Record<number, string> = {
  1: 'sm:grid-cols-1',
  2: 'sm:grid-cols-2',
  3: 'sm:grid-cols-3',
  4: 'sm:grid-cols-2',
  5: 'sm:grid-cols-3',
  6: 'sm:grid-cols-3',
};
const XL_COLS: Record<number, string> = {
  1: 'xl:grid-cols-1',
  2: 'xl:grid-cols-2',
  3: 'xl:grid-cols-3',
  4: 'xl:grid-cols-4',
  5: 'xl:grid-cols-5',
  6: 'xl:grid-cols-6',
};

export function KpiGrid({ counts, money }: Pick<DashboardResponse, 'counts' | 'money'>) {
  const { t } = useI18n();
  const { canOpen } = useNavAccess();

  const entries: Entry[] = [];
  const add = (key: string, labelKey: DictKey, to: string, kind: Entry['kind'], value: number | null) => {
    if (value !== null) entries.push({ key, labelKey, to, kind, value });
  };
  add('employees', 'kpi.activeEmployees', '/admin/employees', 'count', counts.activeEmployees);
  add('sites', 'kpi.activeSites', '/admin/sites', 'count', counts.activeSites);
  add('pending', 'kpi.pendingVerification', '/admin/verification', 'count', counts.pendingVerification);
  add('income', 'kpi.siteIncome', '/admin/income', 'money', money.siteIncomePaise);
  add('expenses', 'kpi.siteExpenses', '/admin/expenses', 'money', money.siteExpensesPaise);
  add('salary', 'kpi.salaryPending', '/admin/salary', 'money', money.salaryPendingPaise);

  const n = entries.length;
  if (n === 0) return null;
  const odd = n % 2 === 1 && n > 1;

  return (
    <div
      className={`grid gap-3 ${n === 1 ? 'grid-cols-1' : 'grid-cols-2'} ${SM_COLS[n] ?? ''} ${XL_COLS[n] ?? ''}`}
    >
      {entries.map((entry, i) => (
        <div key={entry.key} className={odd && i === n - 1 ? 'col-span-2 sm:col-span-1' : ''}>
          <StatCard
            label={t(entry.labelKey)}
            to={canOpen(entry.to) ? entry.to : undefined}
            alignEnd={entry.kind === 'money'}
          >
            {entry.kind === 'money' ? <Money paise={entry.value} /> : formatNumber(entry.value)}
          </StatCard>
        </div>
      ))}
    </div>
  );
}
