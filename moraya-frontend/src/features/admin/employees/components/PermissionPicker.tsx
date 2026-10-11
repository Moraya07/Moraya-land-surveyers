import { useId, type Ref } from 'react';
import { AlertIcon } from '../../../../components/icons';
import { useI18n, type DictKey } from '../../../../i18n';
import { PERMISSION_LABEL, PERMISSION_ORDER } from '../labels';
import type { Permission } from '../types';

/** One-line description shown under each permission name. */
export const PERMISSION_DESCRIPTION: Record<Permission, DictKey> = {
  employee_management: 'perm.desc.employee_management',
  site_management: 'perm.desc.site_management',
  verification: 'perm.desc.verification',
  income_management: 'perm.desc.income_management',
  salary_management: 'perm.desc.salary_management',
  report_view: 'perm.desc.report_view',
  export: 'perm.desc.export',
};

interface PermissionPickerProps {
  value: readonly Permission[];
  onChange: (next: Permission[]) => void;
  /** Called when focus leaves the whole group (not between its checkboxes). */
  onBlur?: () => void;
  /** Already-translated error text. */
  error?: string;
  disabled?: boolean;
  /** Goes to the first checkbox, so a form can move focus here when this group is invalid. */
  firstInputRef?: Ref<HTMLInputElement>;
}

/** Controlled checklist of the seven permissions. Nothing is checked by default (that is the caller's value). */
export function PermissionPicker({ value, onChange, onBlur, error, disabled, firstInputRef }: PermissionPickerProps) {
  const { t } = useI18n();
  const baseId = useId();
  const errorId = `${baseId}-error`;
  const selectedCount = PERMISSION_ORDER.filter((p) => value.includes(p)).length;

  const toggle = (permission: Permission, checked: boolean) => {
    // Always emitted in PERMISSION_ORDER so the value is stable regardless of click order.
    onChange(PERMISSION_ORDER.filter((p) => (p === permission ? checked : value.includes(p))));
  };

  return (
    <fieldset
      disabled={disabled}
      aria-describedby={error ? errorId : undefined}
      className="field min-w-0 border-0 p-0"
      onBlur={(e) => {
        if (!e.currentTarget.contains(e.relatedTarget)) onBlur?.();
      }}
    >
      <legend className="field-label">
        {t('field.permissions')}
        <span aria-hidden="true" className="ms-0.5 text-danger">
          *
        </span>
      </legend>

      <ul className="divide-y divide-border overflow-hidden rounded-md border border-border">
        {PERMISSION_ORDER.map((permission, index) => {
          const inputId = `${baseId}-${permission}`;
          const nameId = `${inputId}-name`;
          const descId = `${inputId}-desc`;
          const hintId = `${inputId}-hint`;
          const isExport = permission === 'export';
          return (
            <li key={permission}>
              <label
                htmlFor={inputId}
                className="flex min-h-11 cursor-pointer items-start gap-3 px-3 py-2.5 hover:bg-panel"
              >
                <input
                  ref={index === 0 ? firstInputRef : undefined}
                  id={inputId}
                  type="checkbox"
                  checked={value.includes(permission)}
                  onChange={(e) => toggle(permission, e.target.checked)}
                  aria-labelledby={nameId}
                  aria-describedby={isExport ? `${descId} ${hintId}` : descId}
                  className="mt-0.5 h-5 w-5 shrink-0"
                  style={{ accentColor: 'rgb(var(--c-primary))' }}
                />
                <span className="min-w-0">
                  <span id={nameId} className="block text-sm font-medium">
                    {t(PERMISSION_LABEL[permission])}
                  </span>
                  <span id={descId} className="block text-sm text-text-muted">
                    {t(PERMISSION_DESCRIPTION[permission])}
                  </span>
                  {/* Hint only: "export" without "report_view" is allowed, just not very useful. */}
                  {isExport && (
                    <span id={hintId} className="mt-0.5 block text-sm text-text-muted">
                      {t('perm.exportHint')}
                    </span>
                  )}
                </span>
              </label>
            </li>
          );
        })}
      </ul>

      <p aria-live="polite" className="mt-1.5 text-sm text-text-muted">
        {t('perm.selected', { n: selectedCount })}
      </p>

      {error && (
        <p id={errorId} className="mt-1.5 flex items-start gap-1.5 text-sm text-danger">
          <AlertIcon width={16} height={16} className="mt-[0.2em] shrink-0" />
          <span>{error}</span>
        </p>
      )}
    </fieldset>
  );
}
