import { useRef } from 'react';
import { Alert } from '../../components/ui/Alert';
import { useI18n } from '../../i18n';

/** Visible countdown ticks silently; screen readers get one announcement, not one per second. */
export function RateLimitAlert({ remaining }: { remaining: number }) {
  const { t } = useI18n();
  const initial = useRef(remaining);
  return (
    <>
      <div role="alert" className="sr-only">
        {t('err.rateLimited', { n: initial.current })}
      </div>
      <div aria-hidden="true">
        <Alert variant="danger">{t('err.rateLimited', { n: remaining })}</Alert>
      </div>
    </>
  );
}
