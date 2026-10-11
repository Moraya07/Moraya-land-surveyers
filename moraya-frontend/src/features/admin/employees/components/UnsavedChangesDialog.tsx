import { useEffect, useId, useRef } from 'react';
import { Button } from '../../../../components/ui/Button';
import { useI18n } from '../../../../i18n';
import { useFocusTrap } from '../../useFocusTrap';

interface UnsavedChangesDialogProps {
  open: boolean;
  onDiscard: () => void;
  onKeep: () => void;
}

/** "Discard unsaved changes?" Esc, the backdrop and "Keep editing" all keep the user on the form. */
export function UnsavedChangesDialog({ open, onDiscard, onKeep }: UnsavedChangesDialogProps) {
  const { t } = useI18n();
  const titleId = useId();
  const bodyId = useId();
  const rootRef = useRef<HTMLDivElement>(null);

  useFocusTrap(rootRef, open, onKeep);

  useEffect(() => {
    if (!open) return;
    const previous = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.body.style.overflow = previous;
    };
  }, [open]);

  if (!open) return null;

  return (
    <div
      className="anim-fade fixed inset-0 z-50 flex items-end justify-center bg-black/50 p-0 sm:items-center sm:p-4"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onKeep();
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
          {t('unsaved.title')}
        </h2>
        <p id={bodyId} className="mt-2 text-sm text-text-muted">
          {t('unsaved.body')}
        </p>
        {/* "Keep editing" comes first in DOM order, so it (not the destructive button) receives initial focus. */}
        <div className="mt-5 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <Button variant="secondary" onClick={onKeep}>
            {t('unsaved.keep')}
          </Button>
          <Button variant="danger" onClick={onDiscard}>
            {t('unsaved.discard')}
          </Button>
        </div>
      </div>
    </div>
  );
}
