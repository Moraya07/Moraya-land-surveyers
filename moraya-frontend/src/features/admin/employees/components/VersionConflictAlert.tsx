import { useEffect, useRef } from 'react';
import { Alert } from '../../../../components/ui/Alert';
import { Button } from '../../../../components/ui/Button';
import { useI18n } from '../../../../i18n';

interface VersionConflictAlertProps {
  /** True once the latest employee has been loaded and the user must choose what happens to their edits. */
  reloaded: boolean;
  reloading: boolean;
  /** The reload itself failed (network or server): the conflict stays and the user can try again. */
  reloadFailed: boolean;
  onReload: () => void;
  onKeep: () => void;
  onDiscard: () => void;
}

/**
 * Blocking inline alert for `409 VERSION_CONFLICT`. Step 1: Reload. Step 2: keep the user's edits on top of
 * the latest data, or discard them. Nothing is ever discarded without the user choosing it.
 */
export function VersionConflictAlert({
  reloaded,
  reloading,
  reloadFailed,
  onReload,
  onKeep,
  onDiscard,
}: VersionConflictAlertProps) {
  const { t } = useI18n();
  const rootRef = useRef<HTMLDivElement>(null);

  // The alert appears far from the Save button, and again after Reload: bring the keyboard to its first action.
  useEffect(() => {
    rootRef.current?.querySelector<HTMLElement>('button')?.focus();
  }, [reloaded]);

  return (
    <div ref={rootRef}>
      <Alert variant="danger" role="alert">
        <p>{reloaded ? t('edit.conflictReloaded') : t('err.conflict')}</p>
        {reloadFailed && !reloaded && <p className="mt-1">{t('err.load')}</p>}
        <div className="mt-3 flex flex-wrap gap-2">
          {reloaded ? (
            <>
              <Button onClick={onKeep}>{t('edit.conflictKeep')}</Button>
              <Button variant="secondary" onClick={onDiscard}>
                {t('edit.conflictDiscard')}
              </Button>
            </>
          ) : (
            <Button variant="secondary" loading={reloading} onClick={onReload}>
              {t('act.reload')}
            </Button>
          )}
        </div>
      </Alert>
    </div>
  );
}
