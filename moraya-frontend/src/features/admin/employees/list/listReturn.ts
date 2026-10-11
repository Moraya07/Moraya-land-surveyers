import { useLocation } from 'react-router-dom';

/** Router state attached to every link from the list to an employee, so "Back" can restore the list view. */
export interface ListReturnState {
  listSearch: string;
}

/** The list's own query string (?q=&status=&role=&sort=&page=), as router state for links and navigate(). */
export function useListLinkState(): ListReturnState {
  const { search } = useLocation();
  return { listSearch: search };
}

const KEPT_KEYS = ['q', 'status', 'role', 'sort', 'page', 'mock'] as const;

/**
 * Reads the state back on the detail page. Only the list's own parameters survive, so whatever is in
 * history state can never inject anything else into a link.
 */
export function readListSearch(state: unknown): string {
  if (typeof state !== 'object' || state === null) return '';
  const raw = (state as { listSearch?: unknown }).listSearch;
  if (typeof raw !== 'string' || raw.length > 600) return '';
  const source = new URLSearchParams(raw);
  const next = new URLSearchParams();
  for (const key of KEPT_KEYS) {
    const value = source.get(key);
    if (value !== null) next.set(key, value);
  }
  const s = next.toString();
  return s ? `?${s}` : '';
}
