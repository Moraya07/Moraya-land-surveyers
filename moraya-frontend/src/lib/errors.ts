import type { DictKey } from '../i18n/en';

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly retryAfterSeconds?: number;
  /** Per-field MACHINE codes (e.g. { name: 'REQUIRED' }). Never server prose. */
  readonly fields?: Readonly<Record<string, string>>;

  constructor(status: number, code: string, retryAfterSeconds?: number, fields?: Record<string, string>) {
    super(code); // server message is intentionally never kept or shown
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
    this.retryAfterSeconds = retryAfterSeconds;
    this.fields = fields;
  }
}

export class NetworkError extends Error {
  constructor() {
    super('NETWORK_ERROR');
    this.name = 'NetworkError';
  }
}

/** Maps any failure to a dictionary key. Raw server messages are never displayed. */
export function errorToKey(error: unknown): DictKey {
  if (error instanceof ApiError) {
    switch (error.code) {
      case 'INVALID_CREDENTIALS':
      case 'UNAUTHENTICATED':
        return 'err.invalid';
      case 'ACCOUNT_INACTIVE':
        return 'err.inactive';
      case 'ACCOUNT_REVOKED':
        return 'err.revoked';
      case 'VALIDATION_ERROR':
        return 'err.validation';
      case 'RATE_LIMITED':
        return 'err.rateLimited';
    }
    if (error.status === 401) return 'err.invalid';
    if (error.status >= 500) return 'err.network';
    return 'err.generic';
  }
  if (error instanceof NetworkError) return 'err.network';
  return 'err.generic';
}
