import type { ReactNode } from 'react';

/** Neutral pill, e.g. one permission. Text only: never relies on colour. */
export function Chip({ children, className = '' }: { children: ReactNode; className?: string }) {
  return (
    <span
      className={`inline-flex items-center rounded-full border border-border bg-panel px-2.5 py-0.5 text-xs font-medium text-text ${className}`}
    >
      {children}
    </span>
  );
}
