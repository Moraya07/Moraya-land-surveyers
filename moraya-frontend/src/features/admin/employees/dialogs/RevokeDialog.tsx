import { ConfirmDialog } from '../../../../components/ui/ConfirmDialog';
import { useToast } from '../../../../components/ui/Toast';
import { useI18n } from '../../../../i18n';
import { useChangeStatus } from '../hooks';
import { EmployeeBody, useDialogFailure, type ActionDialogProps } from './shared';

/**
 * Revoke account access: the strongest confirmation. A reason is required and the user must type the
 * Employee ID (case and surrounding spaces are ignored) before the button is enabled.
 */
export function RevokeDialog({ employee, onClose }: ActionDialogProps) {
  const { t } = useI18n();
  const toast = useToast();
  const change = useChangeStatus(employee.id);
  const failure = useDialogFailure(employee, onClose);

  return (
    <ConfirmDialog
      open
      danger
      title={t('dlg.revokeTitle', { name: employee.name })}
      body={<EmployeeBody employee={employee} text={t('confirm.revoke')} />}
      confirmLabel={t('act.revoke')}
      withReason
      confirmText={employee.employeeId}
      confirmTextIgnoreCase
      confirmTextPrompt={t('confirm.typeId', { id: employee.employeeId })}
      loading={change.isPending}
      error={failure.error}
      reasonError={failure.fieldMessage('reason')}
      onReasonChange={failure.clear}
      onClose={onClose}
      onConfirm={(reason) => {
        failure.clear();
        change.mutate(
          { action: 'revoke', reason },
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
