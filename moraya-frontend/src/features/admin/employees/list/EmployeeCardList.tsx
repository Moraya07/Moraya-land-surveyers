import { Link } from 'react-router-dom';
import { Skeleton } from '../../../../components/ui/Skeleton';
import { useI18n } from '../../../../i18n';
import { formatDateOrDash } from '../../../../lib/format';
import type { EmployeeListItem } from '../types';
import { AccountStatusBadge, RoleBadge } from './EmployeeBadges';
import { EmployeeRowMenu } from './EmployeeRowMenu';
import { useListLinkState } from './listReturn';

/**
 * Tablet and phone layout. The whole card is one link (the name carries a stretched hit area), so there is
 * no link inside a link; the row menu sits above it. No horizontal scroll down to 320px.
 */
export function EmployeeCardList({ rows, busy = false }: { rows: readonly EmployeeListItem[]; busy?: boolean }) {
  const { t } = useI18n();
  const linkState = useListLinkState(); // lets the detail page's Back link restore this list view
  return (
    <ul aria-label={t('emp.title')} aria-busy={busy || undefined} className={`space-y-3 transition-opacity ${busy ? 'opacity-60' : ''}`}>
      {rows.map((e) => (
        <li key={e.id} className="relative rounded-md border border-border bg-surface p-3 focus-within:bg-panel hover:bg-panel">
          <div className="flex items-start gap-2">
            <div className="min-w-0 flex-1">
              <Link
                to={`/admin/employees/${encodeURIComponent(e.id)}`}
                state={linkState}
                className="block break-words font-medium text-text after:absolute after:inset-0"
              >
                {e.name}
              </Link>
              <p dir="ltr" className="mt-0.5 text-sm tabular-nums text-text-muted">
                {e.employeeId}
              </p>
              {e.designation && <p className="break-words text-sm text-text-muted">{e.designation}</p>}
            </div>
            <div className="relative z-10 -me-1 -mt-1 shrink-0">
              <EmployeeRowMenu employee={e} />
            </div>
          </div>
          <div className="mt-2 flex flex-wrap items-center gap-2">
            <RoleBadge role={e.role} />
            <AccountStatusBadge status={e.accountStatus} />
          </div>
          <p className="mt-2 text-sm text-text-muted">
            {t('col.joined')}: <span className="tabular-nums text-text">{formatDateOrDash(e.dateOfJoining)}</span>
          </p>
        </li>
      ))}
    </ul>
  );
}

export function EmployeeCardListSkeleton({ rows = 5 }: { rows?: number }) {
  return (
    <ul className="space-y-3" aria-hidden="true">
      {Array.from({ length: rows }, (_, i) => (
        <li key={i} className="rounded-md border border-border bg-surface p-3">
          <div className="flex items-start justify-between gap-2">
            <div className="min-w-0 flex-1">
              <Skeleton className="h-5 w-40" />
              <Skeleton className="mt-2 h-4 w-24" />
              <Skeleton className="mt-1.5 h-4 w-32" />
            </div>
            <Skeleton className="h-11 w-11" />
          </div>
          <div className="mt-2 flex gap-2">
            <Skeleton className="h-6 w-24 rounded-full" />
            <Skeleton className="h-6 w-20 rounded-full" />
          </div>
          <Skeleton className="mt-3 h-4 w-36" />
        </li>
      ))}
    </ul>
  );
}
