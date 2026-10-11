import { Chip } from '../../../../../components/ui/Chip';
import { useI18n } from '../../../../../i18n';
import { AccountStatusBadge, RoleBadge } from '../../list/EmployeeBadges';
import type { ActivityChange } from '../../types';
import { EMPTY, fieldKey, formatChangeValue, humanizeKey, type FormattedValue } from '../activityText';

function ValueView({ value }: { value: FormattedValue }) {
  const { t } = useI18n();
  switch (value.kind) {
    case 'empty':
      return <span className="text-text-muted">{EMPTY}</span>;
    case 'role':
      return <RoleBadge role={value.role} />;
    case 'status':
      return <AccountStatusBadge status={value.status} />;
    case 'permissions':
      return (
        <ul className="flex min-w-0 flex-wrap gap-1">
          {value.labels.map((p) => (
            <li key={p.key} className="min-w-0">
              <Chip className="max-w-full break-words">{p.labelKey ? t(p.labelKey) : p.text}</Chip>
            </li>
          ))}
        </ul>
      );
    default:
      // Plain text only: React escapes it, and it is never placed in an attribute.
      return (
        <span dir={value.ltr ? 'ltr' : undefined} className="min-w-0 max-w-full break-words [overflow-wrap:anywhere]">
          {value.text}
        </span>
      );
  }
}

/** "What changed": one line per edited field, `Field: from → to`. Callers pass changes that already went through `safeChanges`. */
export function ChangeList({ changes }: { changes: readonly ActivityChange[] }) {
  const { t } = useI18n();
  return (
    <div className="mt-2 min-w-0 rounded-md border border-border bg-panel px-3 py-2">
      <p className="text-xs font-semibold text-text-muted">{t('activity.changes')}</p>
      <ul className="mt-1.5 space-y-2">
        {changes.map((change, index) => {
          const labelKey = fieldKey(change.field);
          const label = labelKey ? t(labelKey) : humanizeKey(change.field);
          return (
            <li
              key={`${change.field}-${index}`}
              className="flex min-w-0 flex-wrap items-center gap-x-1.5 gap-y-1 text-sm text-text"
            >
              <span className="min-w-0 break-words font-medium">{label}:</span>
              <ValueView value={formatChangeValue(change.field, change.from)} />
              <span aria-hidden="true" className="text-text-muted">
                →
              </span>
              <ValueView value={formatChangeValue(change.field, change.to)} />
            </li>
          );
        })}
      </ul>
    </div>
  );
}
