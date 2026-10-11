import { ApiError, NetworkError } from './errors';

const BASE = '/api';
const NO_REFRESH_PATHS = new Set(['/auth/login', '/auth/refresh', '/auth/logout', '/auth/forgot-password']);
const DEFAULT_RETRY_SECONDS = 30;

interface RequestOptions {
  method?: 'GET' | 'POST' | 'PUT' | 'PATCH';
  body?: unknown;
  /** Lets the caller cancel the request (TanStack Query passes one, so a changed query aborts the old call). */
  signal?: AbortSignal;
}

let onSessionExpired: (() => void) | null = null;
/** Registered once at app start: clears the session cache and routes to /login. */
export function setSessionExpiredHandler(handler: () => void): void {
  onSessionExpired = handler;
}

async function send(path: string, { method = 'GET', body, signal }: RequestOptions): Promise<Response> {
  try {
    return await fetch(`${BASE}${path}`, {
      method,
      credentials: 'include',
      headers: {
        'X-Requested-With': 'moraya-web',
        ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body !== undefined ? JSON.stringify(body) : undefined,
      ...(signal ? { signal } : {}),
    });
  } catch (error) {
    // A cancelled request is not a network failure: let the caller see the abort.
    if (error instanceof DOMException && error.name === 'AbortError') throw error;
    throw new NetworkError();
  }
}

// Single-flight: parallel 401s share one refresh call.
let refreshInFlight: Promise<boolean> | null = null;
function refreshSession(): Promise<boolean> {
  if (!refreshInFlight) {
    refreshInFlight = send('/auth/refresh', { method: 'POST' })
      .then((res) => res.ok)
      .catch(() => false)
      .finally(() => {
        refreshInFlight = null;
      });
  }
  return refreshInFlight;
}

async function toApiError(res: Response): Promise<ApiError> {
  let code = 'INTERNAL_ERROR';
  let retry: number | undefined;
  let fields: Record<string, string> | undefined;
  try {
    const body: unknown = await res.json();
    if (typeof body === 'object' && body !== null && 'error' in body) {
      const err = (body as { error: unknown }).error;
      if (typeof err === 'object' && err !== null) {
        const { code: c, retryAfterSeconds, fields: f } = err as {
          code?: unknown;
          retryAfterSeconds?: unknown;
          fields?: unknown;
        };
        if (typeof c === 'string') code = c;
        if (typeof retryAfterSeconds === 'number' && retryAfterSeconds > 0) retry = retryAfterSeconds;
        fields = readFieldCodes(f);
      }
    }
  } catch {
    /* non-JSON error body: keep defaults */
  }
  if (res.status === 429 && retry === undefined) retry = DEFAULT_RETRY_SECONDS;
  return new ApiError(res.status, code, retry, fields);
}

/** Keeps only { field: MACHINE_CODE } pairs. Anything else (prose, nested data) is dropped. */
function readFieldCodes(value: unknown): Record<string, string> | undefined {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return undefined;
  const out: Record<string, string> = {};
  for (const [key, v] of Object.entries(value)) {
    if (typeof v === 'string' && /^[A-Z_]{1,40}$/.test(v)) out[key] = v;
  }
  return Object.keys(out).length > 0 ? out : undefined;
}

export async function request<T>(path: string, options: RequestOptions = {}): Promise<T> {
  let res = await send(path, options);

  if (res.status === 401 && !NO_REFRESH_PATHS.has(path)) {
    if (await refreshSession()) res = await send(path, options); // retry once
    if (res.status === 401 && path !== '/auth/me') onSessionExpired?.();
  }

  if (!res.ok) throw await toApiError(res);
  if (res.status === 204) return undefined as unknown as T;
  return (await res.json()) as T;
}
