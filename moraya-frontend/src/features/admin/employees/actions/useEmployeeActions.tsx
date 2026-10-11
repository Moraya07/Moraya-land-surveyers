import { useCallback, useMemo, useRef, useState, type ReactNode, type RefObject } from 'react';
import type { DictKey } from '../../../../i18n';
import { ChangePermissionsDialog } from '../dialogs/ChangePermissionsDialog';
import { DeactivateDialog } from '../dialogs/DeactivateDialog';
import { MakeSubAdminDialog } from '../dialogs/MakeSubAdminDialog';
import { ReactivateDialog } from '../dialogs/ReactivateDialog';
import { RemoveSubAdminDialog } from '../dialogs/RemoveSubAdminDialog';
import { RevokeDialog } from '../dialogs/RevokeDialog';
import type { DialogEmployee } from '../dialogs/shared';
import type { EmployeeCapabilities, RowCapabilities } from '../types';

export type EmployeeActionKey =
  | 'deactivate'
  | 'reactivate'
  | 'revoke'
  | 'makeSubAdmin'
  | 'removeSubAdmin'
  | 'changePermissions';

export interface EmployeeAction {
  key: EmployeeActionKey;
  labelKey: DictKey;
  /** Destructive: render it as a danger item. */
  danger: boolean;
  onSelect: () => void;
}

/**
 * A list row or the detail object. A list row only carries the row capabilities, so on a list the only
 * actions that can appear are deactivate and reactivate; the rest need the detail capabilities.
 */
export type ActionEmployee = DialogEmployee & {
  capabilities: RowCapabilities & Partial<Omit<EmployeeCapabilities, keyof RowCapabilities>>;
};

interface Options {
  /** Where focus goes when a dialog closes. Defaults to the element that was focused when the action was chosen. */
  returnFocusRef?: RefObject<HTMLElement | null>;
}

const LABEL: Record<EmployeeActionKey, DictKey> = {
  deactivate: 'act.deactivate',
  reactivate: 'act.reactivate',
  revoke: 'act.revoke',
  makeSubAdmin: 'act.makeSubAdmin',
  removeSubAdmin: 'act.removeSubAdmin',
  changePermissions: 'act.changePerms',
};

const DANGER: Record<EmployeeActionKey, boolean> = {
  deactivate: true,
  reactivate: false,
  revoke: true,
  makeSubAdmin: false,
  removeSubAdmin: true,
  changePermissions: false,
};

/**
 * Which actions exist for this employee (from the server's capabilities only) and the dialogs behind them.
 * Render `dialogs` once next to the menu or button; call `onSelect` of an item to open its dialog.
 */
export function useEmployeeActions(employee: ActionEmployee | undefined, options: Options = {}) {
  const [openKey, setOpenKey] = useState<EmployeeActionKey | null>(null);
  const triggerRef = useRef<HTMLElement | null>(null);
  const { returnFocusRef } = options;

  const open = useCallback((key: EmployeeActionKey) => {
    triggerRef.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    setOpenKey(key);
  }, []);

  const close = useCallback(() => {
    setOpenKey(null);
    // After the dialog has unmounted: back to the trigger (the dialog's own focus trap does the same when it can).
    requestAnimationFrame(() => {
      const target = returnFocusRef?.current ?? triggerRef.current;
      if (target?.isConnected) target.focus();
    });
  }, [returnFocusRef]);

  const caps = employee?.capabilities;
  const role = employee?.role;
  const isProtectedMainAdmin = Boolean(caps?.isProtectedMainAdmin) || role === 'main_admin';

  const items = useMemo<EmployeeAction[]>(() => {
    if (!employee || !caps || isProtectedMainAdmin) return [];
    const keys: EmployeeActionKey[] = [];
    if (caps.canDeactivate) keys.push('deactivate');
    if (caps.canReactivate) keys.push('reactivate');
    if (caps.canRevoke) keys.push('revoke');
    if (caps.canPromote && employee.role === 'worker') keys.push('makeSubAdmin');
    if (employee.role === 'sub_admin' && caps.canChangeRole) keys.push('removeSubAdmin');
    if (employee.role === 'sub_admin' && caps.canChangePermissions) keys.push('changePermissions');
    return keys.map((key) => ({ key, labelKey: LABEL[key], danger: DANGER[key], onSelect: () => open(key) }));
  }, [employee, caps, isProtectedMainAdmin, open]);

  let dialogs: ReactNode = null;
  if (employee && openKey) {
    const props = { employee, onClose: close };
    switch (openKey) {
      case 'deactivate':
        dialogs = <DeactivateDialog {...props} />;
        break;
      case 'reactivate':
        dialogs = <ReactivateDialog {...props} />;
        break;
      case 'revoke':
        dialogs = <RevokeDialog {...props} />;
        break;
      case 'makeSubAdmin':
        dialogs = <MakeSubAdminDialog {...props} />;
        break;
      case 'removeSubAdmin':
        dialogs = <RemoveSubAdminDialog {...props} />;
        break;
      case 'changePermissions':
        dialogs = <ChangePermissionsDialog {...props} />;
        break;
    }
  }

  return { items, dialogs, isProtectedMainAdmin };
}
