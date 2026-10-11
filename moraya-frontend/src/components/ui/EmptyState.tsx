import type { ReactNode } from 'react';

/** A useful message (and optional action) instead of a bare "No data". */
export function EmptyState({ message, action }: { message: string; action?: ReactNode }) {
  return (
    <div className="rounded-md border border-dashed border-border px-4 py-6 text-center text-sm text-text-muted">
      <p>{message}</p>
      {action && <div className="mt-3">{action}</div>}
    </div>
  );
}
