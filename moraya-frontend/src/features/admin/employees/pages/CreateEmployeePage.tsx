import { zodResolver } from '@hookform/resolvers/zod';
import { useEffect, useRef, useState } from 'react';
import { useForm, type FieldErrors } from 'react-hook-form';
import { Link, Navigate, useBlocker, useNavigate } from 'react-router-dom';
import { ChevronLeftIcon } from '../../../../components/icons';
import { ErrorState } from '../../../../components/ui/ErrorState';
import { PageHeader } from '../../../../components/ui/PageHeader';
import { Skeleton } from '../../../../components/ui/Skeleton';
import { useToast } from '../../../../components/ui/Toast';
import { useI18n, type DictKey } from '../../../../i18n';
import { ApiError } from '../../../../lib/errors';
import { EmployeeForm, type EmployeeFormError } from '../components/EmployeeForm';
import { TemporaryPasswordDialog } from '../components/TemporaryPasswordDialog';
import { UnsavedChangesDialog } from '../components/UnsavedChangesDialog';
import { mapEmployeeError } from '../errors';
import {
  FORM_FIELDS,
  createSchema,
  defaultCreateValues,
  isFormField,
  toCreateInput,
  type CreateFormValues,
  type FormFieldName,
} from '../formSchemas';
import { useCreateEmployee, useEmployees } from '../hooks';

const LIST_PATH = '/admin/employees';
const SUMMARY_THRESHOLD = 3; // the error summary appears when MORE than this many fields fail

/** What the temporary-password dialog needs. Held in component state only and dropped on close. */
interface CreatedEmployee {
  id: string;
  password: string;
}

/**
 * Gate: the form is only shown when the server says this user can create employees.
 * (The capabilities come with the employee list response; a one-row page is enough to read them.)
 */
export function CreateEmployeePage() {
  const { t } = useI18n();
  const capabilities = useEmployees({ page: 1, pageSize: 1 });

  if (capabilities.isPending) {
    return (
      <div role="status" aria-busy="true" className="space-y-4">
        <span className="sr-only">{t('common.loading')}</span>
        <Skeleton className="h-8 w-1/3" />
        <Skeleton className="h-64 w-full max-w-4xl" />
      </div>
    );
  }

  if (capabilities.isError) {
    if (capabilities.error instanceof ApiError && capabilities.error.status === 403) {
      return <Navigate to={LIST_PATH} replace />;
    }
    return (
      <ErrorState
        message={t(mapEmployeeError(capabilities.error, 'load').messageKey)}
        onRetry={() => void capabilities.refetch()}
        retrying={capabilities.isRefetching}
      />
    );
  }

  const { canCreate, canAssignRole } = capabilities.data.capabilities;
  if (!canCreate) return <Navigate to={LIST_PATH} replace />;
  return <CreateEmployeeFlow canAssignRole={canAssignRole} />;
}

function CreateEmployeeFlow({ canAssignRole }: { canAssignRole: boolean }) {
  const { t } = useI18n();
  const navigate = useNavigate();
  const toast = useToast();
  const create = useCreateEmployee();

  const form = useForm<CreateFormValues>({
    resolver: zodResolver(createSchema),
    // Validate a field when it loses focus, then on every change. Focus is moved by hand (see onInvalid).
    mode: 'onTouched',
    reValidateMode: 'onChange',
    shouldFocusError: false,
    defaultValues: defaultCreateValues,
  });
  const {
    handleSubmit,
    reset,
    setError,
    setFocus,
    formState: { isDirty },
  } = form;

  const [formError, setFormError] = useState<EmployeeFormError | null>(null);
  const [showSummary, setShowSummary] = useState(false);
  const [created, setCreated] = useState<CreatedEmployee | null>(null);
  const [focusRequest, setFocusRequest] = useState<FormFieldName | null>(null);
  /** Set right before we navigate on purpose, so the unsaved-changes guard stays out of the way. */
  const bypassGuard = useRef(false);
  /** Closes the gap between a second Enter key press and the next render. */
  const submitting = useRef(false);

  // ---- Unsaved-changes protection (route changes and tab close) ----
  // While the one-time password is on screen, leaving is blocked too: the password would be lost.
  const dirtyAndIdle = isDirty && !create.isPending;
  const shouldGuard = created !== null || dirtyAndIdle;

  const blocker = useBlocker(
    ({ currentLocation, nextLocation }) =>
      !bypassGuard.current && shouldGuard && currentLocation.pathname !== nextLocation.pathname,
  );

  useEffect(() => {
    if (blocker.state === 'blocked' && created !== null) blocker.reset();
  }, [blocker, created]);

  useEffect(() => {
    if (!shouldGuard) return;
    const onBeforeUnload = (event: BeforeUnloadEvent) => {
      if (bypassGuard.current) return;
      event.preventDefault();
      event.returnValue = ''; // required by some browsers; the browser shows its own generic text
    };
    window.addEventListener('beforeunload', onBeforeUnload);
    return () => window.removeEventListener('beforeunload', onBeforeUnload);
  }, [shouldGuard]);

  // Focus a field after a server error, once the inputs are enabled again.
  useEffect(() => {
    if (focusRequest === null || create.isPending) return;
    setFocus(focusRequest);
    setFocusRequest(null);
  }, [focusRequest, create.isPending, setFocus]);

  // ---- Submit ----

  const handleSaveError = (error: unknown) => {
    if (error instanceof ApiError && (error.code === 'FORBIDDEN' || error.status === 403)) {
      toast.error(t('err.forbidden'));
      bypassGuard.current = true;
      navigate(LIST_PATH, { replace: true });
      return;
    }

    const mapped = mapEmployeeError(error, 'save');
    const fieldTargets = Object.entries(mapped.fieldErrors ?? {}).filter(
      (entry): entry is [FormFieldName, DictKey] => isFormField(entry[0]),
    );
    if (fieldTargets.length > 0) {
      for (const [name, key] of fieldTargets) setError(name, { type: 'server', message: key });
      setShowSummary(fieldTargets.length > SUMMARY_THRESHOLD);
      const first = FORM_FIELDS.find((name) => fieldTargets.some(([target]) => target === name));
      if (first) setFocusRequest(first);
      return;
    }
    setFormError({ key: mapped.messageKey, params: mapped.messageParams });
  };

  const onValid = (values: CreateFormValues) => {
    if (submitting.current || create.isPending) return;
    submitting.current = true;
    setFormError(null);
    setShowSummary(false);

    create.mutate(toCreateInput(values, canAssignRole), {
      onSuccess: ({ employee, temporaryPassword }) => {
        submitting.current = false;
        reset(defaultCreateValues); // the Aadhaar number leaves the form state as soon as it has been sent
        create.reset(); // ...and the request and the temporary password leave the mutation state
        setCreated({ id: employee.id, password: temporaryPassword });
        toast.success(t('toast.created'));
      },
      onError: (error) => {
        submitting.current = false;
        create.reset();
        handleSaveError(error);
      },
    });
  };

  const onInvalid = (fieldErrors: FieldErrors<CreateFormValues>) => {
    const failing = FORM_FIELDS.filter((name) => fieldErrors[name] !== undefined);
    setShowSummary(failing.length > SUMMARY_THRESHOLD);
    const first = failing[0];
    if (first) setFocus(first);
  };

  const finish = () => {
    if (!created) return;
    const { id } = created;
    bypassGuard.current = true;
    setCreated(null); // the password is gone from state before the page changes
    navigate(`${LIST_PATH}/${encodeURIComponent(id)}`, { replace: true });
  };

  return (
    <div className="space-y-6">
      <div className="space-y-1">
        <Link to={LIST_PATH} className="link-action -ms-1 inline-flex min-h-11 items-center gap-1 px-1 text-sm">
          <ChevronLeftIcon width={16} height={16} className="rtl:rotate-180" />
          {t('form.back')}
        </Link>
        <PageHeader title={t('form.createTitle')} />
      </div>

      <EmployeeForm
        mode="create"
        form={form}
        canAssignRole={canAssignRole}
        locked={create.isPending || created !== null}
        pending={create.isPending}
        formError={formError}
        showSummary={showSummary}
        onSubmit={(event) => void handleSubmit(onValid, onInvalid)(event)}
        onCancel={() => navigate(LIST_PATH)}
      />

      {created && <TemporaryPasswordDialog password={created.password} onClose={finish} />}

      <UnsavedChangesDialog
        open={blocker.state === 'blocked' && created === null}
        onDiscard={() => {
          if (blocker.state === 'blocked') blocker.proceed();
        }}
        onKeep={() => {
          if (blocker.state === 'blocked') blocker.reset();
        }}
      />
    </div>
  );
}

export default CreateEmployeePage;
