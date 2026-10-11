import { useCallback, useMemo } from 'react';
import { useSearchParams } from 'react-router-dom';
import type { EmployeeListParams, Role, StatusFilter } from '../types';

export const PAGE_SIZE = 20;
/** Fewer characters than this never reach the server. */
export const MIN_SEARCH_LENGTH = 2;
const MAX_QUERY_LENGTH = 100;
const MAX_PAGE = 10_000;

/** Shown in this order in the Status filter. */
export const STATUS_OPTIONS: readonly StatusFilter[] = ['active', 'all', 'inactive', 'revoked'];
export const ROLE_OPTIONS: readonly Role[] = ['worker', 'sub_admin', 'main_admin'];
export const SORT_FIELDS = ['srNo', 'name', 'employeeId', 'dateOfJoining'] as const;

export type SortField = (typeof SORT_FIELDS)[number];
export type SortDir = 'asc' | 'desc';
export interface SortState {
  field: SortField;
  dir: SortDir;
}

export const DEFAULT_STATUS: StatusFilter = 'active';
export const DEFAULT_SORT: SortState = { field: 'srNo', dir: 'asc' };

export interface EmployeeListState {
  /** Exactly as typed (so typing is never rewritten); trimmed and length-checked before it is sent. */
  q: string;
  status: StatusFilter;
  role: Role | null;
  sort: SortState;
  page: number;
}

const OWN_KEYS = ['q', 'status', 'role', 'sort', 'page'] as const;

/** URL -> state. Every invalid value falls back to its default. */
function parseState(sp: URLSearchParams): EmployeeListState {
  const [rawField, rawDir] = (sp.get('sort') ?? '').split(':');
  const field = SORT_FIELDS.find((f) => f === rawField);
  const sort: SortState = field && (rawDir === 'asc' || rawDir === 'desc') ? { field, dir: rawDir } : DEFAULT_SORT;

  const rawPage = sp.get('page') ?? '';
  const page = /^\d{1,5}$/.test(rawPage) ? Math.min(MAX_PAGE, Math.max(1, Number(rawPage))) : 1;

  const rawStatus = sp.get('status');
  const rawRole = sp.get('role');
  return {
    q: (sp.get('q') ?? '').slice(0, MAX_QUERY_LENGTH),
    status: STATUS_OPTIONS.find((s) => s === rawStatus) ?? DEFAULT_STATUS,
    role: ROLE_OPTIONS.find((r) => r === rawRole) ?? null,
    sort,
    page,
  };
}

/** State -> URL. Defaults are omitted; any other query parameter (such as `mock`) is kept untouched. */
function toSearchParams(base: URLSearchParams, state: EmployeeListState): URLSearchParams {
  const next = new URLSearchParams(base);
  for (const key of OWN_KEYS) next.delete(key);
  if (state.q.trim() !== '') next.set('q', state.q);
  if (state.status !== DEFAULT_STATUS) next.set('status', state.status);
  if (state.role) next.set('role', state.role);
  if (state.sort.field !== DEFAULT_SORT.field || state.sort.dir !== DEFAULT_SORT.dir) {
    next.set('sort', `${state.sort.field}:${state.sort.dir}`);
  }
  if (state.page > 1) next.set('page', String(state.page));
  return next;
}

function sameState(a: EmployeeListState, b: EmployeeListState): boolean {
  return (
    a.q === b.q &&
    a.status === b.status &&
    a.role === b.role &&
    a.sort.field === b.sort.field &&
    a.sort.dir === b.sort.dir &&
    a.page === b.page
  );
}

interface ChangeOptions {
  /** Keep the current page (only a page change itself does). Default: back to page 1. */
  keepPage?: boolean;
  /** Replace the history entry instead of adding one. */
  replace?: boolean;
}

/**
 * The list's whole state lives in the URL: `?q=&status=&role=&sort=&page=`.
 * Back/forward and refresh restore it; changing any filter or the sort returns to page 1.
 */
export function useEmployeeListParams() {
  const [searchParams, setSearchParams] = useSearchParams();
  const state = useMemo(() => parseState(searchParams), [searchParams]);

  const change = useCallback(
    (patch: Partial<EmployeeListState>, options: ChangeOptions = {}) => {
      const next: EmployeeListState = { ...state, ...patch };
      if (patch.page === undefined) next.page = options.keepPage ? state.page : 1;
      if (sameState(state, next)) return;
      setSearchParams(toSearchParams(searchParams, next), { replace: options.replace ?? false });
    },
    [state, searchParams, setSearchParams],
  );

  /** What goes to the API: the search is sent only from 2 characters up. */
  const apiParams = useMemo<EmployeeListParams>(() => {
    const q = state.q.trim();
    return {
      status: state.status,
      sort: `${state.sort.field}:${state.sort.dir}`,
      page: state.page,
      pageSize: PAGE_SIZE,
      ...(q.length >= MIN_SEARCH_LENGTH ? { q } : {}),
      ...(state.role ? { role: state.role } : {}),
    };
  }, [state]);

  /** True when a filter (search, status or role) differs from its default. Sort and page are not filters. */
  const filtersActive = state.q.trim() !== '' || state.status !== DEFAULT_STATUS || state.role !== null;

  /** A `?query` string for a real link that applies `patch` (page resets to 1). */
  const hrefFor = (patch: Partial<EmployeeListState>): string => {
    const next: EmployeeListState = { ...state, ...patch, page: patch.page ?? 1 };
    return toSearchParams(searchParams, next).toString();
  };

  const setPage = useCallback((page: number, replace = false) => change({ page }, { replace }), [change]);

  return {
    state,
    apiParams,
    filtersActive,
    hrefFor,
    setPage,
    setQuery: (q: string) => change({ q }),
    setStatus: (status: StatusFilter) => change({ status }),
    setRole: (role: Role | null) => change({ role }),
    /** Header click: a new column starts ascending; the current one flips. */
    toggleSort: (field: SortField) =>
      change({ sort: { field, dir: state.sort.field === field && state.sort.dir === 'asc' ? 'desc' : 'asc' } }),
    clearFilters: () => change({ q: '', status: DEFAULT_STATUS, role: null }),
  };
}
