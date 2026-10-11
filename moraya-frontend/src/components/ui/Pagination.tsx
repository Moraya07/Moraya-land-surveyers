import { useI18n } from '../../i18n';
import { ChevronLeftIcon, ChevronRightIcon } from '../icons';

interface PaginationProps {
  page: number;
  pageSize: number;
  total: number;
  onPageChange: (page: number) => void;
  /** Disables the controls while the next page is loading. */
  busy?: boolean;
}

/** 1, 2 ... current-1, current, current+1 ... last (null = gap). */
function pageWindow(page: number, pages: number): Array<number | null> {
  const wanted = new Set<number>([1, pages, page - 1, page, page + 1]);
  const sorted = [...wanted].filter((n) => n >= 1 && n <= pages).sort((a, b) => a - b);
  const out: Array<number | null> = [];
  sorted.forEach((n, i) => {
    const prev = sorted[i - 1];
    if (prev !== undefined && n - prev > 1) out.push(null);
    out.push(n);
  });
  return out;
}

const BTN =
  'inline-flex min-h-11 min-w-11 items-center justify-center gap-1 rounded-md border px-3 text-sm font-medium transition-colors lg:min-h-9 lg:min-w-9 disabled:cursor-not-allowed disabled:opacity-50';

export function Pagination({ page, pageSize, total, onPageChange, busy = false }: PaginationProps) {
  const { t } = useI18n();
  if (total <= 0) return null;

  const pages = Math.max(1, Math.ceil(total / pageSize));
  const current = Math.min(Math.max(1, page), pages);
  const from = (current - 1) * pageSize + 1;
  const to = Math.min(total, current * pageSize);
  const go = (n: number) => {
    if (!busy && n >= 1 && n <= pages && n !== current) onPageChange(n);
  };

  return (
    <div className="flex flex-col items-center gap-3 sm:flex-row sm:justify-between">
      <p className="text-sm text-text-muted">{t('pager.showing', { from, to, total })}</p>
      <nav aria-label={t('pager.label')} className="flex flex-wrap items-center justify-center gap-1.5">
        <button
          type="button"
          className={`${BTN} border-field bg-surface hover:bg-panel`}
          disabled={busy || current <= 1}
          onClick={() => go(current - 1)}
        >
          <ChevronLeftIcon width={16} height={16} className="rtl:rotate-180" />
          {t('pager.prev')}
        </button>

        {/* Page numbers from the sm breakpoint up; phones get a compact "Page x of y". */}
        <ul className="hidden items-center gap-1.5 sm:flex">
          {pageWindow(current, pages).map((n, i) =>
            n === null ? (
              <li key={`gap-${i}`} aria-hidden="true" className="px-1 text-text-muted">
                …
              </li>
            ) : (
              <li key={n}>
                <button
                  type="button"
                  aria-label={t('pager.page', { n })}
                  aria-current={n === current ? 'page' : undefined}
                  disabled={busy}
                  onClick={() => go(n)}
                  className={`${BTN} tabular-nums ${
                    n === current
                      ? 'border-text bg-panel font-semibold text-text'
                      : 'border-transparent text-text-muted hover:bg-panel hover:text-text'
                  }`}
                >
                  {n}
                </button>
              </li>
            ),
          )}
        </ul>
        <span className="px-2 text-sm text-text-muted tabular-nums sm:hidden">
          {t('pager.pageOf', { page: current, pages })}
        </span>

        <button
          type="button"
          className={`${BTN} border-field bg-surface hover:bg-panel`}
          disabled={busy || current >= pages}
          onClick={() => go(current + 1)}
        >
          {t('pager.next')}
          <ChevronRightIcon width={16} height={16} className="rtl:rotate-180" />
        </button>
      </nav>
    </div>
  );
}
