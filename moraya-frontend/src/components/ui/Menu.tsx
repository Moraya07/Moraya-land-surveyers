import { useCallback, useEffect, useId, useRef, useState, type FocusEvent, type ReactNode } from 'react';

interface MenuProps {
  /** Accessible name of the trigger button. */
  label: string;
  trigger: ReactNode;
  children: (close: () => void) => ReactNode;
}

/** Disclosure popover: closes on Esc (focus returns to the trigger), outside click, or Tab-out. */
export function Menu({ label, trigger, children }: MenuProps) {
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);
  const buttonRef = useRef<HTMLButtonElement>(null);
  const panelId = useId();

  const close = useCallback(() => {
    setOpen(false);
    buttonRef.current?.focus();
  }, []);

  useEffect(() => {
    if (!open) return;
    const onPointerDown = (e: MouseEvent) => {
      if (rootRef.current && e.target instanceof Node && !rootRef.current.contains(e.target)) setOpen(false);
    };
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') close();
    };
    document.addEventListener('mousedown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('mousedown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [open, close]);

  const onBlur = (e: FocusEvent<HTMLDivElement>) => {
    if (open && e.relatedTarget instanceof Node && !e.currentTarget.contains(e.relatedTarget)) setOpen(false);
  };

  return (
    <div ref={rootRef} onBlur={onBlur} className="relative">
      <button
        ref={buttonRef}
        type="button"
        aria-label={label}
        aria-expanded={open}
        aria-controls={open ? panelId : undefined}
        onClick={() => setOpen((v) => !v)}
        className="flex min-h-11 items-center gap-2 rounded-md px-1.5 hover:bg-panel lg:min-h-9"
      >
        {trigger}
      </button>
      {open && (
        <div
          id={panelId}
          className="anim-pop absolute right-0 top-full z-40 mt-2 w-72 max-w-[calc(100vw-2rem)] rounded-md border border-border bg-surface p-3 shadow-lg"
        >
          {children(close)}
        </div>
      )}
    </div>
  );
}
