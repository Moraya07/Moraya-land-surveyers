import type { Context } from 'hono';

export type ErrorCode =
  | 'VALIDATION_ERROR'
  | 'INVALID_CREDENTIALS'
  | 'UNAUTHENTICATED'
  | 'ACCOUNT_INACTIVE'
  | 'ACCOUNT_REVOKED'
  | 'FORBIDDEN'
  | 'RATE_LIMITED'
  | 'NOT_FOUND'
  | 'INTERNAL_ERROR';

type ErrStatus = 400 | 401 | 403 | 404 | 429 | 500;

// Fixed, generic messages. Upstream/internal details never reach the client.
const MESSAGES: Record<ErrorCode, string> = {
  VALIDATION_ERROR: 'The request is invalid.',
  INVALID_CREDENTIALS: 'Incorrect email or password.',
  UNAUTHENTICATED: 'Authentication required.',
  ACCOUNT_INACTIVE: 'This account is inactive.',
  ACCOUNT_REVOKED: 'Access to this account has been revoked.',
  FORBIDDEN: 'You do not have permission to do this.',
  RATE_LIMITED: 'Too many attempts. Try again later.',
  NOT_FOUND: 'Not found.',
  INTERNAL_ERROR: 'Something went wrong.',
};

export class AppError extends Error {
  constructor(
    readonly status: ErrStatus,
    readonly code: ErrorCode,
    readonly retryAfterSeconds?: number,
  ) {
    super(code);
    this.name = 'AppError';
  }
}

export function jsonError(c: Context, err: AppError) {
  if (err.retryAfterSeconds !== undefined) c.header('Retry-After', String(err.retryAfterSeconds));
  return c.json(
    {
      error: {
        code: err.code,
        message: MESSAGES[err.code],
        ...(err.retryAfterSeconds !== undefined ? { retryAfterSeconds: err.retryAfterSeconds } : {}),
      },
    },
    err.status,
  );
}
