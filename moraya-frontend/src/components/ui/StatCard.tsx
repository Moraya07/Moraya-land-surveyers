import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';

interface StatCardProps {
  label: string;
  children: ReactNode;
  /** Makes the whole card a link. */
  to?: string;
  /** Right-align the value (money). */
  alignEnd?: boolean;
}

export function StatCard({ label, children, to, alignEnd = false }: StatCardProps) {
  const body = (
    <>
      <p className="text-sm text-text-muted">{label}</p>
      <p className={`mt-1 text-xl font-semibold tabular-nums ${alignEnd ? 'text-right' : ''}`}>{children}</p>
    </>
  );
  const box = 'block h-full min-w-0 rounded-lg border border-border bg-surface p-4';
  if (to) {
    return (
      <Link to={to} className={`${box} transition-colors hover:border-field hover:bg-panel`}>
        {body}
      </Link>
    );
  }
  return <div className={box}>{body}</div>;
}
