import { useEffect, useId, useRef, useState, type FormEvent, type ReactNode } from 'react';
import { useFocusTrap } from '../../features/admin/useFocusTrap';
import { useI18n } from '../../i18n';
import { Alert } from './Alert';
import { Button } from './Button';
import { Field } from './Field';

interface ConfirmDialogProps {
  open: boolean;
  title: string;
  body: ReactNode;
  /** Defaults to "Confirm". */
  confirmLabel?: string;
  /** Red confirm button; role="alertdialog". Focus starts on Cancel (or the first input), never on Confirm. */
  danger?: boolean;
  loading?: boolean;
  /** Shows a Reason textarea. */
  withReason?: boolean;
  /** With `withReason`: false makes the reason optional (empty is fine; if given it must meet the length rules). Default true. */
  reasonRequired?: boolean;
  /** Label of the reason field. Defaults to "Reason" (required) or "Reason (optional)". */
  reasonLabel?: string;
  /** Translated error from the server for the reason field. Shown instead of the local length message. */
  reasonError?: string;
  /** Called whenever the user edits the reason (lets the caller clear a server error). */
  onReasonChange?: () => void;
  /** Minimum reason length (default 5). Required whenever `withReason` is set. */
  minLength?: number;
  maxLength?: number;
  /** When set, Confirm stays disabled until the user types exactly this text. */
  confirmText?: string;
  /** Compare the typed text ignoring case and surrounding spaces. */
  confirmTextIgnoreCase?: boolean;
  /** Already-translated label for the type-to-confirm field. Defaults to "Type {text} to confirm". */
  confirmTextPrompt?: string;
  /** Extra form content between the body and the reason (for example a permission picker). */
  children?: ReactNode;
  /** Problem from the last attempt. Rendered as an alert above the buttons; may contain a button. */
  error?: ReactNode;
  /** Keeps Confirm disabled for a reason the dialog itself cannot see (nothing changed, still loading...). */
  confirmDisabled?: boolean;
  /** Wider panel for dialogs with a long form. */
  wide?: boolean;
  /** Receives the trimmed reason (undefined without `withReason`). */
  onConfirm: (reason: string | undefined) => void;
  onClose: () => void;
}

/**
 * Modal confirmation. Esc, Cancel and a backdrop click close it (all ignored while `loading`);
 * Tab stays inside; focus returns to the element that opened it.
 */
export function ConfirmDialog({
  open,
  title,
  body,
  confirmLabel,
  danger = false,
  loading = false,
  withReason = false,
  reasonRequired = true,
  reasonLabel,
  reasonError,
  onReasonChange,
  minLength = 5,
  maxLength = 500,
  confirmText,
  confirmTextIgnoreCase = false,
  confirmTextPrompt,
  children,
  error,
  confirmDisabled = false,
  wide = false,
  onConfirm,
  onClose,
}: ConfirmDialogProps) {
  const { t } = useI18n();
  const titleId = useId();
  const bodyId = useId();
  const rootRef = useRef<HTMLDivElement>(null);
  const reasonRef = useRef<HTMLTextAreaElement>(null);
  const [reason, setReason] = useState('');
  const [typed, setTyped] = useState('');
  const [showReasonError, setShowReasonError] = useState(false);

  const requestClose = () => {
    if (!loading) onClose();
  };
  useFocusTrap(rootRef, open, requestClose);

  // Fresh fields every time the dialog opens.
  useEffect(() => {
    if (open) {
      setReason('');
      setTyped('');
      setShowReasonError(false);
    }
  }, [open]);

  // Keep the page behind from scrolling.
  useEffect(() => {
    if (!open) return;
    const previous = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.body.style.overflow = previous;
    };
  }, [open]);

  if (!open) return null;

  const trimmed = reason.trim();
  const reasonValid =
    trimmed.length === 0
      ? !reasonRequired
      : trimmed.length >= minLength && trimmed.length <= maxLength;
  const textMatches =
    confirmText === undefined ||
    (confirmTextIgnoreCase ? typed.trim().toLowerCase() === confirmText.trim().toLowerCase() : typed === confirmText);

  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (loading || !textMatches) return;
    if (withReason && !reasonValid) {
      setShowReasonError(true);
      reasonRef.current?.focus();
      return;
    }
    onConfirm(withReason && trimmed !== '' ? trimmed : undefined);
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
        role={danger ? 'alertdialog' : 'dialog'}
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={bodyId}
        tabIndex={-1}
        className={`anim-pop max-h-dvh w-full ${wide ? 'max-w-lg' : 'max-w-md'} overflow-y-auto rounded-t-lg border border-border bg-surface p-5 shadow-lg sm:rounded-lg`}
      >
        <form onSubmit={submit} noValidate>
          <h2 id={titleId} className="text-lg font-semibold">
            {title}
          </h2>
          <div id={bodyId} className="mt-2 text-sm text-text-muted">
            {body}
          </div>

          {children && <div className="mt-4">{children}</div>}

          {(withReason || confirmText !== undefined) && (
            <div className="mt-4">
              {withReason && (
                <Field
                  label={reasonLabel ?? (reasonRequired ? t('reason.label') : t('reason.optional'))}
                  required={reasonRequired}
                  error={reasonError ?? (showReasonError && !reasonValid ? t('reason.required') : undefined)}
                >
                  {(control) => (
                    <textarea
                      ref={reasonRef}
                      {...control}
                      rows={3}
                      maxLength={maxLength}
                      value={reason}
                      onChange={(e) => {
                        setReason(e.target.value);
                        onReasonChange?.();
                      }}
                      className="input !h-auto py-2.5"
                    />
                  )}
                </Field>
              )}
              {confirmText !== undefined && (
                <Field label={confirmTextPrompt ?? t('confirm.typePrompt', { text: confirmText })}>
                  {(control) => (
                    <input
                      {...control}
                      type="text"
                      value={typed}
                      autoComplete="off"
                      autoCapitalize="off"
                      spellCheck={false}
                      onChange={(e) => setTyped(e.target.value)}
                      className="input"
                    />
                  )}
                </Field>
              )}
            </div>
          )}

          {error && (
            <div className="mt-4" role="alert">
              <Alert variant="danger">{error}</Alert>
            </div>
          )}

          {/* Cancel comes first in DOM order, so it (not Confirm) receives the initial focus. */}
          <div className="mt-5 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
            <Button variant="secondary" onClick={requestClose} disabled={loading}>
              {t('act.cancel')}
            </Button>
            <Button
              type="submit"
              variant={danger ? 'danger' : 'primary'}
              loading={loading}
              disabled={!textMatches || confirmDisabled}
              className={danger ? '' : '!h-11'}
            >
              {confirmLabel ?? t('act.confirm')}
            </Button>
          </div>
        </form>
      </div>
    </div>
  );
}
