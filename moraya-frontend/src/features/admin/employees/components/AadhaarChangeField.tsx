import { useEffect, useRef } from 'react';
import type { UseFormReturn } from 'react-hook-form';
import { Button } from '../../../../components/ui/Button';
import { Field } from '../../../../components/ui/Field';
import { useI18n } from '../../../../i18n';
import type { EditFormValues } from '../formSchemas';
import { groupAadhaar, withTransform } from '../utils/inputTransforms';

interface AadhaarChangeFieldProps {
  form: UseFormReturn<EditFormValues>;
  /** 'XXXX XXXX 1234', or '' when none is on file. The full number is never available here. */
  masked: string;
  /** Server capability (`canChangeAadhaar`). Without it the masked value is shown with no Change button. */
  canChange: boolean;
  /** True while the empty input is shown. */
  open: boolean;
  onOpen: () => void;
  /** Discards whatever was typed and closes the input. */
  onCancel: () => void;
  /** Already translated. */
  error: string | undefined;
}

/**
 * The sensitive field of the Edit page. It shows the masked number (or "Not provided"); "Change" reveals an
 * EMPTY input, never the old number. What is typed lives only in the form state: no storage, cache, URL,
 * title, log or toast ever sees it.
 */
export function AadhaarChangeField({ form, masked, canChange, open, onOpen, onCancel, error }: AadhaarChangeFieldProps) {
  const { t } = useI18n();
  const rootRef = useRef<HTMLDivElement>(null);
  const wasOpen = useRef(open);
  const reg = form.register('aadhaar');

  // Move focus with the UI: into the new input when it appears, back to "Change" when it goes away.
  useEffect(() => {
    if (wasOpen.current === open) return;
    wasOpen.current = open;
    if (open) form.setFocus('aadhaar');
    else rootRef.current?.querySelector<HTMLElement>('[data-aadhaar-change]')?.focus();
  }, [open, form]);

  const label = t('field.aadhaar');

  return (
    <div ref={rootRef} className="md:col-span-2">
      <div className="field">
        <p className="field-label">{label}</p>
        <div className="flex flex-wrap items-center gap-3">
          <p className="flex min-h-[46px] min-w-0 items-center rounded-md border border-border bg-panel px-3.5">
            {masked === '' ? (
              <span className="text-text-muted">{t('aadhaar.notProvided')}</span>
            ) : (
              <span dir="ltr" className="tabular-nums tracking-wider">
                {masked}
              </span>
            )}
          </p>
          {canChange && !open && (
            <Button variant="secondary" data-aadhaar-change="" aria-label={`${t('act.changeAadhaar')}: ${label}`} onClick={onOpen}>
              {t('act.changeAadhaar')}
            </Button>
          )}
        </div>
      </div>

      {canChange && open && (
        <div className="max-w-md">
          <Field label={t('edit.newAadhaar')} required hint={t('aadhaar.helper')} error={error}>
            {(c) => (
              <input
                {...c}
                {...withTransform(reg, groupAadhaar)}
                type="text"
                inputMode="numeric"
                autoComplete="off"
                autoCorrect="off"
                autoCapitalize="off"
                spellCheck={false}
                placeholder="XXXX XXXX XXXX"
                data-lpignore="true"
                data-1p-ignore="true"
                className="input tabular-nums tracking-wider"
              />
            )}
          </Field>
          <button type="button" onClick={onCancel} className="link-action -mt-2 mb-4 inline-flex min-h-11 items-center text-sm">
            {t('act.cancelChange')}
          </button>
        </div>
      )}
    </div>
  );
}
