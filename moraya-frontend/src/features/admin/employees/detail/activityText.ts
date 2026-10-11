import type { DictKey, Lang } from '../../../../i18n';
import { formatDate } from '../../../../lib/format';
import { PERMISSION_LABEL, PERMISSION_ORDER, ROLE_LABEL, STATUS_LABEL } from '../labels';
import type { ActivityChange } from '../types';

/** Action code -> translated sentence. Anything not listed shows the generic "Activity recorded". */
const ACTION_KEY: Record<string, DictKey> = {
  USER_CREATED: 'activity.USER_CREATED',
  USER_UPDATED: 'activity.USER_UPDATED',
  USER_AADHAAR_CHANGED: 'activity.USER_AADHAAR_CHANGED',
  USER_DEACTIVATED: 'activity.USER_DEACTIVATED',
  USER_REACTIVATED: 'activity.USER_REACTIVATED',
  USER_REVOKED: 'activity.USER_REVOKED',
  SUBADMIN_CREATED: 'activity.SUBADMIN_CREATED',
  SUBADMIN_PERMISSIONS_CHANGED: 'activity.SUBADMIN_PERMISSIONS_CHANGED',
  SUBADMIN_REVOKED: 'activity.SUBADMIN_REVOKED',
  AADHAAR_REVEALED: 'activity.AADHAAR_REVEALED',
};

/** The raw code is never returned for display: unknown codes get the generic label. */
export function actionKey(code: string): DictKey {
  return Object.prototype.hasOwnProperty.call(ACTION_KEY, code) ? (ACTION_KEY[code] ?? 'activity.unknown') : 'activity.unknown';
}

export type ActivityCategory = 'created' | 'edited' | 'off' | 'on' | 'access' | 'sensitive' | 'unknown';

const CATEGORY: Record<string, ActivityCategory> = {
  USER_CREATED: 'created',
  USER_UPDATED: 'edited',
  USER_AADHAAR_CHANGED: 'sensitive',
  USER_DEACTIVATED: 'off',
  USER_REACTIVATED: 'on',
  USER_REVOKED: 'off',
  SUBADMIN_CREATED: 'access',
  SUBADMIN_PERMISSIONS_CHANGED: 'access',
  SUBADMIN_REVOKED: 'off',
  AADHAAR_REVEALED: 'sensitive',
};

export function actionCategory(code: string): ActivityCategory {
  return Object.prototype.hasOwnProperty.call(CATEGORY, code) ? (CATEGORY[code] ?? 'unknown') : 'unknown';
}

// ---------------------------------------------------------------- fields

const FIELD_KEY: Record<string, DictKey> = {
  name: 'activity.field.name',
  employeeId: 'activity.field.employeeId',
  designation: 'activity.field.designation',
  dateOfBirth: 'activity.field.dateOfBirth',
  dateOfJoining: 'activity.field.dateOfJoining',
  role: 'activity.field.role',
  accountStatus: 'activity.field.accountStatus',
  permissions: 'activity.field.permissions',
};

export type KnownField = 'name' | 'employeeId' | 'designation' | 'dateOfBirth' | 'dateOfJoining' | 'role' | 'accountStatus' | 'permissions';

export function knownField(field: string): KnownField | null {
  return Object.prototype.hasOwnProperty.call(FIELD_KEY, field) ? (field as KnownField) : null;
}

/** Translation key for a known field, or null (the caller then shows `humanizeKey`). */
export function fieldKey(field: string): DictKey | null {
  const known = knownField(field);
  return known ? (FIELD_KEY[known] ?? null) : null;
}

/** "reportingManager" / "reporting_manager" -> "Reporting manager". Only letters, digits and spaces survive. */
export function humanizeKey(key: string): string {
  const spaced = key
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/[^A-Za-z0-9]+/g, ' ')
    .trim()
    .toLowerCase();
  if (!spaced) return '—';
  return spaced.charAt(0).toUpperCase() + spaced.slice(1);
}

// ---------------------------------------------------------------- safety filter

const FORBIDDEN_FIELD = /aadhaar|password|token/i;

/**
 * Client-side safety net, on top of the server's own sanitising: any change whose field name contains
 * "aadhaar", "password" or "token" (any case) is removed before anything is rendered. A change list that
 * ends up empty becomes null, so no empty "What changed" block is drawn.
 */
export function safeChanges(changes: readonly ActivityChange[] | null | undefined): ActivityChange[] | null {
  if (!changes) return null;
  const kept = changes.filter((c) => !FORBIDDEN_FIELD.test(c.field));
  return kept.length > 0 ? kept : null;
}

// ---------------------------------------------------------------- values

export const EMPTY = '—';

export type FormattedValue =
  | { kind: 'empty' }
  | { kind: 'text'; text: string; ltr?: boolean }
  | { kind: 'role'; role: keyof typeof ROLE_LABEL }
  | { kind: 'status'; status: keyof typeof STATUS_LABEL }
  | { kind: 'permissions'; labels: Array<{ key: string; labelKey: DictKey | null; text: string }> };

function isRole(v: string): v is keyof typeof ROLE_LABEL {
  return Object.prototype.hasOwnProperty.call(ROLE_LABEL, v);
}
function isStatus(v: string): v is keyof typeof STATUS_LABEL {
  return Object.prototype.hasOwnProperty.call(STATUS_LABEL, v);
}

/** Permissions arrive as one string: "a, b" (comma separated) or a JSON array string. Both are accepted. */
export function parseList(value: string): string[] {
  const trimmed = value.trim();
  if (trimmed.startsWith('[')) {
    try {
      const parsed: unknown = JSON.parse(trimmed);
      if (Array.isArray(parsed)) return parsed.filter((x): x is string => typeof x === 'string' && x.trim() !== '').map((x) => x.trim());
    } catch {
      /* not JSON: fall through to the comma split */
    }
  }
  return trimmed
    .split(/[,;]/)
    .map((x) => x.trim())
    .filter(Boolean);
}

/** Turns one side (`from` or `to`) of a change into something the row can draw. Never throws. */
export function formatChangeValue(field: string, value: string | null): FormattedValue {
  if (value === null || value.trim() === '') return { kind: 'empty' };
  switch (knownField(field)) {
    case 'dateOfBirth':
    case 'dateOfJoining': {
      const text = formatDate(value.trim());
      return text === EMPTY ? { kind: 'text', text: value } : { kind: 'text', text, ltr: true };
    }
    case 'employeeId':
      return { kind: 'text', text: value, ltr: true };
    case 'role': {
      const v = value.trim();
      return isRole(v) ? { kind: 'role', role: v } : { kind: 'text', text: humanizeKey(v) };
    }
    case 'accountStatus': {
      const v = value.trim();
      return isStatus(v) ? { kind: 'status', status: v } : { kind: 'text', text: humanizeKey(v) };
    }
    case 'permissions': {
      const known = new Set<string>(PERMISSION_ORDER);
      const codes = parseList(value);
      if (codes.length === 0) return { kind: 'empty' };
      // Known permissions in the standard display order first, then any unknown ones (humanized).
      const ordered = [...PERMISSION_ORDER.filter((p) => codes.includes(p)), ...codes.filter((c) => !known.has(c))];
      return {
        kind: 'permissions',
        labels: ordered.map((code) => {
          const labelKey = known.has(code) ? PERMISSION_LABEL[code as keyof typeof PERMISSION_LABEL] : null;
          return { key: code, labelKey, text: humanizeKey(code) };
        }),
      };
    }
    default:
      return { kind: 'text', text: value };
  }
}

// ---------------------------------------------------------------- time

/** Valid ISO timestamp -> same string (for `<time datetime>`); otherwise undefined so the attribute is left out. */
export function validIso(iso: string): string | undefined {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? undefined : d.toISOString();
}

const rtfCache = new Map<Lang, Intl.RelativeTimeFormat>();

function rtf(lang: Lang): Intl.RelativeTimeFormat {
  const hit = rtfCache.get(lang);
  if (hit) return hit;
  // "-u-nu-latn": Latin digits in Marathi too, like every other number in the app.
  const made = new Intl.RelativeTimeFormat(lang === 'mr' ? 'mr-IN-u-nu-latn' : 'en', { numeric: 'auto' });
  rtfCache.set(lang, made);
  return made;
}

/** "2 days ago" / "२ दिवसांपूर्वी"-style hint via Intl.RelativeTimeFormat. A timestamp in the future counts as "now". */
export function relativeTime(iso: string, now: number, lang: Lang): string {
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return '';
  const seconds = Math.max(0, Math.round((now - then) / 1000));
  const f = rtf(lang);
  if (seconds < 60) return f.format(0, 'second');
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return f.format(-minutes, 'minute');
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return f.format(-hours, 'hour');
  const days = Math.floor(hours / 24);
  if (days < 30) return f.format(-days, 'day');
  const months = Math.floor(days / 30);
  if (months < 12) return f.format(-months, 'month');
  return f.format(-Math.floor(days / 365), 'year');
}
