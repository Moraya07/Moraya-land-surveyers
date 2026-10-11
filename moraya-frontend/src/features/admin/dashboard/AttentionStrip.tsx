import { Link } from 'react-router-dom';
import { AlertIcon, CheckIcon } from '../../../components/icons';
import { Money } from '../../../components/ui/Money';
import { useI18n } from '../../../i18n';
import { useNavAccess } from '../useNavAccess';

interface AttentionStripProps {
  pending: number | null;
  salaryPendingPaise: number | null;
}

/** "What needs my attention?" null means not permitted, so nothing about it is shown. */
export function AttentionStrip({ pending, salaryPendingPaise }: AttentionStripProps) {
  const { t } = useI18n();
  const { canOpen } = useNavAccess();

  if (pending === null && salaryPendingPaise === null) return null;

  const showPending = (pending ?? 0) > 0;
  const showSalary = (salaryPendingPaise ?? 0) > 0;

  if (!showPending && !showSalary) {
    return (
      <p className="flex items-center gap-2 text-sm text-text-muted">
        <CheckIcon width={16} height={16} />
        {t('dash.allClear')}
      </p>
    );
  }

  return (
    <section aria-label={t('dash.attention')} className="attn">
      <div className="flex items-center gap-2 text-sm font-semibold">
        <AlertIcon width={18} height={18} />
        {t('dash.attention')}
      </div>
      <ul className="mt-2 space-y-2">
        {showPending && (
          <li className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2">
            <span>{t('dash.attentionPending', { n: pending ?? 0 })}</span>
            {canOpen('/admin/verification') && (
              <Link to="/admin/verification" className="btn-primary !h-10 !w-auto px-4 text-sm">
                {t('dash.reviewNow')}
              </Link>
            )}
          </li>
        )}
        {showSalary && (
          <li className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2">
            <span>
              {t('kpi.salaryPending')}: <Money paise={salaryPendingPaise ?? 0} className="font-semibold" />
            </span>
            {canOpen('/admin/salary') && (
              <Link to="/admin/salary" className="link-action text-sm">
                {t('dash.viewSalary')}
              </Link>
            )}
          </li>
        )}
      </ul>
    </section>
  );
}
