import { ConfirmDialog } from '../../../../components/ui/ConfirmDialog';
import { useToast } from '../../../../components/ui/Toast';
import { useI18n } from '../../../../i18n';
import { useChangeRole } from '../hooks';
import { EmployeeBody, useDialogFailure, type ActionDialogProps } from './shared';

/** Demote a Sub-Admin to Surveyor. All admin permissions are lost; the reason is optional. */
export function RemoveSubAdminDialog({ employee, onClose }: ActionDialogProps) {
  const { t } = useI18n();
  const toast = useToast();
  const change = useChangeRole(employee.id);
  const failure = useDialogFailure(employee, onClose);

  return (
    <ConfirmDialog
      open
      danger
      title={t('dlg.removeSubAdminTitle', { name: employee.name })}
      body={<EmployeeBody employee={employee} text={t('confirm.removeSubAdmin')} />}
      confirmLabel={t('act.removeSubAdmin')}
      withReason
      reasonRequired={false}
      loading={change.isPending}
      error={failure.error}
      reasonError={failure.fieldMessage('reason')}
      onReasonChange={failure.clear}
      onClose={onClose}
      onConfirm={(reason) => {
        failure.clear();
        change.mutate(
          { role: 'worker', ...(reason ? { reason } : {}) },
          {
            onSuccess: () => {
              toast.success(t('toast.updated'));
              onClose();
            },
            onError: failure.handle,
          },
        );
      }}
    />
  );
}
