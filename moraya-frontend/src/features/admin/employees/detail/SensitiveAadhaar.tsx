import { useQueryClient } from '@tanstack/react-query';
import { useCallback, useEffect, useRef, useState } from 'react';
import { useLocation } from 'react-router-dom';
import { Alert } from '../../../../components/ui/Alert';
import { Button } from '../../../../components/ui/Button';
import { ConfirmDialog } from '../../../../components/ui/ConfirmDialog';
import { useI18n, type DictKey } from '../../../../i18n';
import { ApiError } from '../../../../lib/errors';
import { formatAadhaar } from '../aadhaar';
import { mapEmployeeError } from '../errors';
import { employeeKeys, useRevealAadhaar } from '../hooks';
import { useAutoHide } from './useAutoHide';

const DEFAULT_SECONDS = 30;
const MAX_SECONDS = 300;

interface Props {
  employeeId: string;
  /** 'XXXX XXXX 1234', or '' when none is on file. */
  masked: string;
  /** From the server's capabilities. */
  canReveal: boolean;
  /** Any change to these means the employee was modified: a revealed number is hidden at once. */
  version: number;
  updatedAt: string;
}

interface Revealed {
  digits: string;
  seconds: number;
}

interface Problem {
  key: DictKey;
  params?: Record<string, number>;
}

type Announcement = '' | 'shown' | 'hidden';

/**
 * The only place in the app that ever holds a full Aadhaar number, and only in this component's state.
 * It is never written to the query cache, URL, title, storage, console, a toast or an error message.
 * It is cleared on: Hide, the timer, any navigation (tab or route), unmount, the page being away for more
 * than 10 s, and any change to the employee. There is deliberately no copy button.
 */
export function SensitiveAadhaar({ employeeId, masked, canReveal, version, updatedAt }: Props) {
  const { t } = useI18n();
  const queryClient = useQueryClient();
  const reveal = useRevealAadhaar(employeeId);
  const { key: locationKey } = useLocation();

  const [confirmOpen, setConfirmOpen] = useState(false);
  const [revealed, setRevealed] = useState<Revealed | null>(null);
  const [problem, setProblem] = useState<Problem | null>(null);
  const [announcement, setAnnouncement] = useState<Announcement>('');

  const rootRef = useRef<HTMLDivElement>(null);
  const visibleRef = useRef(false); // mirrors `revealed !== null` for callbacks
  const focusButtonRef = useRef(false); // move focus to the Reveal/Hide button after the next render
  const stamp = `${version}:${updatedAt}`;
  const stampRef = useRef(stamp);

  const hide = useCallback(() => {
    if (!visibleRef.current) return;
    visibleRef.current = false;
    // If the Hide button had focus it is about to disappear: hand focus to the Reveal button.
    if (rootRef.current?.contains(document.activeElement)) focusButtonRef.current = true;
    setRevealed(null);
    setAnnouncement('hidden');
  }, []);

  const remaining = useAutoHide({
    active: revealed !== null,
    seconds: revealed?.seconds ?? DEFAULT_SECONDS,
    onHide: hide,
  });

  // The employee changed (an action, an edit, a reload): never keep a number on screen across that.
  useEffect(() => {
    if (stampRef.current === stamp) return;
    stampRef.current = stamp;
    hide();
  }, [stamp, hide]);

  // Any navigation (tab switch, another route, another employee) hides it.
  const lastLocationKey = useRef(locationKey);
  useEffect(() => {
    if (lastLocationKey.current === locationKey) return;
    lastLocationKey.current = locationKey;
    hide();
  }, [locationKey, hide]);

  // Focus management after Reveal / Hide / a failed attempt.
  useEffect(() => {
    if (!focusButtonRef.current) return;
    focusButtonRef.current = false;
    rootRef.current?.querySelector<HTMLElement>('[data-aadhaar-button]')?.focus();
  }, [revealed, problem, reveal.isPending]);

  // The announcement is read once; it is cleared a few seconds later so it is not re-read when browsing.
  useEffect(() => {
    if (announcement === '') return;
    const timer = setTimeout(() => setAnnouncement(''), 4000);
    return () => clearTimeout(timer);
  }, [announcement]);

  const startReveal = () => {
    const requestStamp = stampRef.current;
    setConfirmOpen(false);
    setProblem(null);
    reveal.mutate(undefined, {
      onSuccess: (result) => {
        const digits = result.aadhaar;
        const seconds =
          Number.isFinite(result.expiresInSeconds) && result.expiresInSeconds > 0
            ? Math.min(result.expiresInSeconds, MAX_SECONDS)
            : DEFAULT_SECONDS;
        reveal.reset(); // drop the number from the mutation state right away
        focusButtonRef.current = true;
        if (stampRef.current !== requestStamp) return; // the employee changed while waiting
        visibleRef.current = true;
        setRevealed({ digits, seconds });
        setAnnouncement('shown');
      },
      onError: (error) => {
        const mapped = mapEmployeeError(error, 'load');
        setProblem({ key: mapped.messageKey, ...(mapped.messageParams ? { params: mapped.messageParams } : {}) });
        focusButtonRef.current = true;
        if (error instanceof ApiError && (error.code === 'FORBIDDEN' || error.code === 'NOT_FOUND')) {
          // The permission or the record changed: reload the employee so the page reflects it.
          void queryClient.invalidateQueries({ queryKey: employeeKeys.detail(employeeId) });
        }
        reveal.reset();
      },
    });
  };

  if (masked === '') {
    return <span className="text-text-muted">{t('aadhaar.notProvided')}</span>;
  }

  const aadhaarName = t('field.aadhaar');

  return (
    <div ref={rootRef} className="space-y-2">
      {revealed ? (
        <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
          <span
            data-sensitive
            dir="ltr"
            translate="no"
            className="text-base font-semibold tabular-nums tracking-wider text-text"
          >
            {formatAadhaar(revealed.digits)}
          </span>
          {/* Visual only: a per-second countdown must not be announced. */}
          <span aria-hidden="true" className="text-sm tabular-nums text-text-muted">
            {t('aadhaar.hidesIn', { n: remaining })}
          </span>
          <Button
            variant="secondary"
            data-aadhaar-button
            aria-label={`${t('act.hide')}: ${aadhaarName}`}
            onClick={hide}
          >
            {t('act.hide')}
          </Button>
        </div>
      ) : (
        <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
          <span dir="ltr" className="text-base tabular-nums tracking-wider text-text">
            {masked}
          </span>
          {canReveal && (
            <Button
              variant="secondary"
              data-aadhaar-button
              loading={reveal.isPending}
              disabled={reveal.isPending}
              aria-label={`${t('act.reveal')}: ${aadhaarName}`}
              onClick={() => {
                setProblem(null);
                setConfirmOpen(true);
              }}
            >
              {t('act.reveal')}
            </Button>
          )}
        </div>
      )}

      {problem && (
        <Alert variant="danger" role="alert">
          {t(problem.key, problem.params)}
        </Alert>
      )}

      {/* One short message when it is shown and one when it is hidden. Never contains the number. */}
      <div aria-live="polite" aria-atomic="true" className="sr-only">
        {announcement === 'shown' ? t('aadhaar.shownAnnounce') : announcement === 'hidden' ? t('aadhaar.hiddenAnnounce') : ''}
      </div>

      <ConfirmDialog
        open={confirmOpen}
        title={aadhaarName}
        body={<p>{t('confirm.revealAadhaar')}</p>}
        confirmLabel={t('act.reveal')}
        onConfirm={startReveal}
        onClose={() => setConfirmOpen(false)}
      />
    </div>
  );
}
