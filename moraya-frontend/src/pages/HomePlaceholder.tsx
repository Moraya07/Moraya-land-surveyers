import { PlaceholderShell } from '../components/PlaceholderShell';
import { useI18n } from '../i18n';

export function HomePlaceholder() {
  const { t } = useI18n();
  return <PlaceholderShell title={t('home.title')} />;
}
