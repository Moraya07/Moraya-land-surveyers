/** Placeholder block. Decorative: pair it with a labelled status region. */
export function Skeleton({ className = '' }: { className?: string }) {
  return <div aria-hidden="true" className={`rounded bg-panel motion-safe:animate-pulse ${className}`} />;
}
