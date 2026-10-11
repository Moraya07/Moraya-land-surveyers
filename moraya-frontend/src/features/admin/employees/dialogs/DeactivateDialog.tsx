import { ConfirmDialog } from '../../../../components/ui/ConfirmDialog';
import { useToast } from '../../../../components/ui/Toast';
import { useI18n } from '../../../../i18n';
import { useChangeStatus } from '../hooks';
import { EmployeeBody, useDialogFailure, type ActionDialogProps } from './shared';

/** Deactivate: the person can't sign in; records are kept. A reason (5-500 characters) is required. */
export function DeactivateDialog({ employee, onClose }: ActionDialogProps) {
  const { t } = useI18n();
  const toast = useToast();
  const change = useChangeStatus(employee.id);
  const failure = useDialogFailure(employee, onClose);

  return (
    <ConfirmDialog
      open
      danger
      title={t('dlg.deactivateTitle', { name: employee.name })}
      body={<EmployeeBody employee={employee} text={t('confirm.deactivate')} />}
      confirmLabel={t('act.deactivate')}
      withReason
      loading={change.isPending}
      error={failure.error}
      reasonError={failure.fieldMessage('reason')}
      onReasonChange={failure.clear}
      onClose={onClose}
      onConfirm={(reason) => {
        failure.clear();
        change.mutate(
          { action: 'deactivate', reason },
          {
            onSuccess: () => {
              toast.success(t('toast.statusChanged'));
              onClose();
            },
            onError: failure.handle,
          },
        );
      }}
    />
  );
}
