import type { DictKey } from '../../../i18n';
import { ApiError, NetworkError } from '../../../lib/errors';
import { ApiShapeError } from './schemas';

export interface MappedEmployeeError {
  messageKey: DictKey;
  /** Values for `{n}`-style placeholders in the message. */
  messageParams?: Record<string, number>;
  /** fieldName -> dictionary key. Only present when the server named fields (or a uniqueness error maps to one). */
  fieldErrors?: Record<string, DictKey>;
}

const FIELD_CODE_KEY: Record<string, DictKey> = {
  REQUIRED: 'fieldErr.REQUIRED',
  INVALID_FORMAT: 'fieldErr.INVALID_FORMAT',
  TOO_SHORT: 'fieldErr.TOO_SHORT',
  TOO_LONG: 'fieldErr.TOO_LONG',
  FUTURE_DATE: 'fieldErr.FUTURE_DATE',
  PAST_REQUIRED: 'fieldErr.PAST_REQUIRED',
  BEFORE_DOB: 'fieldErr.BEFORE_DOB',
  CHECKSUM: 'fieldErr.CHECKSUM',
  AT_LEAST_ONE: 'fieldErr.AT_LEAST_ONE',
  NOT_ALLOWED: 'fieldErr.NOT_ALLOWED',
};

/** Unknown field codes become the generic "fieldErr.invalid". */
export function fieldCodeToKey(code: string): DictKey {
  return FIELD_CODE_KEY[code] ?? 'fieldErr.invalid';
}

/**
 * Turns any failure into translated-text keys. Raw server messages are never used.
 * `kind` picks the generic fallback: 'load' for reads, 'save' for writes.
 */
export function mapEmployeeError(error: unknown, kind: 'load' | 'save' = 'load'): MappedEmployeeError {
  const generic: DictKey = kind === 'save' ? 'err.save' : 'err.load';

  if (error instanceof NetworkError) return { messageKey: 'err.network' };
  if (error instanceof ApiShapeError) return { messageKey: generic };
  if (!(error instanceof ApiError)) return { messageKey: generic };

  switch (error.code) {
    case 'VALIDATION_ERROR': {
      const fieldErrors: Record<string, DictKey> = {};
      for (const [field, code] of Object.entries(error.fields ?? {})) fieldErrors[field] = fieldCodeToKey(code);
      return Object.keys(fieldErrors).length > 0
        ? { messageKey: 'err.validation', fieldErrors }
        : { messageKey: 'err.validation' };
    }
    case 'EMPLOYEE_ID_TAKEN':
      return { messageKey: 'err.idTaken', fieldErrors: { employeeId: 'err.idTaken' } };
    case 'EMAIL_TAKEN':
      return { messageKey: 'err.emailTaken', fieldErrors: { loginEmail: 'err.emailTaken' } };
    case 'AADHAAR_TAKEN':
      return { messageKey: 'err.aadhaarTaken', fieldErrors: { aadhaar: 'err.aadhaarTaken' } };
    case 'VERSION_CONFLICT':
      return { messageKey: 'err.conflict' };
    case 'INVALID_STATE':
      return { messageKey: 'err.invalidState' };
    case 'LAST_MAIN_ADMIN_PROTECTED':
      return { messageKey: 'protected.main' };
    case 'FORBIDDEN':
      return { messageKey: 'err.forbidden' };
    case 'NOT_FOUND':
      return { messageKey: 'err.notFound' };
    case 'RATE_LIMITED':
      return { messageKey: 'err.rateLimited', messageParams: { n: error.retryAfterSeconds ?? 30 } };
    default:
      break;
  }

  // Status-based fallbacks for codes the contract does not name.
  if (error.status === 403) return { messageKey: 'err.forbidden' };
  if (error.status === 404) return { messageKey: 'err.notFound' };
  if (error.status === 429) return { messageKey: 'err.rateLimited', messageParams: { n: error.retryAfterSeconds ?? 30 } };
  return { messageKey: generic };
}
