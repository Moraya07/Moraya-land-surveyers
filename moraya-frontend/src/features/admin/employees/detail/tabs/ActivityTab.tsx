import { useEffect, useMemo, useRef, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { EmptyState } from '../../../../../components/ui/EmptyState';
import { ErrorState } from '../../../../../components/ui/ErrorState';
import { Skeleton } from '../../../../../components/ui/Skeleton';
import { Spinner } from '../../../../../components/ui/Spinner';
import { useI18n } from '../../../../../i18n';
import { ApiError } from '../../../../../lib/errors';
import { employeeKeys, useEmployeeActivity } from '../../hooks';
import type { ActivityItem } from '../../types';
import { ActivityItemRow } from './ActivityItemRow';

const PAGE_ONE = 1;

function ListSkeleton() {
  const { t } = useI18n();
  return (
    <div role="status" aria-busy="true" className="space-y-5">
      <span className="sr-only">{t('common.loading')}</span>
      {[0, 1, 2, 3, 4].map((n) => (
        <div key={n} className="flex gap-3">
          <Skeleton className="h-8 w-8 shrink-0 !rounded-full" />
          <div className="min-w-0 flex-1 space-y-2">
            <Skeleton className="h-4 w-1/2 max-w-xs" />
            <Skeleton className="h-3 w-3/4 max-w-sm" />
          </div>
        </div>
      ))}
    </div>
  );
}

/** A message in place of the list (no access / not found). The detail query is refreshed separately. */
function Notice({ text }: { text: string }) {
  return (
    <div role="alert" className="rounded-lg border border-border bg-surface px-4 py-8 text-center">
      <p className="text-text">{text}</p>
    </div>
  );
}

const MORE_BUTTON =
  'inline-flex min-h-11 items-center justify-center gap-2 rounded-md border border-field bg-surface px-4 text-base font-medium text-text transition-colors hover:bg-panel aria-disabled:cursor-not-allowed aria-disabled:opacity-60';

/**
 * Employee history, newest first, 25 per page, "Load more" appends the next page.
 *
 * - Mounted only while the Activity tab is open, so nothing is fetched when the detail page loads.
 * - Page 1 is always observed; the newest page is observed on top of it. Pages in between are kept in local
 *   state, so earlier pages are never fetched again by "Load more".
 * - After a change made from this page (deactivate, role change…) the page-1 query is refetched by the existing
 *   invalidation; the list then starts again from the top, so the new entry is never missing.
 */
export function ActivityTab({ employeeId }: { employeeId: string }) {
  const { t } = useI18n();
  const qc = useQueryClient();

  const [pageCount, setPageCount] = useState(PAGE_ONE);
  /** Items of pages 2..pageCount-1. The newest page is read live from its query. */
  const [committed, setCommitted] = useState<Record<number, ActivityItem[]>>({});

  const first = useEmployeeActivity(employeeId, PAGE_ONE);
  const last = useEmployeeActivity(employeeId, pageCount); // same query as `first` while pageCount is 1

  // The hook keeps the previous page as placeholder data; here that would look like the new page, so ignore it.
  const lastData = pageCount > PAGE_ONE && !last.isPlaceholderData ? last.data : undefined;
  const newestPage = pageCount === PAGE_ONE ? first.data : lastData;

  // ---- 403 / 404: tell the detail page, which owns the tab list and the not-found state.
  const failure = first.error ?? (pageCount > PAGE_ONE ? last.error : null);
  const failureStatus = failure instanceof ApiError ? failure.status : null;
  useEffect(() => {
    if (failureStatus === 403 || failureStatus === 404) {
      // 403: the refetched detail drops `canViewActivity`, so the tab disappears. 404: the detail page shows "not found".
      void qc.invalidateQueries({ queryKey: employeeKeys.detail(employeeId), exact: true });
    }
  }, [failureStatus, employeeId, qc]);

  // ---- Page 1 was refreshed while pages 2+ are shown (a change was made): start again from the top.
  const firstStamp = first.dataUpdatedAt;
  const seenStamp = useRef(firstStamp);
  useEffect(() => {
    if (seenStamp.current === firstStamp) return;
    seenStamp.current = firstStamp;
    if (pageCount > PAGE_ONE) {
      setPageCount(PAGE_ONE);
      setCommitted({});
      // Drop the cached later pages: they are out of date now.
      qc.removeQueries({ queryKey: employeeKeys.activities(employeeId), predicate: (q) => q.queryKey[4] !== PAGE_ONE });
    }
  }, [firstStamp, pageCount, employeeId, qc]);

  const items = useMemo(() => {
    const seen = new Set<string>();
    const out: ActivityItem[] = [];
    const push = (list: readonly ActivityItem[] | undefined) => {
      for (const item of list ?? []) {
        if (seen.has(item.id)) continue; // a new entry can shift one item across a page boundary
        seen.add(item.id);
        out.push(item);
      }
    };
    push(first.data?.items);
    for (let page = 2; page < pageCount; page += 1) push(committed[page]);
    push(lastData?.items);
    return out;
  }, [first.data, committed, lastData, pageCount]);

  // One "now" per data refresh, so the relative hints in a list agree with each other.
  const dataStamp = first.dataUpdatedAt + last.dataUpdatedAt;
  const now = useMemo(() => Date.now(), [dataStamp]);

  // ---- Blocking states
  if (failureStatus === 403) return <Notice text={t('err.noAccess')} />;
  if (failureStatus === 404) return <Notice text={t('detail.notFound')} />;
  if (!first.data) {
    if (first.isError) {
      return <ErrorState message={t('err.load')} onRetry={() => void first.refetch()} retrying={first.isFetching} />;
    }
    return <ListSkeleton />;
  }
  if (first.data.total === 0 && items.length === 0) {
    return <EmptyState message={t('activity.empty')} />;
  }

  // ---- Load more
  const total = (newestPage ?? first.data).total;
  const loadingMore = pageCount > PAGE_ONE && !lastData && !last.isError;
  const moreFailed = pageCount > PAGE_ONE && !lastData && last.isError;
  // While the next page is loading the button stays (busy); it goes only when everything is shown.
  const hasMore = loadingMore || (items.length < total && (newestPage?.items.length ?? 0) > 0);

  const loadMore = () => {
    if (!newestPage || loadingMore) return;
    if (pageCount > PAGE_ONE && lastData) {
      const done = lastData.items;
      setCommitted((prev) => ({ ...prev, [pageCount]: done }));
    }
    setPageCount((n) => n + 1);
  };

  return (
    <div className="min-w-0">
      {first.isError && <p className="mb-3 text-sm text-text-muted">{t('list.refreshFailed')}</p>}

      <ol aria-label={t('tab.activity')} className="min-w-0">
        {items.map((item) => (
          <ActivityItemRow key={item.id} item={item} now={now} />
        ))}
      </ol>

      <div className="mt-5 flex flex-wrap items-center gap-x-4 gap-y-3 border-t border-border pt-4">
        {/* Always present, so a change of the count is announced politely. Focus is never moved. */}
        <p aria-live="polite" aria-atomic="true" className="text-sm text-text-muted">
          {t('activity.showing', { n: items.length, total })}
        </p>

        {moreFailed && (
          <>
            <p role="alert" className="text-sm text-danger">
              {t('err.load')}
            </p>
            <button type="button" className={MORE_BUTTON} onClick={() => void last.refetch()}>
              {t('common.retry')}
            </button>
          </>
        )}

        {!moreFailed && hasMore && (
          <button
            type="button"
            className={MORE_BUTTON}
            // aria-disabled (not disabled) while loading: the button keeps keyboard focus.
            aria-disabled={loadingMore || undefined}
            aria-busy={loadingMore || undefined}
            onClick={loadMore}
          >
            {loadingMore && <Spinner />}
            {t('activity.loadMore')}
          </button>
        )}
      </div>
    </div>
  );
}
