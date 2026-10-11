import type { ReactNode } from 'react';

export interface Column<T> {
  key: string;
  header: string;
  render: (row: T) => ReactNode;
  align?: 'end';
  /** Used as the card title when the list collapses to cards on small screens. */
  primary?: boolean;
}

interface DataTableProps<T> {
  columns: Column<T>[];
  rows: readonly T[];
  getKey: (row: T) => string;
  /** Screen-reader name for the table. */
  caption: string;
}

export function DataTable<T>({ columns, rows, getKey, caption }: DataTableProps<T>) {
  return (
    <div className="overflow-x-auto rounded-md border border-border">
      <table className="w-full text-sm">
        <caption className="sr-only">{caption}</caption>
        <thead className="bg-panel text-xs text-text-muted">
          <tr>
            {columns.map((c) => (
              <th
                key={c.key}
                scope="col"
                className={`px-3 py-2 font-medium ${c.align === 'end' ? 'text-right' : 'text-left'}`}
              >
                {c.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={getKey(row)} className="border-t border-border">
              {columns.map((c) => (
                <td key={c.key} className={`px-3 py-2.5 align-top ${c.align === 'end' ? 'text-right tabular-nums' : ''}`}>
                  {c.render(row)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
