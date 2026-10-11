import { useEffect, useId, useRef, useState, type KeyboardEvent } from 'react';
import { Link } from 'react-router-dom';
import { ChevronDownIcon, ChevronLeftIcon, LockIcon } from '../../../../components/icons';
import { useI18n } from '../../../../i18n';
import { useEmployeeActions, type EmployeeAction } from '../actions/useEmployeeActions';
import { AccountStatusBadge, RoleBadge } from '../list/EmployeeBadges';
import type { EmployeeDetail } from '../types';

const LIST_PATH = '/admin/employees';
const ITEM = 'flex min-h-11 w-full items-center px-3 text-start text-sm hover:bg-panel focus-visible:bg-panel';

interface Props {
  employee: EmployeeDetail;
  /** The list's query string ("?status=inactive&page=2") when the user came from the list, else "". */
  listSearch: string;
}

/**
 * Back link, name, Employee ID, badges and the Actions menu. The menu is Edit (when allowed) plus whatever
 * `useEmployeeActions` offers; for the protected Main Admin there are no destructive actions, only a note.
 */
export function EmployeeHeader({ employee, listSearch }: Props) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const panelRef = useRef<HTMLDivElement>(null);
  const panelId = useId();
  const { items, dialogs, isProtectedMainAdmin } = useEmployeeActions(employee, { returnFocusRef: triggerRef });

  const canEdit = employee.capabilities.canEdit;
  const hasMenu = canEdit || items.length > 0;

  useEffect(() => {
    if (!open) return;
    panelRef.current?.querySelector<HTMLElement>('[role="menuitem"]')?.focus();
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const onPointerDown = (e: MouseEvent) => {
      if (rootRef.current && e.target instanceof Node && !rootRef.current.contains(e.target)) setOpen(false);
    };
    document.addEventListener('mousedown', onPointerDown);
    return () => document.removeEventListener('mousedown', onPointerDown);
  }, [open]);

  // The menu cannot stay open if the employee changed and it no longer has anything to offer.
  useEffect(() => {
    if (!hasMenu) setOpen(false);
  }, [hasMenu]);

  const onPanelKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
    const els = Array.from(panelRef.current?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? []);
    const current = els.findIndex((el) => el === document.activeElement);
    switch (e.key) {
      case 'ArrowDown':
        e.preventDefault();
        els[(current + 1) % els.length]?.focus();
        break;
      case 'ArrowUp':
        e.preventDefault();
        els[(current - 1 + els.length) % els.length]?.focus();
        break;
      case 'Home':
        e.preventDefault();
        els[0]?.focus();
        break;
      case 'End':
        e.preventDefault();
        els[els.length - 1]?.focus();
        break;
      case 'Escape':
        e.preventDefault();
        setOpen(false);
        triggerRef.current?.focus();
        break;
      case 'Tab':
        setOpen(false);
        break;
    }
  };

  const choose = (action: EmployeeAction) => {
    // Focus is on the trigger when the dialog opens, so the dialog can hand it back there.
    triggerRef.current?.focus();
    setOpen(false);
    action.onSelect();
  };

  return (
    <header className="space-y-3">
      <Link to={{ pathname: LIST_PATH, search: listSearch }} className="link-action inline-flex min-h-11 items-center gap-1 text-sm">
        <ChevronLeftIcon width={16} height={16} />
        {t('detail.back')}
      </Link>

      <div className="flex flex-wrap items-start justify-between gap-x-4 gap-y-3">
        <div className="min-w-0">
          <h1 className="break-words text-xl font-semibold sm:text-2xl" style={{ lineHeight: 'var(--lh-heading)' }}>
            {employee.name}
          </h1>
          <p className="mt-1 text-sm text-text-muted">
            <span>{t('field.employeeId')}: </span>
            <span dir="ltr" className="inline-block tabular-nums text-text">
              {employee.employeeId}
            </span>
          </p>
          <div className="mt-2 flex flex-wrap items-center gap-2">
            <RoleBadge role={employee.role} />
            <AccountStatusBadge status={employee.accountStatus} />
          </div>
        </div>

        {hasMenu && (
          <div ref={rootRef} className="relative">
            <button
              ref={triggerRef}
              type="button"
              aria-haspopup="menu"
              aria-expanded={open}
              aria-controls={open ? panelId : undefined}
              onClick={() => setOpen((v) => !v)}
              onKeyDown={(e) => {
                if (e.key === 'ArrowDown' && !open) {
                  e.preventDefault();
                  setOpen(true);
                }
              }}
              className="inline-flex min-h-11 items-center justify-center gap-2 rounded-md border border-field bg-surface px-4 text-sm font-medium text-text transition-colors hover:bg-panel"
            >
              {t('act.actions')}
              <ChevronDownIcon width={16} height={16} />
            </button>

            {open && (
              <div
                ref={panelRef}
                id={panelId}
                role="menu"
                aria-label={t('act.actions')}
                onKeyDown={onPanelKeyDown}
                className="anim-pop absolute end-0 top-full z-30 mt-1 min-w-56 max-w-[calc(100vw-2rem)] rounded-md border border-border bg-surface py-1 shadow-lg"
              >
                {canEdit && (
                  <Link
                    role="menuitem"
                    tabIndex={-1}
                    to={`${LIST_PATH}/${encodeURIComponent(employee.id)}/edit`}
                    onClick={() => setOpen(false)}
                    className={ITEM}
                  >
                    {t('act.edit')}
                  </Link>
                )}
                {canEdit && items.length > 0 && <div role="separator" className="my-1 border-t border-border" />}
                {items.map((item) => (
                  <button
                    key={item.key}
                    type="button"
                    role="menuitem"
                    tabIndex={-1}
                    onClick={() => choose(item)}
                    className={`${ITEM} ${item.danger ? 'text-danger' : ''}`}
                  >
                    {t(item.labelKey)}
                  </button>
                ))}
              </div>
            )}
          </div>
        )}
      </div>

      {isProtectedMainAdmin && (
        <p className="flex items-start gap-2 rounded-md border border-border bg-panel px-3 py-2 text-sm text-text-muted">
          <LockIcon className="mt-0.5 shrink-0" width={16} height={16} />
          <span>{t('protected.main')}</span>
        </p>
      )}

      {dialogs}
    </header>
  );
}
