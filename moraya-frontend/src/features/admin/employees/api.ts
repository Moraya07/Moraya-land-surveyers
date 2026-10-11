import { request } from '../../../lib/api';
import { ApiError } from '../../../lib/errors';
import { parseResponse, schemas } from './schemas';
import type {
  ActivityResponse,
  ChangePermissionsInput,
  ChangeRoleInput,
  ChangeStatusInput,
  CreateEmployeeInput,
  CreateEmployeeResult,
  EmployeeDetail,
  EmployeeListParams,
  EmployeeListResponse,
  RevealAadhaarResult,
  UpdateEmployeeInput,
} from './types';

const BASE = '/admin/employees';

type Method = 'GET' | 'POST' | 'PUT' | 'PATCH';

/**
 * One transport for every endpoint. With VITE_USE_MOCK_EMPLOYEES=true (dev only) the call is answered
 * by the in-memory mock. The condition is written inline with `import.meta.env.DEV` so that production
 * builds drop the branch, and with it the dynamic import, entirely.
 */
async function call(method: Method, path: string, body?: unknown, signal?: AbortSignal): Promise<unknown> {
  if (import.meta.env.DEV && import.meta.env.VITE_USE_MOCK_EMPLOYEES === 'true') {
    const { handleMockRequest } = await import('./mock/handlers');
    const res = await handleMockRequest({ method, path, body });
    if (signal?.aborted) throw new DOMException('Aborted', 'AbortError'); // the mock cannot cancel mid-flight; it drops the answer
    if (res.error) throw new ApiError(res.status, res.error.code, res.error.retryAfterSeconds, res.error.fields);
    return res.body;
  }
  return request<unknown>(path, { method, body, ...(signal ? { signal } : {}) });
}

function query(params: Record<string, string | number | undefined>): string {
  const sp = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== '') sp.set(key, String(value));
  }
  const s = sp.toString();
  return s ? `?${s}` : '';
}

const idPath = (id: string) => `${BASE}/${encodeURIComponent(id)}`;

export const employeesApi = {
  async list(params: EmployeeListParams, signal?: AbortSignal): Promise<EmployeeListResponse> {
    const q = query({
      q: params.q?.trim(),
      status: params.status && params.status !== 'all' ? params.status : undefined,
      role: params.role,
      sort: params.sort,
      page: params.page,
      pageSize: params.pageSize,
    });
    return parseResponse(schemas.list, await call('GET', `${BASE}${q}`, undefined, signal));
  },

  async get(id: string): Promise<EmployeeDetail> {
    return parseResponse(schemas.employee, await call('GET', idPath(id))).employee;
  },

  async create(input: CreateEmployeeInput): Promise<CreateEmployeeResult> {
    return parseResponse(schemas.create, await call('POST', BASE, input));
  },

  async update(id: string, input: UpdateEmployeeInput): Promise<EmployeeDetail> {
    return parseResponse(schemas.employee, await call('PATCH', idPath(id), input)).employee;
  },

  async changeStatus(id: string, input: ChangeStatusInput): Promise<EmployeeDetail> {
    return parseResponse(schemas.employee, await call('POST', `${idPath(id)}/status`, input)).employee;
  },

  async changeRole(id: string, input: ChangeRoleInput): Promise<EmployeeDetail> {
    return parseResponse(schemas.employee, await call('PUT', `${idPath(id)}/role`, input)).employee;
  },

  async changePermissions(id: string, input: ChangePermissionsInput): Promise<EmployeeDetail> {
    return parseResponse(schemas.employee, await call('PUT', `${idPath(id)}/permissions`, input)).employee;
  },

  async revealAadhaar(id: string): Promise<RevealAadhaarResult> {
    return parseResponse(schemas.reveal, await call('POST', `${idPath(id)}/aadhaar/reveal`));
  },

  async activity(id: string, page: number, pageSize: number): Promise<ActivityResponse> {
    return parseResponse(schemas.activity, await call('GET', `${idPath(id)}/activity${query({ page, pageSize })}`));
  },
};
