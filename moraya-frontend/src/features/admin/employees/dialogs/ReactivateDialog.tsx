import { ConfirmDialog } from '../../../../components/ui/ConfirmDialog';
import { useToast } from '../../../../components/ui/Toast';
import { useI18n } from '../../../../i18n';
import { useChangeStatus } from '../hooks';
import { EmployeeBody, useDialogFailure, type ActionDialogProps } from './shared';

/** Reactivate: a simple confirmation with an optional reason. */
export function ReactivateDialog({ employee, onClose }: ActionDialogProps) {
  const { t } = useI18n();
  const toast = useToast();
  const change = useChangeStatus(employee.id);
  const failure = useDialogFailure(employee, onClose);

  return (
    <ConfirmDialog
      open
      title={t('dlg.reactivateTitle', { name: employee.name })}
      body={<EmployeeBody employee={employee} text={t('confirm.reactivate')} />}
      confirmLabel={t('act.reactivate')}
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
          reason ? { action: 'reactivate', reason } : { action: 'reactivate' },
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
