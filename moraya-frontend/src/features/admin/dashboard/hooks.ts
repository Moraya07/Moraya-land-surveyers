import { keepPreviousData, useQuery } from '@tanstack/react-query';
import { ApiError } from '../../../lib/errors';
import { fetchDashboard } from './api';
import type { Period } from './schema';

export const PERIODS: readonly Period[] = ['today', 'this_week', 'this_month', 'previous_month'];

/** Invalid or missing values fall back to this month. */
export function parsePeriod(value: string | null): Period {
  return PERIODS.find((p) => p === value) ?? 'this_month';
}

/** In-memory cache only (no persister). No polling; the period switch keeps the old data on screen. */
export function useDashboard(period: Period) {
  return useQuery({
    queryKey: ['admin', 'dashboard', period],
    queryFn: () => fetchDashboard(period),
    staleTime: 60_000,
    gcTime: 5 * 60_000,
    refetchOnWindowFocus: false,
    retry: (failureCount, error) => !(error instanceof ApiError && error.status === 403) && failureCount < 1,
    placeholderData: keepPreviousData,
  });
}
