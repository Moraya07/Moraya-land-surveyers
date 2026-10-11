import { useId } from 'react';
import { Money } from '../../../components/ui/Money';
import { useI18n, type DictKey } from '../../../i18n';
import type { DashboardResponse } from './schema';

interface Row {
  key: string;
  labelKey: DictKey;
  paise: number;
  color: string;
}

/** Proportional bars drawn with plain divs from the real values. Verified records only. */
export function FinancialOverview({ money }: { money: DashboardResponse['money'] }) {
  const { t } = useI18n();
  const headingId = useId();

  const rows: Row[] = [];
  const add = (key: string, labelKey: DictKey, paise: number | null, color: string) => {
    if (paise !== null) rows.push({ key, labelKey, paise, color });
  };
  add('income', 'kpi.siteIncome', money.siteIncomePaise, '--c-success');
  add('expenses', 'kpi.siteExpenses', money.siteExpensesPaise, '--c-danger');
  add('paid', 'kpi.salaryPaid', money.salaryPaidPaise, '--c-info');
  add('pending', 'kpi.salaryPending', money.salaryPendingPaise, '--c-warning');

  const net = money.siteNetBalancePaise;
  if (rows.length === 0 && net === null) return null;

  const max = Math.max(1, ...rows.map((r) => r.paise));

  return (
    <section aria-labelledby={headingId} className="rounded-lg border border-border bg-surface p-4 sm:p-5">
      <h2 id={headingId} className="text-base font-semibold">
        {t('section.financial')}
      </h2>

      {rows.length > 0 && (
        <ul className="mt-4 space-y-4">
          {rows.map((row) => {
            const pct = row.paise > 0 ? Math.max(1.5, (row.paise / max) * 100) : 0;
            return (
              <li
                key={row.key}
                className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-4 gap-y-1.5 sm:grid-cols-[10rem_minmax(0,1fr)_9rem]"
              >
                <span className="text-sm">{t(row.labelKey)}</span>
                <Money paise={row.paise} className="text-right text-sm font-medium sm:order-3" />
                <div
                  aria-hidden="true"
                  className="col-span-2 h-2.5 overflow-hidden rounded-full bg-panel sm:order-2 sm:col-span-1"
                >
                  <div
                    className="h-full rounded-full"
                    style={{ width: `${pct}%`, backgroundColor: `rgb(var(${row.color}))` }}
                  />
                </div>
              </li>
            );
          })}
        </ul>
      )}

      {net !== null && (
        <p className={`text-sm ${rows.length > 0 ? 'mt-5 border-t border-border pt-3' : 'mt-3'}`}>
          <span className="text-text-muted">{t('kpi.netBalance')}: </span>
          <Money paise={net} className="font-semibold" />
        </p>
      )}
      <p className="mt-2 text-xs text-text-muted">{t('section.basedOnVerified')}</p>
    </section>
  );
}
