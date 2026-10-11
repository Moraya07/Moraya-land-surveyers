import { PlaceholderShell } from '../components/PlaceholderShell';
import { useI18n } from '../i18n';

export function AdminPlaceholder() {
  const { t } = useI18n();
  return <PlaceholderShell title={t('admin.title')} />;
}
