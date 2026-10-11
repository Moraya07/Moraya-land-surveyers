import { Link } from 'react-router-dom';
import { PageHeader } from '../../../components/ui/PageHeader';
import { useI18n } from '../../../i18n';

export function NotFoundInShell() {
  const { t } = useI18n();
  return (
    <div className="space-y-4">
      <PageHeader title={t('admin.notFound')} subtitle={t('admin.notFoundHint')} />
      <Link to="/admin" className="link-action inline-block text-sm">
        {t('admin.goDashboard')}
      </Link>
    </div>
  );
}
