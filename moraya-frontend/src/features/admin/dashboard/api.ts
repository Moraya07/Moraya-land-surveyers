import { request } from '../../../lib/api';
import { dashboardSchema, type DashboardResponse, type Period } from './schema';

/**
 * One request for the whole page. The response is validated at this boundary, so a malformed
 * payload becomes the generic error state instead of a crash. Payloads are never logged.
 */
export async function fetchDashboard(period: Period): Promise<DashboardResponse> {
  // Dev only. Vite replaces the env check at build time, so the mock is dropped from production bundles.
  if (import.meta.env.VITE_USE_MOCK_DASHBOARD === 'true') {
    const { getMockDashboard } = await import('./mock');
    const scenario = new URLSearchParams(window.location.search).get('mock');
    return dashboardSchema.parse(await getMockDashboard(period, scenario));
  }
  const raw = await request<unknown>(`/admin/dashboard?period=${period}`);
  return dashboardSchema.parse(raw);
}
