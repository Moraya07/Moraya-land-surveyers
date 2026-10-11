import type { MouseEvent } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { ChevronDownIcon } from '../../../../components/icons';
import { Skeleton } from '../../../../components/ui/Skeleton';
import { useI18n, type DictKey } from '../../../../i18n';
import { formatDateOrDash } from '../../../../lib/format';
import type { EmployeeListItem } from '../types';
import { AccountStatusBadge, RoleBadge } from './EmployeeBadges';
import { EmployeeRowMenu } from './EmployeeRowMenu';
import { useListLinkState } from './listReturn';
import { ChevronUpIcon, ChevronsUpDownIcon } from './listIcons';
import type { SortField, SortState } from './useEmployeeListParams';

interface Column {
  key: string;
  labelKey: DictKey;
  sort?: SortField;
}

const COLUMNS: readonly Column[] = [
  { key: 'srNo', labelKey: 'col.srNo', sort: 'srNo' },
  { key: 'employee', labelKey: 'col.employee', sort: 'name' },
  { key: 'employeeId', labelKey: 'col.employeeId', sort: 'employeeId' },
  { key: 'designation', labelKey: 'col.designation' },
  { key: 'role', labelKey: 'col.role' },
  { key: 'status', labelKey: 'col.status' },
  { key: 'joined', labelKey: 'col.joined', sort: 'dateOfJoining' },
];

const TH =
  'sticky top-14 z-10 border-b border-border bg-panel px-3 py-2 text-start align-middle text-xs font-medium text-text-muted first:rounded-tl-md last:rounded-tr-md';
const TD = 'border-t border-border px-3 py-2.5 align-middle';
/** First body row sits directly under the header's own bottom border. */
const TBODY = '[&>tr:first-child>td]:border-t-0';

/** Anything inside the row that handles its own clicks keeps them. */
const OWN_CLICKS = 'a,button,input,select,textarea,label,[role="menu"],[role="dialog"],[role="alertdialog"]';

interface EmployeeTableProps {
  rows: readonly EmployeeListItem[];
  sort: SortState;
  onSort: (field: SortField) => void;
  /** The next page is loading: keep the rows, show them as busy. */
  busy?: boolean;
}

/**
 * Desktop table. No scroll container around it on purpose: the header sticks under the top bar and the
 * row menu can open past the last row.
 */
export function EmployeeTable({ rows, sort, onSort, busy = false }: EmployeeTableProps) {
  const { t } = useI18n();
  const navigate = useNavigate();
  const linkState = useListLinkState(); // lets the detail page's Back link restore this list view

  const openRow = (e: MouseEvent<HTMLTableRowElement>, id: string) => {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    if (e.target instanceof Element && e.target.closest(OWN_CLICKS)) return;
    if (window.getSelection()?.toString()) return; // the user is selecting text
    navigate(`/admin/employees/${encodeURIComponent(id)}`, { state: linkState });
  };

  return (
    <div className={`rounded-md border border-border transition-opacity ${busy ? 'opacity-60' : ''}`}>
      <table className="w-full border-separate border-spacing-0 text-sm" aria-busy={busy || undefined}>
        <caption className="sr-only">{t('emp.title')}</caption>
        <thead>
          <tr>
            {COLUMNS.map((c) => {
              const sorted = c.sort !== undefined && sort.field === c.sort;
              return (
                <th
                  key={c.key}
                  scope="col"
                  className={TH}
                  aria-sort={c.sort ? (sorted ? (sort.dir === 'asc' ? 'ascending' : 'descending') : 'none') : undefined}
                >
                  {c.sort ? (
                    <button
                      type="button"
                      onClick={() => c.sort && onSort(c.sort)}
                      className={`-mx-1 inline-flex min-h-9 items-center gap-1 rounded px-1 text-start hover:text-text ${sorted ? 'text-text' : ''}`}
                    >
                      {t(c.labelKey)}
                      {sorted ? (
                        sort.dir === 'asc' ? (
                          <ChevronUpIcon width={14} height={14} />
                        ) : (
                          <ChevronDownIcon width={14} height={14} />
                        )
                      ) : (
                        <ChevronsUpDownIcon width={14} height={14} className="opacity-50" />
                      )}
                    </button>
                  ) : (
                    t(c.labelKey)
                  )}
                </th>
              );
            })}
            <th scope="col" className={TH}>
              <span className="sr-only">{t('col.actions')}</span>
            </th>
          </tr>
        </thead>
        <tbody className={TBODY}>
          {rows.map((e) => (
            <tr key={e.id} onClick={(ev) => openRow(ev, e.id)} className="cursor-pointer hover:bg-panel focus-within:bg-panel">
              <td className={`${TD} tabular-nums text-text-muted`}>{e.srNo}</td>
              <td className={`${TD} min-w-0`}>
                <Link
                  to={`/admin/employees/${encodeURIComponent(e.id)}`}
                  state={linkState}
                  className="break-words font-medium text-text hover:underline"
                >
                  {e.name}
                </Link>
                <div dir="ltr" className="break-all text-xs text-text-muted">
                  {e.loginEmail}
                </div>
              </td>
              <td className={`${TD} whitespace-nowrap tabular-nums`}>
                <span dir="ltr">{e.employeeId}</span>
              </td>
              <td className={`${TD} break-words`}>{e.designation ?? '—'}</td>
              <td className={TD}>
                <RoleBadge role={e.role} />
              </td>
              <td className={TD}>
                <AccountStatusBadge status={e.accountStatus} />
              </td>
              <td className={`${TD} whitespace-nowrap tabular-nums`}>{formatDateOrDash(e.dateOfJoining)}</td>
              <td className={`${TD} w-px`}>
                <EmployeeRowMenu employee={e} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** Same columns and row height as the table, with placeholder blocks. */
export function EmployeeTableSkeleton({ rows = 8 }: { rows?: number }) {
  const { t } = useI18n();
  return (
    <div className="rounded-md border border-border" aria-hidden="true">
      <table className="w-full border-separate border-spacing-0 text-sm">
        <thead>
          <tr>
            {COLUMNS.map((c) => (
              <th key={c.key} scope="col" className={`${TH} !static`}>
                {t(c.labelKey)}
              </th>
            ))}
            <th scope="col" className={`${TH} !static`} />
          </tr>
        </thead>
        <tbody className={TBODY}>
          {Array.from({ length: rows }, (_, i) => (
            <tr key={i}>
              <td className={TD}>
                <Skeleton className="h-4 w-6" />
              </td>
              <td className={TD}>
                <Skeleton className="h-4 w-40" />
                <Skeleton className="mt-1.5 h-3 w-48" />
              </td>
              <td className={TD}>
                <Skeleton className="h-4 w-20" />
              </td>
              <td className={TD}>
                <Skeleton className="h-4 w-28" />
              </td>
              <td className={TD}>
                <Skeleton className="h-6 w-24 rounded-full" />
              </td>
              <td className={TD}>
                <Skeleton className="h-6 w-20 rounded-full" />
              </td>
              <td className={TD}>
                <Skeleton className="h-4 w-20" />
              </td>
              <td className={`${TD} w-px`}>
                <Skeleton className="h-11 w-11" />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
