import { zodResolver } from '@hookform/resolvers/zod';
import { useQueryClient } from '@tanstack/react-query';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useForm, useWatch, type FieldErrors } from 'react-hook-form';
import { Link, useBlocker, useNavigate, useParams } from 'react-router-dom';
import { ChevronLeftIcon } from '../../../../components/icons';
import { ErrorState } from '../../../../components/ui/ErrorState';
import { PageHeader } from '../../../../components/ui/PageHeader';
import { Skeleton } from '../../../../components/ui/Skeleton';
import { useToast } from '../../../../components/ui/Toast';
import { useI18n, type DictKey } from '../../../../i18n';
import { ApiError } from '../../../../lib/errors';
import { EmployeeForm, type EmployeeFormError } from '../components/EmployeeForm';
import { UnsavedChangesDialog } from '../components/UnsavedChangesDialog';
import { VersionConflictAlert } from '../components/VersionConflictAlert';
import { mapEmployeeError } from '../errors';
import {
  EDIT_FIELDS,
  editSchema,
  editValuesFrom,
  isEditField,
  type EditFieldName,
  type EditFormValues,
} from '../formSchemas';
import { employeeKeys, useEmployee, useUpdateEmployee } from '../hooks';
import type { EmployeeDetail } from '../types';
import { applyChangedFields, diffEditValues, hasChanges } from '../utils/changedFields';

const LIST_PATH = '/admin/employees';
const SUMMARY_THRESHOLD = 3; // the error summary appears when MORE than this many fields fail

const detailPath = (id: string): string => `${LIST_PATH}/${encodeURIComponent(id)}`;

/** Where a version conflict stands. `fresh` is set once the latest employee has been loaded. */
interface ConflictState {
  fresh: EmployeeDetail | null;
  reloading: boolean;
  reloadFailed: boolean;
}

function PageSkeleton() {
  const { t } = useI18n();
  return (
    <div role="status" aria-busy="true" className="space-y-4">
      <span className="sr-only">{t('common.loading')}</span>
      <Skeleton className="h-8 w-1/3" />
      <Skeleton className="h-64 w-full max-w-4xl" />
    </div>
  );
}

/** The employee does not exist (any more): a message inside the shell with a way back to the list. */
function EmployeeNotFound() {
  const { t } = useI18n();
  return (
    <div role="alert" className="rounded-lg border border-border bg-surface px-4 py-8 text-center">
      <p className="text-text">{t('detail.notFound')}</p>
      <Link to={LIST_PATH} className="link-action mt-3 inline-flex min-h-11 items-center">
        {t('detail.back')}
      </Link>
    </div>
  );
}

/** No permission to edit: one "not allowed" toast, then back to the employee page. */
function RedirectToDetail({ id }: { id: string }) {
  const { t } = useI18n();
  const toast = useToast();
  const navigate = useNavigate();
  const done = useRef(false); // StrictMode runs effects twice in development: toast once
  useEffect(() => {
    if (done.current) return;
    done.current = true;
    toast.error(t('err.forbidden'));
    navigate(detailPath(id), { replace: true });
  }, [id, navigate, t, toast]);
  return null;
}

/**
 * `/admin/employees/:id/edit`. Gate: load the employee and check `capabilities.canEdit`.
 * The page never asks for, receives or shows a full Aadhaar number.
 */
export function EditEmployeePage() {
  const { t } = useI18n();
  const { id = '' } = useParams();
  const query = useEmployee(id);
  const { refetch } = query;
  const employee = query.data;
  const error = query.error;

  // Latest data from the server, or null when the reload failed. Used by the version-conflict flow.
  const reload = useCallback(async (): Promise<EmployeeDetail | null> => {
    const result = await refetch();
    return result.isError || !result.data ? null : result.data;
  }, [refetch]);

  // These win over cached data: a refetch that says "gone" or "not allowed" is the truth.
  if (error instanceof ApiError && error.status === 404) return <EmployeeNotFound />;
  if (error instanceof ApiError && error.status === 403) return <RedirectToDetail id={id} />;

  if (!employee) {
    if (query.isError) {
      return <ErrorState message={t('err.load')} onRetry={() => void refetch()} retrying={query.isFetching} />;
    }
    return <PageSkeleton />;
  }

  if (!employee.capabilities.canEdit) return <RedirectToDetail id={employee.id} />;

  return <EditEmployeeFlow key={employee.id} employee={employee} reload={reload} />;
}

function EditEmployeeFlow({
  employee,
  reload,
}: {
  employee: EmployeeDetail;
  reload: () => Promise<EmployeeDetail | null>;
}) {
  const { t } = useI18n();
  const navigate = useNavigate();
  const toast = useToast();
  const queryClient = useQueryClient();
  const update = useUpdateEmployee(employee.id);

  // The form is built from a snapshot of the employee. Background refetches of the query do not move it:
  // only an explicit Reload (version conflict) replaces the snapshot.
  const [base, setBase] = useState<EmployeeDetail>(employee);
  const initial = useMemo(() => editValuesFrom(base), [base]);

  const form = useForm<EditFormValues>({
    resolver: zodResolver(editSchema),
    // Validate a field when it loses focus, then on every change. Focus is moved by hand (see onInvalid).
    mode: 'onTouched',
    reValidateMode: 'onChange',
    shouldFocusError: false,
    defaultValues: initial,
  });
  const { handleSubmit, reset, setError, setFocus, setValue, clearErrors, getValues, control } = form;

  const watched = useWatch({ control });
  const patch = useMemo(() => diffEditValues(watched, initial), [watched, initial]);
  const changed = hasChanges(patch);
  const aadhaarOpen = watched.changeAadhaar === true;

  const [formError, setFormError] = useState<EmployeeFormError | null>(null);
  const [showSummary, setShowSummary] = useState(false);
  const [conflict, setConflict] = useState<ConflictState | null>(null);
  const [gone, setGone] = useState(false);
  const [focusRequest, setFocusRequest] = useState<EditFieldName | null>(null);
  /** Set right before we navigate on purpose, so the unsaved-changes guard stays out of the way. */
  const bypassGuard = useRef(false);
  /** Closes the gap between a second Enter key press and the next render. */
  const submitting = useRef(false);

  // "Edit {name}" in the document title. The name only: never the Aadhaar or any other identifier.
  const pageTitle = t('form.editTitle', { name: base.name });
  const sectionTitle = t('emp.title');
  useEffect(() => {
    const previous = document.title;
    document.title = `${pageTitle} · ${sectionTitle}`;
    return () => {
      document.title = previous;
    };
  }, [pageTitle, sectionTitle]);

  // ---- Unsaved-changes protection (route changes and tab close): same pattern as the create page ----
  const shouldGuard = changed && !update.isPending;

  const blocker = useBlocker(
    ({ currentLocation, nextLocation }) =>
      !bypassGuard.current && shouldGuard && currentLocation.pathname !== nextLocation.pathname,
  );

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

  // Focus a field after a server error or a conflict decision, once the inputs are enabled again.
  const locked = update.isPending || conflict !== null;
  useEffect(() => {
    if (focusRequest === null || locked) return;
    setFocus(focusRequest);
    setFocusRequest(null);
  }, [focusRequest, locked, setFocus]);

  // ---- Aadhaar change field ----

  const openAadhaar = () => setValue('changeAadhaar', true);

  const cancelAadhaar = () => {
    setValue('aadhaar', ''); // what was typed is discarded, not parked
    setValue('changeAadhaar', false);
    clearErrors('aadhaar');
  };

  // ---- Submit ----

  const leaveTo = (path: string) => {
    bypassGuard.current = true;
    navigate(path, { replace: true });
  };

  const handleSaveError = (error: unknown) => {
    if (error instanceof ApiError && (error.code === 'FORBIDDEN' || error.status === 403)) {
      toast.error(t('err.forbidden'));
      void queryClient.invalidateQueries({ queryKey: employeeKeys.detail(base.id) }); // the detail page must not trust old capabilities
      leaveTo(detailPath(base.id));
      return;
    }
    if (error instanceof ApiError && (error.code === 'NOT_FOUND' || error.status === 404)) {
      setGone(true);
      return;
    }
    if (error instanceof ApiError && error.code === 'VERSION_CONFLICT') {
      setConflict({ fresh: null, reloading: false, reloadFailed: false });
      setShowSummary(false);
      return;
    }

    const mapped = mapEmployeeError(error, 'save');
    const fieldTargets = Object.entries(mapped.fieldErrors ?? {}).filter(
      (entry): entry is [EditFieldName, DictKey] => isEditField(entry[0]),
    );
    if (fieldTargets.length > 0) {
      for (const [name, key] of fieldTargets) setError(name, { type: 'server', message: key });
      setShowSummary(fieldTargets.length > SUMMARY_THRESHOLD);
      const first = EDIT_FIELDS.find((name) => fieldTargets.some(([target]) => target === name));
      if (first) setFocusRequest(first);
      return;
    }
    setFormError({ key: mapped.messageKey, ...(mapped.messageParams ? { params: mapped.messageParams } : {}) });
  };

  const onValid = (values: EditFormValues) => {
    if (submitting.current || update.isPending || conflict !== null) return;
    // Only what changed is sent, plus the version the form was loaded at.
    const changes = diffEditValues(values, initial);
    if (!hasChanges(changes)) return;
    submitting.current = true;
    setFormError(null);
    setShowSummary(false);

    update.mutate(
      { version: base.version, ...changes },
      {
        onSuccess: (updated) => {
          submitting.current = false;
          reset(editValuesFrom(updated)); // a new Aadhaar number leaves the form state as soon as it has been sent
          update.reset(); // ...and the request leaves the mutation state
          toast.success(t('toast.updated'));
          leaveTo(detailPath(updated.id)); // the cache was already updated from the response by the hook
        },
        onError: (error) => {
          submitting.current = false;
          update.reset();
          handleSaveError(error);
        },
      },
    );
  };

  const onInvalid = (fieldErrors: FieldErrors<EditFormValues>) => {
    const failing = EDIT_FIELDS.filter((name) => fieldErrors[name] !== undefined);
    setShowSummary(failing.length > SUMMARY_THRESHOLD);
    const first = failing[0];
    if (first) setFocus(first);
  };

  // ---- Version conflict ----

  const onReload = async () => {
    setConflict((c) => (c ? { ...c, reloading: true, reloadFailed: false } : c));
    const fresh = await reload();
    setConflict((c) =>
      c ? (fresh ? { fresh, reloading: false, reloadFailed: false } : { ...c, reloading: false, reloadFailed: true }) : c,
    );
  };

  const finishConflict = (fresh: EmployeeDetail) => {
    setBase(fresh); // the new version is what the next save sends
    setConflict(null);
    setFormError(null);
    setShowSummary(false);
    setFocusRequest('name');
  };

  /** Re-applies the user's changed fields over the fresh data. A typed Aadhaar stays exactly as it is. */
  const onKeep = () => {
    const fresh = conflict?.fresh;
    if (!fresh) return;
    const current = getValues();
    const mine = diffEditValues(current, initial);
    reset({
      ...applyChangedFields(editValuesFrom(fresh), mine),
      aadhaar: current.aadhaar,
      changeAadhaar: current.changeAadhaar,
    });
    finishConflict(fresh);
  };

  const onDiscard = () => {
    const fresh = conflict?.fresh;
    if (!fresh) return;
    reset(editValuesFrom(fresh));
    finishConflict(fresh);
  };

  if (gone) return <EmployeeNotFound />;

  const back = detailPath(base.id);

  return (
    <div className="space-y-6">
      <div className="space-y-1">
        <Link to={back} className="link-action -ms-1 inline-flex min-h-11 items-center gap-1 px-1 text-sm">
          <ChevronLeftIcon width={16} height={16} className="rtl:rotate-180" />
          {t('edit.back')}
        </Link>
        <PageHeader title={pageTitle} />
      </div>

      <EmployeeForm
        mode="edit"
        form={form}
        employee={base}
        backTo={back}
        aadhaarOpen={aadhaarOpen}
        onAadhaarOpen={openAadhaar}
        onAadhaarCancel={cancelAadhaar}
        locked={locked}
        pending={update.isPending}
        saveDisabled={locked || !changed}
        cancelDisabled={update.isPending}
        saveHint={!changed && !locked ? t('edit.noChanges') : undefined}
        formError={formError}
        showSummary={showSummary}
        banner={
          conflict ? (
            <VersionConflictAlert
              reloaded={conflict.fresh !== null}
              reloading={conflict.reloading}
              reloadFailed={conflict.reloadFailed}
              onReload={() => void onReload()}
              onKeep={onKeep}
              onDiscard={onDiscard}
            />
          ) : undefined
        }
        onSubmit={(event) => void handleSubmit(onValid, onInvalid)(event)}
        onCancel={() => navigate(back)}
      />

      <UnsavedChangesDialog
        open={blocker.state === 'blocked'}
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

export default EditEmployeePage;
