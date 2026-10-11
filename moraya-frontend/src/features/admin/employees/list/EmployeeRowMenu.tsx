import { useEffect, useId, useRef, useState, type KeyboardEvent } from 'react';
import { Link } from 'react-router-dom';
import { useI18n } from '../../../../i18n';
import { useEmployeeActions, type EmployeeAction } from '../actions/useEmployeeActions';
import type { EmployeeListItem } from '../types';
import { useListLinkState } from './listReturn';
import { MoreVerticalIcon } from './listIcons';

const ITEM =
  'flex min-h-11 w-full items-center px-3 text-start text-sm hover:bg-panel focus-visible:bg-panel';

/**
 * Kebab menu of a list row: View, Edit (when allowed), then the status actions from `useEmployeeActions`.
 * A list row only carries the row capabilities, so only deactivate / reactivate can appear.
 * The action dialogs render here, next to the trigger, and hand focus back to it when they close.
 */
export function EmployeeRowMenu({ employee }: { employee: EmployeeListItem }) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const panelRef = useRef<HTMLDivElement>(null);
  const panelId = useId();
  const linkState = useListLinkState();
  const { items, dialogs } = useEmployeeActions(employee, { returnFocusRef: triggerRef });

  const label = t('list.rowActions', { name: employee.name });
  const path = `/admin/employees/${encodeURIComponent(employee.id)}`;

  // Opening moves focus to the first item.
  useEffect(() => {
    if (!open) return;
    panelRef.current?.querySelector<HTMLElement>('[role="menuitem"]')?.focus();
  }, [open]);

  // Outside click closes.
  useEffect(() => {
    if (!open) return;
    const onPointerDown = (e: MouseEvent) => {
      if (rootRef.current && e.target instanceof Node && !rootRef.current.contains(e.target)) setOpen(false);
    };
    document.addEventListener('mousedown', onPointerDown);
    return () => document.removeEventListener('mousedown', onPointerDown);
  }, [open]);

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
        setOpen(false); // focus moves on naturally
        break;
    }
  };

  const choose = (action: EmployeeAction) => {
    // Focus is on the trigger when the dialog opens, so it can be handed back there afterwards.
    triggerRef.current?.focus();
    setOpen(false);
    action.onSelect();
  };

  return (
    <div ref={rootRef} className="relative">
      <button
        ref={triggerRef}
        type="button"
        aria-label={label}
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
        className="flex h-11 w-11 items-center justify-center rounded-md text-text-muted hover:bg-panel hover:text-text"
      >
        <MoreVerticalIcon />
      </button>

      {open && (
        <div
          ref={panelRef}
          id={panelId}
          role="menu"
          aria-label={label}
          onKeyDown={onPanelKeyDown}
          className="anim-pop absolute end-0 top-full z-30 mt-1 min-w-48 max-w-[calc(100vw-2rem)] rounded-md border border-border bg-surface py-1 shadow-lg"
        >
          <Link role="menuitem" tabIndex={-1} to={path} state={linkState} onClick={() => setOpen(false)} className={ITEM}>
            {t('act.view')}
          </Link>
          {employee.capabilities.canEdit && (
            <Link role="menuitem" tabIndex={-1} to={`${path}/edit`} onClick={() => setOpen(false)} className={ITEM}>
              {t('act.edit')}
            </Link>
          )}
          {items.length > 0 && <div role="separator" className="my-1 border-t border-border" />}
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

      {/* Clicks inside a dialog must not reach the row (a row click opens the employee). */}
      {dialogs && (
        <div role="presentation" onClick={(e) => e.stopPropagation()}>
          {dialogs}
        </div>
      )}
    </div>
  );
}
