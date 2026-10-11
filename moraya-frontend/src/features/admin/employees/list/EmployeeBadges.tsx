import { BanIcon, CheckIcon, CircleDashedIcon, ClipboardIcon, KeyIcon, ShieldCheckIcon } from '../../../../components/icons';
import { useI18n } from '../../../../i18n';
import { ROLE_LABEL, STATUS_LABEL } from '../labels';
import type { AccountStatus, Role } from '../types';

const STATUS_LOOK: Record<AccountStatus, { cls: string; Icon: typeof CheckIcon }> = {
  active: { cls: 'badge-success', Icon: CheckIcon },
  inactive: { cls: 'badge-neutral', Icon: CircleDashedIcon },
  revoked: { cls: 'badge-danger', Icon: BanIcon },
};

const ROLE_LOOK: Record<Role, { cls: string; Icon: typeof CheckIcon }> = {
  main_admin: { cls: 'badge-info', Icon: ShieldCheckIcon },
  sub_admin: { cls: 'badge-neutral', Icon: KeyIcon },
  worker: { cls: 'badge-neutral', Icon: ClipboardIcon },
};

/** Account status: icon + text, never colour alone. */
export function AccountStatusBadge({ status }: { status: AccountStatus }) {
  const { t } = useI18n();
  const { cls, Icon } = STATUS_LOOK[status];
  return (
    <span className={`badge ${cls}`}>
      <Icon width={12} height={12} />
      {t(STATUS_LABEL[status])}
    </span>
  );
}

/** Role: icon + text. Same look wherever an employee's role is shown. */
export function RoleBadge({ role }: { role: Role }) {
  const { t } = useI18n();
  const { cls, Icon } = ROLE_LOOK[role];
  return (
    <span className={`badge ${cls}`}>
      <Icon width={12} height={12} />
      {t(ROLE_LABEL[role])}
    </span>
  );
}
