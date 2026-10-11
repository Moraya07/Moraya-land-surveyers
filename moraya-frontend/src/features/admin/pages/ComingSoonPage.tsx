import { EmptyState } from '../../../components/ui/EmptyState';
import { PageHeader } from '../../../components/ui/PageHeader';
import { useI18n, type DictKey } from '../../../i18n';

/** Placeholder for every nav destination that is built in a later phase. */
export function ComingSoonPage({ titleKey }: { titleKey: DictKey }) {
  const { t } = useI18n();
  return (
    <div className="space-y-6">
      <PageHeader title={t(titleKey)} />
      <EmptyState message={t('common.comingSoon')} />
    </div>
  );
}
