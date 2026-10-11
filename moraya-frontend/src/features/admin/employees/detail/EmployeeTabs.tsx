import { useId, useRef, type KeyboardEvent } from 'react';
import { useLocation, useSearchParams } from 'react-router-dom';
import { useI18n, type DictKey } from '../../../../i18n';
import type { AuthUser } from '../../../auth/authApi';
import { hasPermission } from '../../permissions';
import type { EmployeeDetail } from '../types';
import { ModuleComingSoonTab } from './ModuleComingSoonTab';
import { ProfileTab } from './ProfileTab';
import { ActivityTab } from './tabs/ActivityTab';

export const TAB_IDS = ['profile', 'work', 'expenses', 'salary', 'activity'] as const;
export type TabId = (typeof TAB_IDS)[number];

const TAB_LABEL: Record<TabId, DictKey> = {
  profile: 'tab.profile',
  work: 'tab.work',
  expenses: 'tab.expenses',
  salary: 'tab.salary',
  activity: 'tab.activity',
};

/** Which tabs exist for this viewer and employee. Profile is always there. */
export function visibleTabs(user: Pick<AuthUser, 'role' | 'permissions'> | null | undefined, employee: EmployeeDetail): TabId[] {
  const tabs: TabId[] = ['profile'];
  if (user && hasPermission(user, 'verification')) tabs.push('work', 'expenses');
  if (user && hasPermission(user, 'salary_management')) tabs.push('salary');
  if (employee.capabilities.canViewActivity) tabs.push('activity');
  return tabs;
}

interface Props {
  employee: EmployeeDetail;
  user: Pick<AuthUser, 'role' | 'permissions'> | null | undefined;
}

/**
 * WAI-ARIA tabs with the selected tab in the URL (`?tab=`). An unknown or unavailable value shows Profile.
 * Arrow keys, Home and End move between tabs (and select them). Only the active panel is mounted, so
 * leaving the Profile tab also drops anything held by it (the revealed Aadhaar number).
 * The employee comes in as a prop: switching tabs never touches the query.
 */
export function EmployeeTabs({ employee, user }: Props) {
  const { t } = useI18n();
  const baseId = useId();
  const location = useLocation();
  const [searchParams, setSearchParams] = useSearchParams();
  const buttons = useRef(new Map<TabId, HTMLButtonElement>());

  const tabs = visibleTabs(user, employee);
  const requested = searchParams.get('tab');
  const active: TabId = tabs.find((id) => id === requested) ?? 'profile';

  const select = (id: TabId, focus: boolean) => {
    if (id !== active || requested !== id) {
      const next = new URLSearchParams(searchParams);
      next.set('tab', id);
      // replace: tab changes should not fill the history; keep the router state (the list's search) as it is.
      setSearchParams(next, { replace: true, state: location.state });
    }
    if (focus) buttons.current.get(id)?.focus();
  };

  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
    const index = tabs.indexOf(active);
    const last = tabs.length - 1;
    let next: number | null = null;
    if (e.key === 'ArrowRight') next = index === last ? 0 : index + 1;
    else if (e.key === 'ArrowLeft') next = index === 0 ? last : index - 1;
    else if (e.key === 'Home') next = 0;
    else if (e.key === 'End') next = last;
    if (next === null) return;
    const target = tabs[next];
    if (!target) return;
    e.preventDefault();
    select(target, true);
  };

  const panel = (() => {
    switch (active) {
      case 'work':
        return <ModuleComingSoonTab messageKey="empty.employeeWork" />;
      case 'expenses':
        return <ModuleComingSoonTab messageKey="empty.employeeExpenses" />;
      case 'salary':
        return <ModuleComingSoonTab messageKey="empty.employeeSalary" />;
      case 'activity':
        return <ActivityTab employeeId={employee.id} />;
      default:
        return <ProfileTab employee={employee} />;
    }
  })();

  return (
    <div className="min-w-0">
      {/* The tab list scrolls inside its own box on narrow screens; the page never scrolls sideways. */}
      <div className="max-w-full overflow-x-auto border-b border-border">
        <div role="tablist" aria-label={t('emp.route.detail')} onKeyDown={onKeyDown} className="flex min-w-max">
          {tabs.map((id) => {
            const selected = id === active;
            return (
              <button
                key={id}
                ref={(el) => {
                  if (el) buttons.current.set(id, el);
                  else buttons.current.delete(id);
                }}
                type="button"
                role="tab"
                id={`${baseId}-tab-${id}`}
                aria-selected={selected}
                aria-controls={selected ? `${baseId}-panel-${id}` : undefined}
                tabIndex={selected ? 0 : -1}
                onClick={() => select(id, false)}
                className="tab min-h-11 shrink-0"
              >
                {t(TAB_LABEL[id])}
              </button>
            );
          })}
        </div>
      </div>
      <div role="tabpanel" id={`${baseId}-panel-${active}`} aria-labelledby={`${baseId}-tab-${active}`} tabIndex={0} className="pt-4">
        {panel}
      </div>
    </div>
  );
}
