import { useEffect, useRef } from 'react';
import { XIcon } from '../../components/icons';
import { Logo } from '../../components/Logo';
import { useI18n } from '../../i18n';
import type { NavItem } from './navConfig';
import { SidebarNav } from './Sidebar';
import { useFocusTrap } from './useFocusTrap';

interface MobileDrawerProps {
  open: boolean;
  onClose: () => void;
  items: NavItem[];
}

/** Accessible navigation drawer for < 1024px: focus trap, Esc, overlay click, closes on route change. */
export function MobileDrawer({ open, onClose, items }: MobileDrawerProps) {
  const { t } = useI18n();
  const panelRef = useRef<HTMLDivElement>(null);
  useFocusTrap(panelRef, open, onClose);

  // Lock page scroll while open and close if the window grows to the desktop layout.
  useEffect(() => {
    if (!open) return;
    const previous = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    const mq = window.matchMedia('(min-width: 1024px)');
    const onChange = () => {
      if (mq.matches) onClose();
    };
    mq.addEventListener('change', onChange);
    return () => {
      document.body.style.overflow = previous;
      mq.removeEventListener('change', onChange);
    };
  }, [open, onClose]);

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-40 lg:hidden">
      <div className="anim-fade absolute inset-0 bg-black/40" aria-hidden="true" onClick={onClose} />
      <div
        ref={panelRef}
        id="admin-drawer"
        role="dialog"
        aria-modal="true"
        aria-label={t('nav.label')}
        tabIndex={-1}
        className="anim-drawer absolute inset-y-0 left-0 flex w-72 max-w-[85vw] flex-col bg-surface shadow-xl"
      >
        <div className="flex h-14 shrink-0 items-center justify-between border-b border-border pl-4 pr-2">
          <Logo className="w-10" />
          <button
            type="button"
            onClick={onClose}
            aria-label={t('nav.close')}
            className="flex h-11 w-11 items-center justify-center rounded-md text-text-muted hover:bg-panel hover:text-text"
          >
            <XIcon />
          </button>
        </div>
        <SidebarNav items={items} onNavigate={onClose} />
      </div>
    </div>
  );
}
