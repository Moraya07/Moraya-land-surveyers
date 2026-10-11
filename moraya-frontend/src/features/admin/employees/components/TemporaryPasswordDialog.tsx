import { useEffect, useId, useRef, useState } from 'react';
import { CheckIcon, ClipboardIcon } from '../../../../components/icons';
import { Button } from '../../../../components/ui/Button';
import { useI18n } from '../../../../i18n';
import { useFocusTrap } from '../../useFocusTrap';

interface TemporaryPasswordDialogProps {
  /** Lives in the caller's component state only. The caller clears it when `onClose` fires. */
  password: string;
  onClose: () => void;
}

const COPIED_MS = 3000;

/** Old-browser / insecure-context fallback: select the field and use the legacy copy command. */
function legacyCopy(input: HTMLInputElement | null): boolean {
  if (!input) return false;
  input.focus();
  input.select();
  try {
    return document.execCommand('copy');
  } catch {
    return false;
  }
}

/**
 * Shows a one-time password. It cannot be closed (Esc, backdrop, button) until the user ticks
 * "I've saved it". The password is never written to storage, the URL, the console or a toast.
 */
export function TemporaryPasswordDialog({ password, onClose }: TemporaryPasswordDialogProps) {
  const { t } = useI18n();
  const titleId = useId();
  const bodyId = useId();
  const rootRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const copiedTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const [acknowledged, setAcknowledged] = useState(false);
  const [copied, setCopied] = useState(false);

  const requestClose = () => {
    if (acknowledged) onClose();
  };
  useFocusTrap(rootRef, true, requestClose);

  useEffect(() => {
    const previous = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.body.style.overflow = previous;
    };
  }, []);

  useEffect(() => () => clearTimeout(copiedTimer.current), []);

  const copy = async () => {
    let ok = false;
    try {
      await navigator.clipboard.writeText(password);
      ok = true;
    } catch {
      // No Clipboard API (or permission denied): try the legacy path. If that fails too the text stays selected.
      ok = legacyCopy(inputRef.current);
    }
    if (!ok) return;
    setCopied(true);
    clearTimeout(copiedTimer.current);
    copiedTimer.current = setTimeout(() => setCopied(false), COPIED_MS);
  };

  return (
    <div
      className="anim-fade fixed inset-0 z-50 flex items-end justify-center bg-black/50 p-0 sm:items-center sm:p-4"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) requestClose();
      }}
    >
      <div
        ref={rootRef}
        role="alertdialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={bodyId}
        tabIndex={-1}
        className="anim-pop max-h-dvh w-full max-w-md overflow-y-auto rounded-t-lg border border-border bg-surface p-5 shadow-lg sm:rounded-lg"
      >
        <h2 id={titleId} className="text-lg font-semibold">
          {t('temp.title')}
        </h2>
        <p id={bodyId} className="mt-2 text-sm text-text-muted">
          {t('temp.body')}
        </p>

        <div className="mt-4 flex gap-2">
          <input
            ref={inputRef}
            type="text"
            readOnly
            value={password}
            aria-label={t('temp.title')}
            dir="ltr"
            autoComplete="off"
            spellCheck={false}
            onFocus={(e) => e.currentTarget.select()}
            className="input min-w-0 flex-1 font-mono font-semibold tracking-wide"
          />
          <Button variant="secondary" onClick={() => void copy()} className="shrink-0">
            <ClipboardIcon width={18} height={18} />
            {t('temp.copy')}
          </Button>
        </div>
        {/* Always in the DOM so screen readers announce the text when it appears. */}
        <p aria-live="polite" className="mt-2 flex min-h-5 items-center gap-1.5 text-sm text-success">
          {copied && (
            <>
              <CheckIcon width={16} height={16} className="shrink-0" />
              {t('temp.copied')}
            </>
          )}
        </p>

        <label className="mt-3 flex min-h-11 cursor-pointer items-center gap-3 text-sm font-medium">
          <input
            type="checkbox"
            checked={acknowledged}
            onChange={(e) => setAcknowledged(e.target.checked)}
            className="h-5 w-5 shrink-0"
            style={{ accentColor: 'rgb(var(--c-primary))' }}
          />
          {t('temp.saved')}
        </label>

        <div className="mt-4 flex justify-end">
          <Button disabled={!acknowledged} onClick={onClose} className="!h-11">
            {t('act.confirm')}
          </Button>
        </div>
      </div>
    </div>
  );
}
