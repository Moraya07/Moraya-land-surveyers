import { useState } from 'react';
import { ConfirmDialog } from '../../../../components/ui/ConfirmDialog';
import { useToast } from '../../../../components/ui/Toast';
import { useI18n } from '../../../../i18n';
import { PermissionPicker } from '../components/PermissionPicker';
import { useChangeRole } from '../hooks';
import type { Permission } from '../types';
import { EmployeeBody, useDialogFailure, type ActionDialogProps } from './shared';

/** Promote a Surveyor to Sub-Admin: at least one permission is required, the reason is optional. */
export function MakeSubAdminDialog({ employee, onClose }: ActionDialogProps) {
  const { t } = useI18n();
  const toast = useToast();
  const change = useChangeRole(employee.id);
  const failure = useDialogFailure(employee, onClose);
  const [permissions, setPermissions] = useState<Permission[]>([]);
  const [showPermissionError, setShowPermissionError] = useState(false);

  const permissionError =
    permissions.length === 0 && showPermissionError ? t('fieldErr.AT_LEAST_ONE') : failure.fieldMessage('permissions');

  return (
    <ConfirmDialog
      open
      wide
      title={t('dlg.makeSubAdminTitle', { name: employee.name })}
      body={<EmployeeBody employee={employee} text={t('confirm.makeSubAdmin')} />}
      confirmLabel={t('act.makeSubAdmin')}
      withReason
      reasonRequired={false}
      loading={change.isPending}
      error={failure.error}
      reasonError={failure.fieldMessage('reason')}
      onReasonChange={failure.clear}
      onClose={onClose}
      onConfirm={(reason) => {
        if (permissions.length === 0) {
          setShowPermissionError(true);
          return;
        }
        failure.clear();
        change.mutate(
          { role: 'sub_admin', permissions, ...(reason ? { reason } : {}) },
          {
            onSuccess: () => {
              toast.success(t('toast.updated'));
              onClose();
            },
            onError: failure.handle,
          },
        );
      }}
    >
      <PermissionPicker
        value={permissions}
        onChange={(next) => {
          setPermissions(next);
          failure.clear();
        }}
        error={permissionError}
        disabled={change.isPending}
      />
    </ConfirmDialog>
  );
}
