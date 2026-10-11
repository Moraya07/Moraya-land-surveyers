import type { ComponentType, SVGProps } from 'react';
import {
  BanIcon,
  CheckIcon,
  ClockIcon,
  LockIcon,
  PencilIcon,
  ShieldCheckIcon,
  UsersIcon,
} from '../../../../../components/icons';
import { useI18n } from '../../../../../i18n';
import { formatDate, formatTime } from '../../../../../lib/format';
import type { ActivityItem } from '../../types';
import {
  actionCategory,
  actionKey,
  relativeTime,
  safeChanges,
  validIso,
  type ActivityCategory,
} from '../activityText';
import { ChangeList } from './ChangeList';

type Icon = ComponentType<SVGProps<SVGSVGElement>>;

/** Marker look per category. Colours come from the shared badge tokens; the icon carries the meaning too. */
const MARKER: Record<ActivityCategory, { cls: string; Icon: Icon }> = {
  created: { cls: 'badge-success', Icon: UsersIcon },
  edited: { cls: 'badge-info', Icon: PencilIcon },
  off: { cls: 'badge-danger', Icon: BanIcon },
  on: { cls: 'badge-success', Icon: CheckIcon },
  access: { cls: 'badge-info', Icon: ShieldCheckIcon },
  sensitive: { cls: 'badge-warning', Icon: LockIcon },
  unknown: { cls: 'badge-neutral', Icon: ClockIcon },
};

/** These two never show a "What changed" block, whatever the server sent: no value may appear for them. */
const NO_DIFF = new Set(['USER_AADHAAR_CHANGED', 'AADHAAR_REVEALED']);

interface Props {
  item: ActivityItem;
  /** One "now" for the whole list, so every relative hint is computed from the same moment. */
  now: number;
}

/** One timeline entry. Everything from the server is drawn as text: never as HTML, never in an attribute. */
export function ActivityItemRow({ item, now }: Props) {
  const { t, lang } = useI18n();
  const { cls, Icon } = MARKER[actionCategory(item.action)];
  const iso = validIso(item.at);
  const actor = item.actorName?.trim();
  const reason = item.reason?.trim();
  const changes = NO_DIFF.has(item.action) ? null : safeChanges(item.changes);
  const relative = iso ? relativeTime(item.at, now, lang) : '';

  return (
    <li className="group relative min-w-0 pb-6 pl-11 last:pb-0">
      {/* The connecting line; the last entry has none. */}
      <span aria-hidden="true" className="absolute bottom-0 left-4 top-8 w-px -translate-x-1/2 bg-border group-last:hidden" />
      <span
        aria-hidden="true"
        className={`badge ${cls} !absolute left-0 top-0 !h-8 !w-8 !justify-center !gap-0 !p-0`}
      >
        <Icon width={16} height={16} />
      </span>

      <div className="min-w-0">
        <p className="break-words text-sm font-semibold text-text">{t(actionKey(item.action))}</p>
        <p className="mt-0.5 flex flex-wrap items-baseline gap-x-2 gap-y-0.5 text-xs text-text-muted">
          <span className="min-w-0 break-words">{actor ? t('activity.by', { name: actor }) : t('activity.bySystem')}</span>
          <span aria-hidden="true">·</span>
          <time dateTime={iso} className="tabular-nums">
            {formatDate(item.at)} {formatTime(item.at)}
          </time>
          {relative && (
            <>
              <span aria-hidden="true">·</span>
              <span>{relative}</span>
            </>
          )}
        </p>

        {reason && (
          <p className="mt-2 min-w-0 whitespace-pre-line break-words text-sm text-text-muted [overflow-wrap:anywhere]">
            <span className="font-medium">{t('activity.reasonLabel')}:</span> “{reason}”
          </p>
        )}

        {changes && <ChangeList changes={changes} />}
      </div>
    </li>
  );
}
