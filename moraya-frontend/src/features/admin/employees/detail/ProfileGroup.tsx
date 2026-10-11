import { useId, type ReactNode } from 'react';

/** A titled card holding a definition list. */
export function ProfileGroup({ title, children }: { title: string; children: ReactNode }) {
  const headingId = useId();
  return (
    <section aria-labelledby={headingId} className="min-w-0 rounded-lg border border-border bg-surface">
      <h2 id={headingId} className="border-b border-border px-4 py-3 text-base font-semibold">
        {title}
      </h2>
      <dl className="divide-y divide-border px-4">{children}</dl>
    </section>
  );
}

/** One term/description pair. Stacks on phones, two columns from `sm` up. */
export function ProfileRow({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="grid grid-cols-1 gap-1 py-3 sm:grid-cols-[10rem_minmax(0,1fr)] sm:gap-4">
      <dt className="text-sm text-text-muted">{label}</dt>
      <dd className="min-w-0 break-words text-sm text-text">{children}</dd>
    </div>
  );
}

export const EMPTY_VALUE = '—';
