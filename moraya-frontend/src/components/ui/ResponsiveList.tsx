import { DataTable, type Column } from './DataTable';

interface ResponsiveListProps<T> {
  columns: Column<T>[];
  rows: readonly T[];
  getKey: (row: T) => string;
  caption: string;
}

/** A compact table from 768px up, stacked cards below (never a shrunk table). */
export function ResponsiveList<T>({ columns, rows, getKey, caption }: ResponsiveListProps<T>) {
  const primary = columns.find((c) => c.primary) ?? columns[0];
  const rest = columns.filter((c) => c !== primary);

  return (
    <>
      <div className="hidden md:block">
        <DataTable columns={columns} rows={rows} getKey={getKey} caption={caption} />
      </div>
      <ul aria-label={caption} className="space-y-2 md:hidden">
        {rows.map((row) => (
          <li key={getKey(row)} className="rounded-md border border-border bg-surface p-3">
            {primary && <div className="min-w-0 break-words font-medium">{primary.render(row)}</div>}
            <dl className="mt-2 grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1.5 text-sm">
              {rest.map((c) => (
                <div key={c.key} className="contents">
                  <dt className="text-text-muted">{c.header}</dt>
                  <dd className="min-w-0 break-words text-right tabular-nums">{c.render(row)}</dd>
                </div>
              ))}
            </dl>
          </li>
        ))}
      </ul>
    </>
  );
}
