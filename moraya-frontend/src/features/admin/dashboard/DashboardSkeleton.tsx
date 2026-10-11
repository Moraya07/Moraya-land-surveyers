import { Skeleton } from '../../../components/ui/Skeleton';
import { useI18n } from '../../../i18n';

/** Mirrors the final layout: header, KPI row, financial block, two lists. */
export function DashboardSkeleton() {
  const { t } = useI18n();
  return (
    <div role="status" aria-busy="true" className="space-y-6">
      <span className="sr-only">{t('common.loading')}</span>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="space-y-2">
          <Skeleton className="h-8 w-64 max-w-full" />
          <Skeleton className="h-4 w-28" />
        </div>
        <div className="flex gap-2">
          <Skeleton className="h-11 w-36" />
          <Skeleton className="h-11 w-24" />
        </div>
      </div>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-6">
        {Array.from({ length: 6 }, (_, i) => (
          <Skeleton key={i} className="h-[84px]" />
        ))}
      </div>
      <Skeleton className="h-48" />
      <div className="space-y-2">
        <Skeleton className="h-5 w-48" />
        <Skeleton className="h-52" />
      </div>
      <div className="grid gap-6 2xl:grid-cols-2">
        <Skeleton className="h-52" />
        <Skeleton className="h-52" />
      </div>
    </div>
  );
}
