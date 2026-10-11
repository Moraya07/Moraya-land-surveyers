import { EmptyState } from '../../../../components/ui/EmptyState';
import { useI18n, type DictKey } from '../../../../i18n';

/** Work, Expenses and Salary tabs until their modules exist. */
export function ModuleComingSoonTab({ messageKey }: { messageKey: DictKey }) {
  const { t } = useI18n();
  return <EmptyState message={t(messageKey)} />;
}
