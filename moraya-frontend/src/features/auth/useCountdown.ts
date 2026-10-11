import { useCallback, useEffect, useState } from 'react';

export function useCountdown() {
  const [until, setUntil] = useState<number | null>(null);
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (until === null) return;
    const id = window.setInterval(() => {
      const n = Date.now();
      setNow(n);
      if (n >= until) setUntil(null);
    }, 1000);
    return () => window.clearInterval(id);
  }, [until]);

  const start = useCallback((seconds: number) => {
    const n = Date.now();
    setNow(n);
    setUntil(n + seconds * 1000);
  }, []);

  const remaining = until === null ? 0 : Math.max(0, Math.ceil((until - now) / 1000));
  return { remaining, start };
}
