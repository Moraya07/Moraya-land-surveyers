import { useQueryClient } from '@tanstack/react-query';
import { useState, type ReactNode } from 'react';
import { Button } from '../../../../components/ui/Button';
import { useToast } from '../../../../components/ui/Toast';
import { useI18n, type DictKey } from '../../../../i18n';
import { ApiError } from '../../../../lib/errors';
import { mapEmployeeError } from '../errors';
import { employeeKeys } from '../hooks';
import type { AccountStatus, Permission, Role } from '../types';

/** The few fields the action dialogs need. Fits a list row or the detail object. Never includes Aadhaar. */
export interface DialogEmployee {
  id: string;
  employeeId: string;
  name: string;
  role: Role;
  accountStatus: AccountStatus;
  permissions?: Permission[];
  version?: number;
}

export interface ActionDialogProps {
  employee: DialogEmployee;
  /** Closes the dialog. Focus is handed back by the hook that owns the dialogs. */
  onClose: () => void;
}

/** Name + Employee ID, then the consequence in plain language. */
export function EmployeeBody({ employee, text }: { employee: DialogEmployee; text: string }) {
  return (
    <>
      <p className="text-text">
        <span className="font-semibold">{employee.name}</span>
        <span aria-hidden="true"> · </span>
        <span className="sr-only">, </span>
        <span dir="ltr" className="whitespace-nowrap">
          {employee.employeeId}
        </span>
      </p>
      <p className="mt-1.5">{text}</p>
    </>
  );
}

interface DialogProblem {
  key: DictKey;
  params?: Record<string, number>;
  /** Shows a Reload button (the employee changed under the user). */
  reload: boolean;
}

/**
 * Turns a failed mutation into what the dialog shows. The dialog always stays open (except NOT_FOUND),
 * so the user keeps what they typed.
 */
export function useDialogFailure(employee: DialogEmployee, onClose: () => void) {
  const { t } = useI18n();
  const toast = useToast();
  const queryClient = useQueryClient();
  const [problem, setProblem] = useState<DialogProblem | null>(null);
  const [fieldErrors, setFieldErrors] = useState<Record<string, DictKey>>({});

  /** Refetch this employee (detail) and every list that may show it. */
  const refresh = () => {
    void queryClient.invalidateQueries({ queryKey: employeeKeys.detail(employee.id) });
    void queryClient.invalidateQueries({ queryKey: employeeKeys.lists() });
  };

  const clear = () => {
    setProblem(null);
    setFieldErrors({});
  };

  const handle = (error: unknown) => {
    const code = error instanceof ApiError ? error.code : '';
    const mapped = mapEmployeeError(error, 'save');
    setFieldErrors(mapped.fieldErrors ?? {});

    switch (code) {
      case 'NOT_FOUND':
        toast.error(t('err.notFound'));
        refresh();
        onClose();
        return;
      case 'INVALID_STATE':
      case 'FORBIDDEN':
        refresh();
        setProblem({ key: mapped.messageKey, reload: false });
        return;
      case 'VERSION_CONFLICT':
        setProblem({ key: 'err.conflict', reload: true });
        return;
      case 'LAST_MAIN_ADMIN_PROTECTED':
        setProblem({ key: 'protected.main', reload: false });
        return;
      case 'VALIDATION_ERROR': {
        // A reason or permissions problem is shown at its field; anything else is a general message.
        const handledAtField = Object.keys(mapped.fieldErrors ?? {}).every((f) => f === 'reason' || f === 'permissions');
        setProblem(handledAtField && Object.keys(mapped.fieldErrors ?? {}).length > 0 ? null : { key: mapped.messageKey, reload: false });
        return;
      }
      default:
        setProblem({ key: mapped.messageKey, params: mapped.messageParams, reload: false });
    }
  };

  const reload = () => {
    refresh();
    clear();
  };

  const error: ReactNode = problem ? (
    <div>
      <p>{t(problem.key, problem.params)}</p>
      {problem.reload && (
        <Button variant="secondary" onClick={reload} className="mt-2">
          {t('act.reload')}
        </Button>
      )}
    </div>
  ) : null;

  const fieldMessage = (field: string): string | undefined => {
    const key = fieldErrors[field];
    return key ? t(key) : undefined;
  };

  return { error, handle, clear, fieldMessage };
}
