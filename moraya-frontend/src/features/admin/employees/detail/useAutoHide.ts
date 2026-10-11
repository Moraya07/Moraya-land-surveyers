import { useEffect, useRef, useState } from 'react';

/** The page may stay in the background (tab hidden or window blurred) for this long before the value is hidden. */
export const BACKGROUND_LIMIT_MS = 10_000;

interface Options {
  /** True while something sensitive is on screen. Everything below runs only while this is true. */
  active: boolean;
  /** How long it may stay visible. */
  seconds: number;
  /** Called once when the time is up or the page was away for more than BACKGROUND_LIMIT_MS. */
  onHide: () => void;
}

/**
 * Countdown plus "the user left" detection for a value that must not stay on screen.
 *
 * - The deadline is a wall-clock time, so a throttled background timer cannot make it last longer.
 * - A tab switch or window blur starts a 10 s timer; coming back earlier cancels it.
 * - Every timer and listener is removed when `active` turns false and when the component unmounts.
 *
 * Returns the whole seconds left (for display only).
 */
export function useAutoHide({ active, seconds, onHide }: Options): number {
  const [remaining, setRemaining] = useState(seconds);
  const hideRef = useRef(onHide);
  useEffect(() => {
    hideRef.current = onHide;
  });

  useEffect(() => {
    if (!active) return;

    const deadline = Date.now() + seconds * 1000;
    setRemaining(seconds);

    let done = false;
    let awaySince: number | null = null;
    let awayTimer: ReturnType<typeof setTimeout> | undefined;

    const hide = () => {
      if (done) return;
      done = true;
      hideRef.current();
    };

    const tick = () => {
      const left = Math.ceil((deadline - Date.now()) / 1000);
      if (left <= 0) hide();
      else setRemaining(left);
    };

    const leave = () => {
      if (awaySince !== null) return;
      awaySince = Date.now();
      awayTimer = setTimeout(hide, BACKGROUND_LIMIT_MS);
    };

    const back = () => {
      if (awaySince === null) return;
      const away = Date.now() - awaySince;
      awaySince = null;
      clearTimeout(awayTimer);
      if (away > BACKGROUND_LIMIT_MS) hide();
      else tick();
    };

    const onVisibility = () => {
      if (document.visibilityState === 'hidden') leave();
      else if (document.hasFocus()) back();
    };

    const interval = setInterval(tick, 250);
    document.addEventListener('visibilitychange', onVisibility);
    window.addEventListener('blur', leave);
    window.addEventListener('focus', back);

    return () => {
      done = true;
      clearInterval(interval);
      clearTimeout(awayTimer);
      document.removeEventListener('visibilitychange', onVisibility);
      window.removeEventListener('blur', leave);
      window.removeEventListener('focus', back);
    };
  }, [active, seconds]);

  return remaining;
}
