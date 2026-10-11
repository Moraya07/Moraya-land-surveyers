import { useI18n } from '../../i18n';
import {
  BanIcon,
  CheckIcon,
  CircleDashedIcon,
  ClockIcon,
  PencilIcon,
  XCircleIcon,
} from '../icons';

export type BadgeStatus =
  | 'DRAFT'
  | 'PENDING_VERIFICATION'
  | 'VERIFIED'
  | 'CHANGES_REQUESTED'
  | 'REJECTED'
  | 'CANCELLED'
  | 'PENDING'
  | 'RECEIVED'
  | 'PARTIALLY_RECEIVED'
  | 'PARTIALLY_PAID';

const LOOK: Record<BadgeStatus, { cls: string; Icon: typeof CheckIcon }> = {
  DRAFT: { cls: 'badge-neutral', Icon: CircleDashedIcon },
  PENDING_VERIFICATION: { cls: 'badge-warning', Icon: ClockIcon },
  VERIFIED: { cls: 'badge-success', Icon: CheckIcon },
  CHANGES_REQUESTED: { cls: 'badge-info', Icon: PencilIcon },
  REJECTED: { cls: 'badge-danger', Icon: XCircleIcon },
  CANCELLED: { cls: 'badge-neutral', Icon: BanIcon },
  PENDING: { cls: 'badge-warning', Icon: ClockIcon },
  RECEIVED: { cls: 'badge-success', Icon: CheckIcon },
  PARTIALLY_RECEIVED: { cls: 'badge-info', Icon: ClockIcon },
  PARTIALLY_PAID: { cls: 'badge-info', Icon: ClockIcon },
};

/** One badge for every status in the app: icon + text label, never colour alone. */
export function StatusBadge({ status }: { status: BadgeStatus }) {
  const { t } = useI18n();
  const { cls, Icon } = LOOK[status];
  return (
    <span className={`badge ${cls}`}>
      <Icon width={12} height={12} />
      {t(`status.${status}`)}
    </span>
  );
}
