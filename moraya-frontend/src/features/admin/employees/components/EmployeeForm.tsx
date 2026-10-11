import { useId, type FormEvent, type ReactNode } from 'react';
import { Controller, useWatch, type UseFormReturn } from 'react-hook-form';
import { Link } from 'react-router-dom';
import { Alert } from '../../../../components/ui/Alert';
import { Button } from '../../../../components/ui/Button';
import { Field } from '../../../../components/ui/Field';
import { Select } from '../../../../components/ui/Select';
import { useI18n, type DictKey } from '../../../../i18n';
import {
  FIELD_LABEL,
  FORM_FIELDS,
  dayBefore,
  todayIso,
  type CreateFormValues,
  type EditFormValues,
  type FormFieldName,
  type SharedFormValues,
} from '../formSchemas';
import { AccountStatusBadge, RoleBadge } from '../list/EmployeeBadges';
import type { EmployeeDetail } from '../types';
import { groupAadhaar, transformInput, withTransform } from '../utils/inputTransforms';
import { AadhaarChangeField } from './AadhaarChangeField';
import { PermissionPicker } from './PermissionPicker';

export type EmployeeFormMode = 'create' | 'edit';

export interface EmployeeFormError {
  key: DictKey;
  params?: Record<string, number>;
}

interface BaseProps {
  /** Every input disabled: saving, a dialog is open, or a conflict is waiting for a decision. */
  locked: boolean;
  /** Spinner and "Creating…" / "Saving…" on the submit button. */
  pending: boolean;
  /** Form-level problem that no single field explains. */
  formError: EmployeeFormError | null;
  /** Show the list of invalid fields above the form (the page turns it on when more than three fail). */
  showSummary: boolean;
  onSubmit: (event: FormEvent<HTMLFormElement>) => void;
  onCancel: () => void;
  /** Disables the submit button. Defaults to `locked`. Edit: nothing changed, or a conflict is open. */
  saveDisabled?: boolean | undefined;
  /** Disables Cancel. Defaults to `locked`. Edit keeps Cancel usable while a conflict is open. */
  cancelDisabled?: boolean | undefined;
  /** Short text next to the buttons (edit: "No changes to save."). */
  saveHint?: string | undefined;
  /** Rendered above the form-level alerts (edit: the version-conflict alert). */
  banner?: ReactNode | undefined;
}

interface CreateProps extends BaseProps {
  mode: 'create';
  form: UseFormReturn<CreateFormValues>;
  /** Server capability: show the Role selector (and the permissions for a Sub-Admin). */
  canAssignRole: boolean;
}

interface EditProps extends BaseProps {
  mode: 'edit';
  form: UseFormReturn<EditFormValues>;
  /** The employee the form was loaded from: SR NO, masked Aadhaar, login email, role and status come from it. */
  employee: EmployeeDetail;
  /** Where "open the employee page" goes. */
  backTo: string;
  /** True while the empty "new Aadhaar" input is shown. */
  aadhaarOpen: boolean;
  onAadhaarOpen: () => void;
  onAadhaarCancel: () => void;
}

export type EmployeeFormProps = CreateProps | EditProps;

// ---------------------------------------------------------------- layout pieces

function FormSection({ title, children }: { title: string; children: ReactNode }) {
  const headingId = useId();
  return (
    <section aria-labelledby={headingId} className="rounded-lg border border-border bg-surface p-4 sm:p-5">
      <h2 id={headingId} className="mb-4 text-base font-semibold">
        {title}
      </h2>
      <div className="grid gap-x-6 md:grid-cols-2">{children}</div>
    </section>
  );
}

/** A value that cannot be edited here: plain text in a muted box, with an optional short helper. */
function ReadOnlyField({
  label,
  helper,
  children,
}: {
  label: string;
  helper?: string | undefined;
  children: ReactNode;
}) {
  return (
    <div className="field">
      <p className="field-label">{label}</p>
      <div className="flex min-h-[46px] flex-wrap items-center gap-2 break-all rounded-md border border-border bg-panel px-3.5 py-1.5 text-text-muted">
        {children}
      </div>
      {helper && <p className="mt-1.5 text-sm text-text-muted">{helper}</p>}
    </div>
  );
}

type Message = (name: FormFieldName) => string | undefined;

/** Create mode: login email, role, permissions and the note about the temporary password. */
function CreateAccessFields({
  form,
  canAssignRole,
  message,
}: {
  form: UseFormReturn<CreateFormValues>;
  canAssignRole: boolean;
  message: Message;
}) {
  const { t } = useI18n();
  const { register, control, setValue, clearErrors } = form;
  const role = useWatch({ control, name: 'role' });
  const emailReg = register('loginEmail');

  return (
    <>
      <Field label={t('field.loginEmail')} required error={message('loginEmail')}>
        {(c) => (
          <input
            {...c}
            {...withTransform(emailReg, (el) => transformInput(el, (v) => v.toLowerCase()))}
            type="email"
            inputMode="email"
            autoComplete="off"
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            className="input"
          />
        )}
      </Field>

      {canAssignRole && (
        <Select
          label={t('field.role')}
          required
          error={message('role')}
          {...register('role', {
            onChange: (event: { target: { value: string } }) => {
              // A Surveyor has no permissions, so nothing chosen for a Sub-Admin is carried over.
              if (event.target.value !== 'sub_admin') {
                setValue('permissions', [], { shouldDirty: true });
                clearErrors('permissions');
              }
            },
          })}
        >
          <option value="worker">{t('role.worker')}</option>
          <option value="sub_admin">{t('role.sub_admin')}</option>
        </Select>
      )}

      {canAssignRole && role === 'sub_admin' && (
        <div className="md:col-span-2">
          <Controller
            control={control}
            name="permissions"
            render={({ field }) => (
              <PermissionPicker
                value={field.value}
                onChange={field.onChange}
                onBlur={field.onBlur}
                error={message('permissions')}
                firstInputRef={field.ref}
              />
            )}
          />
        </div>
      )}

      <p className="rounded-md border border-border bg-panel p-3 text-sm text-text-muted md:col-span-2">
        {t('login.note')}
      </p>
    </>
  );
}

/** Edit mode: login email, role and status are shown, not edited. */
function EditAccessFields({ employee, backTo }: { employee: EmployeeDetail; backTo: string }) {
  const { t } = useI18n();
  return (
    <>
      <div className="md:col-span-2">
        <ReadOnlyField label={t('field.loginEmail')} helper={t('edit.loginEmailLocked')}>
          <span dir="ltr">{employee.loginEmail}</span>
        </ReadOnlyField>
      </div>
      <ReadOnlyField label={t('field.role')}>
        <RoleBadge role={employee.role} />
      </ReadOnlyField>
      <ReadOnlyField label={t('field.status')}>
        <AccountStatusBadge status={employee.accountStatus} />
      </ReadOnlyField>
      <p className="-mt-2 mb-2 text-sm text-text-muted md:col-span-2">
        {t('edit.roleStatusNote')}{' '}
        <Link to={backTo} className="link-action inline-flex min-h-11 items-center">
          {t('edit.openEmployee')}
        </Link>
      </p>
    </>
  );
}

// ---------------------------------------------------------------- the form

/**
 * The employee form, used by Create and Edit. It owns the layout and the field wiring; the page owns the form
 * instance, the submit/error handling and the unsaved-changes protection.
 */
export function EmployeeForm(props: EmployeeFormProps) {
  const { t } = useI18n();
  const { locked, pending, formError, showSummary, onSubmit, onCancel, banner, saveHint } = props;
  const saveDisabled = props.saveDisabled ?? locked;
  const cancelDisabled = props.cancelDisabled ?? locked;

  // The employment fields exist in both value types with the same types, so they are wired once against the
  // shared shape. The create-only and edit-only fields below use the form with its real type.
  const form = props.form as unknown as UseFormReturn<SharedFormValues>;
  const { register, getValues, trigger, setFocus } = form;
  const errors = form.formState.errors as unknown as Partial<Record<FormFieldName, { message?: unknown }>>;

  const message: Message = (name) => {
    const text = errors[name]?.message;
    return typeof text === 'string' ? t(text as DictKey) : undefined;
  };
  const focusField = (name: FormFieldName) => (setFocus as (field: string) => void)(name);

  const failing = FORM_FIELDS.filter((name) => errors[name] !== undefined);
  const today = todayIso();

  // Registered here (not inline) because the Employee ID changes the text before the form library reads it.
  const employeeIdReg = register('employeeId');
  const aadhaarReg = register('aadhaar');

  return (
    <form onSubmit={onSubmit} noValidate aria-busy={pending || undefined} className="max-w-4xl">
      <div className="space-y-4">
        {banner}

        {formError && (
          <Alert variant="danger" role="alert">
            {t(formError.key, formError.params)}
          </Alert>
        )}

        {showSummary && failing.length > 0 && (
          <Alert variant="danger" role="alert">
            <p className="font-medium">{t('err.validation')}</p>
            <ul className="mt-1 list-disc ps-5">
              {failing.map((name) => (
                <li key={name}>
                  <button type="button" onClick={() => focusField(name)} className="link-action text-start underline">
                    {t(FIELD_LABEL[name])}
                  </button>
                  {': '}
                  {message(name)}
                </li>
              ))}
            </ul>
          </Alert>
        )}

        {/* One disabled fieldset disables every control while saving. */}
        <fieldset disabled={locked} className="min-w-0 space-y-4 border-0 p-0">
          <FormSection title={t('group.employment')}>
            <ReadOnlyField
              label={t('field.srNo')}
              helper={props.mode === 'edit' ? t('edit.srNoLocked') : undefined}
            >
              {props.mode === 'edit' ? props.employee.srNo : t('field.autoAssigned')}
            </ReadOnlyField>

            <Field label={t('field.name')} required error={message('name')}>
              {(c) => <input {...c} {...register('name')} type="text" autoComplete="off" className="input" />}
            </Field>

            <Field label={t('field.employeeId')} required hint={t('field.employeeIdHint')} error={message('employeeId')}>
              {(c) => (
                <input
                  {...c}
                  {...withTransform(employeeIdReg, (el) => transformInput(el, (v) => v.toUpperCase()))}
                  type="text"
                  autoComplete="off"
                  autoCapitalize="characters"
                  spellCheck={false}
                  className="input"
                />
              )}
            </Field>

            <Field label={t('field.designation')} required error={message('designation')}>
              {(c) => <input {...c} {...register('designation')} type="text" autoComplete="off" className="input" />}
            </Field>

            <Field label={t('field.dob')} required error={message('dateOfBirth')}>
              {(c) => (
                <input
                  {...c}
                  {...register('dateOfBirth', {
                    // The joining date is checked against this one, so re-check it once it has a value.
                    onChange: () => {
                      if (getValues('dateOfJoining')) void trigger('dateOfJoining');
                    },
                  })}
                  type="date"
                  max={dayBefore(today)}
                  autoComplete="off"
                  className="input"
                />
              )}
            </Field>

            <Field label={t('field.doj')} required error={message('dateOfJoining')}>
              {(c) => (
                <input
                  {...c}
                  {...register('dateOfJoining')}
                  type="date"
                  max={today}
                  autoComplete="off"
                  className="input"
                />
              )}
            </Field>
          </FormSection>

          <FormSection title={t('group.identity')}>
            {props.mode === 'edit' ? (
              <AadhaarChangeField
                form={props.form}
                masked={props.employee.aadhaarMasked}
                canChange={props.employee.capabilities.canChangeAadhaar}
                open={props.aadhaarOpen}
                onOpen={props.onAadhaarOpen}
                onCancel={props.onAadhaarCancel}
                error={message('aadhaar')}
              />
            ) : (
              <Field label={t('field.aadhaar')} required hint={t('aadhaar.helper')} error={message('aadhaar')}>
                {(c) => (
                  <input
                    {...c}
                    {...withTransform(aadhaarReg, groupAadhaar)}
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
            )}
          </FormSection>

          <FormSection title={t('group.access')}>
            {props.mode === 'edit' ? (
              <EditAccessFields employee={props.employee} backTo={props.backTo} />
            ) : (
              <CreateAccessFields form={props.form} canAssignRole={props.canAssignRole} message={message} />
            )}
          </FormSection>
        </fieldset>
      </div>

      {/* Sticky action bar: spans the page width, stays at the bottom of the viewport while the form is longer. */}
      <div className="sticky bottom-0 z-10 -mx-4 mt-6 flex flex-wrap items-center justify-end gap-2 border-t border-border bg-background px-4 py-3 sm:-mx-6 sm:px-6">
        {saveHint && <p className="me-auto text-sm text-text-muted">{saveHint}</p>}
        <Button variant="secondary" onClick={onCancel} disabled={cancelDisabled}>
          {t('act.cancel')}
        </Button>
        <Button type="submit" loading={pending} disabled={saveDisabled} className="!h-11">
          {props.mode === 'create' ? (pending ? t('act.creating') : t('act.create')) : pending ? t('act.saving') : t('act.save')}
        </Button>
      </div>
    </form>
  );
}
