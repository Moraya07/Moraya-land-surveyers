import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { useI18n } from '../../i18n';
import { AlertIcon, CheckIcon, XIcon } from '../icons';

type Variant = 'success' | 'error';

interface ToastItem {
  id: number;
  variant: Variant;
  message: string;
}

interface ToastApi {
  /** Pass already-translated text. Never put an Aadhaar number or a password in a toast. */
  success: (message: string) => void;
  error: (message: string) => void;
}

const ToastContext = createContext<ToastApi | null>(null);

const MAX_VISIBLE = 3;
const LIFETIME_MS: Record<Variant, number> = { success: 4000, error: 7000 };

export function ToastProvider({ children }: { children: ReactNode }) {
  const { t } = useI18n();
  const [items, setItems] = useState<ToastItem[]>([]);
  const nextId = useRef(1);
  const timers = useRef(new Map<number, ReturnType<typeof setTimeout>>());

  const dismiss = useCallback((id: number) => {
    const timer = timers.current.get(id);
    if (timer) clearTimeout(timer);
    timers.current.delete(id);
    setItems((list) => list.filter((item) => item.id !== id));
  }, []);

  const push = useCallback(
    (variant: Variant, message: string) => {
      const id = nextId.current++;
      setItems((list) => [...list, { id, variant, message }].slice(-MAX_VISIBLE));
      timers.current.set(
        id,
        setTimeout(() => dismiss(id), LIFETIME_MS[variant]),
      );
    },
    [dismiss],
  );

  useEffect(() => {
    const active = timers.current;
    return () => {
      active.forEach((timer) => clearTimeout(timer));
      active.clear();
    };
  }, []);

  const api = useMemo<ToastApi>(
    () => ({ success: (m) => push('success', m), error: (m) => push('error', m) }),
    [push],
  );

  return (
    <ToastContext.Provider value={api}>
      {children}
      {/* One polite live region; it exists before any toast so screen readers announce additions. */}
      <div
        aria-live="polite"
        aria-atomic="false"
        className="pointer-events-none fixed inset-x-3 bottom-3 z-[60] flex flex-col items-center gap-2 sm:inset-x-auto sm:end-4 sm:bottom-4 sm:items-end"
      >
        {items.map((item) => (
          <div
            key={item.id}
            className={`anim-pop pointer-events-auto flex w-full max-w-sm items-start gap-2.5 rounded-md border bg-surface p-3 text-sm shadow-lg ${
              item.variant === 'success' ? 'border-success/60' : 'border-danger/60'
            }`}
          >
            {item.variant === 'success' ? (
              <CheckIcon className="mt-[0.1em] shrink-0 text-success" />
            ) : (
              <AlertIcon className="mt-[0.1em] shrink-0 text-danger" />
            )}
            <p className="min-w-0 flex-1 break-words">{item.message}</p>
            <button
              type="button"
              aria-label={t('toast.dismiss')}
              onClick={() => dismiss(item.id)}
              className="-m-2 flex h-11 w-11 shrink-0 items-center justify-center rounded-md text-text-muted hover:text-text lg:-m-1 lg:h-8 lg:w-8"
            >
              <XIcon width={16} height={16} />
            </button>
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  );
}

export function useToast(): ToastApi {
  const ctx = useContext(ToastContext);
  if (!ctx) throw new Error('useToast must be used inside <ToastProvider>');
  return ctx;
}
