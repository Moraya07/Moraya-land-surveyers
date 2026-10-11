import { useState } from 'react';
import { Chip } from '../../../../components/ui/Chip';
import { ConfirmDialog } from '../../../../components/ui/ConfirmDialog';
import { useToast } from '../../../../components/ui/Toast';
import { useI18n } from '../../../../i18n';
import { PermissionPicker } from '../components/PermissionPicker';
import { useChangePermissions, useEmployee } from '../hooks';
import { PERMISSION_LABEL, PERMISSION_ORDER } from '../labels';
import type { Permission } from '../types';
import { EmployeeBody, useDialogFailure, type ActionDialogProps } from './shared';

/**
 * Edit a Sub-Admin's permissions. The picker starts from the current permissions; the dialog lists what
 * would be Added and Removed. Confirm stays disabled until something changed and at least one remains.
 */
export function ChangePermissionsDialog({ employee, onClose }: ActionDialogProps) {
  const { t } = useI18n();
  const toast = useToast();
  const change = useChangePermissions(employee.id);
  const failure = useDialogFailure(employee, onClose);

  // A list row has no permissions: load the detail (once) in that case.
  const needsLoad = employee.permissions === undefined;
  const detail = useEmployee(needsLoad ? employee.id : undefined);
  const current: Permission[] | null = employee.permissions ?? detail.data?.permissions ?? null;

  const [edited, setEdited] = useState<Permission[] | null>(null);
  const value = edited ?? current ?? [];

  const added = current ? PERMISSION_ORDER.filter((p) => value.includes(p) && !current.includes(p)) : [];
  const removed = current ? PERMISSION_ORDER.filter((p) => current.includes(p) && !value.includes(p)) : [];
  const changed = added.length + removed.length > 0;
  const noneLeft = current !== null && value.length === 0;

  const loadError = needsLoad && detail.isError ? (
    <div>
      <p>{t('err.load')}</p>
      <button type="button" onClick={() => void detail.refetch()} className="link-action mt-1 underline">
        {t('act.retry')}
      </button>
    </div>
  ) : null;

  return (
    <ConfirmDialog
      open
      wide
      title={t('dlg.changePermsTitle', { name: employee.name })}
      body={<EmployeeBody employee={employee} text={t('confirm.changePerms')} />}
      confirmLabel={t('act.save')}
      withReason
      reasonRequired={false}
      loading={change.isPending}
      error={failure.error ?? loadError}
      reasonError={failure.fieldMessage('reason')}
      onReasonChange={failure.clear}
      confirmDisabled={current === null || !changed || noneLeft}
      onClose={onClose}
      onConfirm={(reason) => {
        if (!changed || noneLeft) return;
        failure.clear();
        change.mutate(
          { permissions: value, ...(reason ? { reason } : {}) },
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
      {current === null ? (
        !detail.isError && (
          <p role="status" className="text-sm text-text-muted">
            {t('common.loading')}
          </p>
        )
      ) : (
        <>
          <PermissionPicker
            value={value}
            onChange={(next) => {
              setEdited(next);
              failure.clear();
            }}
            error={noneLeft ? t('fieldErr.AT_LEAST_ONE') : failure.fieldMessage('permissions')}
            disabled={change.isPending}
          />
          {/* What would change, spelled out in words so it never depends on colour. */}
          <div aria-live="polite" className="mb-1 space-y-2 text-sm">
            {changed ? (
              <>
                {added.length > 0 && (
                  <div className="flex flex-wrap items-center gap-1.5">
                    <span className="font-medium">{t('perm.added')}:</span>
                    {added.map((p) => (
                      <Chip key={p}>{t(PERMISSION_LABEL[p])}</Chip>
                    ))}
                  </div>
                )}
                {removed.length > 0 && (
                  <div className="flex flex-wrap items-center gap-1.5">
                    <span className="font-medium">{t('perm.removed')}:</span>
                    {removed.map((p) => (
                      <Chip key={p}>{t(PERMISSION_LABEL[p])}</Chip>
                    ))}
                  </div>
                )}
              </>
            ) : (
              <p className="text-text-muted">{t('perm.noChange')}</p>
            )}
          </div>
        </>
      )}
    </ConfirmDialog>
  );
}
