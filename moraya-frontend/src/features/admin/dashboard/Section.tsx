import { useId, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { useI18n } from '../../../i18n';
import { useNavAccess } from '../useNavAccess';

interface SectionProps {
  title: string;
  /** Optional total shown next to the title. */
  count?: number;
  /** "View all" target; only shown when the user can open it. */
  viewAllTo?: string;
  children: ReactNode;
}

/** Plain titled block (not a card) so the page stays calm. */
export function Section({ title, count, viewAllTo, children }: SectionProps) {
  const { t } = useI18n();
  const { canOpen } = useNavAccess();
  const headingId = useId();
  return (
    <section aria-labelledby={headingId}>
      <div className="mb-2 flex items-center justify-between gap-3">
        <h2 id={headingId} className="text-base font-semibold">
          {title}
          {count !== undefined && <span className="ml-2 text-sm font-normal text-text-muted">({count})</span>}
        </h2>
        {viewAllTo && canOpen(viewAllTo) && (
          <Link to={viewAllTo} className="link-action shrink-0 text-sm">
            {t('common.viewAll')}
          </Link>
        )}
      </div>
      {children}
    </section>
  );
}
