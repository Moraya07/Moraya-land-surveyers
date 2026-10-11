import { useI18n } from '../i18n';

export function PageSkeleton() {
  const { t } = useI18n();
  return (
    <div role="status" aria-busy="true" className="flex min-h-dvh items-center justify-center px-6">
      <span className="sr-only">{t('common.loading')}</span>
      <div className="w-full max-w-[400px] space-y-4" aria-hidden="true">
        <div className="h-20 w-20 rounded-md bg-panel motion-safe:animate-pulse" />
        <div className="h-6 w-2/3 rounded bg-panel motion-safe:animate-pulse" />
        <div className="h-11 rounded-md bg-panel motion-safe:animate-pulse" />
        <div className="h-11 rounded-md bg-panel motion-safe:animate-pulse" />
      </div>
    </div>
  );
}
