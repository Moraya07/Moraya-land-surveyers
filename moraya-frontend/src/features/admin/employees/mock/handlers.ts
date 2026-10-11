import { aadhaarProblem } from '../aadhaar';
import { PERMISSION_ORDER } from '../labels';
import type {
  ActivityChange,
  EmployeeCapabilities,
  EmployeeDetail,
  EmployeeListItem,
  Permission,
  RowCapabilities,
} from '../types';
import type { StoredEmployee } from './seed';
import {
  addAudit,
  checkRevealRate,
  currentScenario,
  findEmployee,
  getActor,
  getStore,
  takeConflictTrigger,
  takeForcedError,
  type Actor,
} from './store';

// Dev-only fake of /api/admin/employees. Behaviour follows the API contract in the Employees prompt.
// Aadhaar values here are fake and are never logged.

export interface MockRequest {
  method: string;
  /** Path under /api, query string included (e.g. "/admin/employees?page=2"). */
  path: string;
  body?: unknown;
}
export interface MockError {
  code: string;
  retryAfterSeconds?: number;
  fields?: Record<string, string>;
}
export interface MockResponse {
  status: number;
  body?: unknown;
  error?: MockError;
}

type Rec = Record<string, unknown>;
const isRec = (v: unknown): v is Rec => typeof v === 'object' && v !== null && !Array.isArray(v);

const ok = (status: number, body: unknown): MockResponse => ({ status, body });
const fail = (status: number, code: string, extra: Omit<MockError, 'code'> = {}): MockResponse => ({
  status,
  error: { code, ...extra },
});
const invalid = (fields: Record<string, string>): MockResponse => fail(400, 'VALIDATION_ERROR', { fields });

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

export async function handleMockRequest(req: MockRequest): Promise<MockResponse> {
  const scenario = currentScenario();
  await sleep(scenario === 'slow' ? 1500 : 120 + Math.random() * 180);
  if (scenario === 'error') return fail(500, 'INTERNAL_ERROR');
  if (scenario === 'malformed') return ok(200, { unexpected: true });
  if (req.method !== 'GET') {
    const forced = takeForcedError();
    if (forced) return forcedResponse(forced);
  }
  const res = route(req, getActor(scenario));
  // Round-trip through JSON so the client can never hold a reference into the mock store.
  return res.body === undefined ? res : { ...res, body: JSON.parse(JSON.stringify(res.body)) as unknown };
}

/** Responses for the dev-only `forceNextError` trigger. */
function forcedResponse(code: NonNullable<ReturnType<typeof takeForcedError>>): MockResponse {
  switch (code) {
    case 'FORBIDDEN':
      return fail(403, code);
    case 'NOT_FOUND':
      return fail(404, code);
    case 'VALIDATION_ERROR':
      return invalid({ reason: 'TOO_SHORT' });
    default:
      return fail(409, code);
  }
}

// ---------------------------------------------------------------- routing

function route(req: MockRequest, actor: Actor): MockResponse {
  const url = new URL(req.path, 'http://mock.local');
  const segs = url.pathname.replace(/^\/admin\/employees\/?/, '').split('/').filter(Boolean);
  const [id, sub, leaf] = segs;
  const m = req.method;

  if (segs.length === 0) {
    if (m === 'GET') return listEmployees(url.searchParams, actor);
    if (m === 'POST') return createEmployee(req.body, actor);
  } else if (id) {
    const target = findEmployee(id);
    if (!target) return fail(404, 'NOT_FOUND');
    if (segs.length === 1) {
      if (m === 'GET') return ok(200, { employee: toDetail(actor, target) });
      if (m === 'PATCH') return updateEmployee(target, req.body, actor);
    } else if (segs.length === 2) {
      if (sub === 'status' && m === 'POST') return changeStatus(target, req.body, actor);
      if (sub === 'role' && m === 'PUT') return changeRole(target, req.body, actor);
      if (sub === 'permissions' && m === 'PUT') return changePermissions(target, req.body, actor);
      if (sub === 'activity' && m === 'GET') return activity(target, url.searchParams, actor);
    } else if (segs.length === 3 && sub === 'aadhaar' && leaf === 'reveal' && m === 'POST') {
      return revealAadhaar(target, actor);
    }
  }
  return fail(404, 'NOT_FOUND');
}

// ---------------------------------------------------------------- capabilities (computed per actor)

/** Main Admin manages everyone; a Sub-Admin with employee_management manages workers only. */
function canManage(actor: Actor, t: StoredEmployee): boolean {
  return actor.isMain || t.role === 'worker';
}

function rowCaps(actor: Actor, t: StoredEmployee): RowCapabilities {
  const manage = canManage(actor, t);
  return {
    canEdit: manage && t.accountStatus !== 'revoked',
    canDeactivate: manage && t.role !== 'main_admin' && t.accountStatus === 'active',
    canReactivate:
      manage && (t.accountStatus === 'inactive' || (t.accountStatus === 'revoked' && actor.isMain)),
  };
}

function detailCaps(actor: Actor, t: StoredEmployee): EmployeeCapabilities {
  const row = rowCaps(actor, t);
  const notMain = t.role !== 'main_admin';
  return {
    canEdit: row.canEdit,
    canChangeAadhaar: row.canEdit,
    canRevealAadhaar: actor.isMain && t.aadhaar !== '',
    canDeactivate: row.canDeactivate,
    canReactivate: row.canReactivate,
    canRevoke: actor.isMain && notMain && t.accountStatus !== 'revoked',
    canPromote: actor.isMain && t.role === 'worker' && t.accountStatus === 'active',
    canChangeRole: actor.isMain && notMain && t.accountStatus !== 'revoked',
    canChangePermissions: actor.isMain && t.role === 'sub_admin' && t.accountStatus !== 'revoked',
    canViewActivity: canManage(actor, t),
    isProtectedMainAdmin: t.role === 'main_admin',
  };
}

function toDetail(actor: Actor, t: StoredEmployee): EmployeeDetail {
  return {
    id: t.id,
    srNo: getStore().employees.indexOf(t) + 1,
    employeeId: t.employeeId,
    name: t.name,
    loginEmail: t.loginEmail,
    designation: t.designation,
    role: t.role,
    accountStatus: t.accountStatus,
    dateOfJoining: t.dateOfJoining,
    dateOfBirth: t.dateOfBirth,
    aadhaarMasked: t.aadhaar ? `XXXX XXXX ${t.aadhaar.slice(-4)}` : '',
    permissions: [...t.permissions],
    lastLoginAt: t.lastLoginAt,
    createdAt: t.createdAt,
    createdByName: t.createdByName,
    updatedAt: t.updatedAt,
    version: t.version,
    capabilities: detailCaps(actor, t),
  };
}

// ---------------------------------------------------------------- list

type SortKey = 'name' | 'employeeId' | 'designation' | 'dateOfJoining' | 'accountStatus' | 'role' | 'loginEmail';
const SORT_KEYS: readonly SortKey[] = [
  'name',
  'employeeId',
  'designation',
  'dateOfJoining',
  'accountStatus',
  'role',
  'loginEmail',
];

function clampInt(value: string | null, min: number, max: number, fallback: number): number {
  const n = Number.parseInt(value ?? '', 10);
  return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : fallback;
}

function listEmployees(params: URLSearchParams, actor: Actor): MockResponse {
  const all = getStore().employees;
  const q = (params.get('q') ?? '').trim().toLowerCase();
  const status = params.get('status') ?? 'all';
  const role = params.get('role');

  let rows = all.filter((e) => {
    if (status !== 'all' && e.accountStatus !== status) return false;
    if (role && e.role !== role) return false;
    if (!q) return true;
    return (
      e.name.toLowerCase().includes(q) || e.employeeId.toLowerCase().includes(q) || e.loginEmail.toLowerCase().includes(q)
    );
  });

  // SR NO is the stable position in the store (creation order), not the position in this result.
  const srNos = new Map<string, number>(all.map((e, i): [string, number] => [e.id, i + 1]));
  const srNoOf = (e: StoredEmployee) => srNos.get(e.id) ?? 0;

  const [rawKey = 'name', rawDir = 'asc'] = (params.get('sort') ?? 'name:asc').split(':');
  const dir = rawDir === 'desc' ? -1 : 1;
  if (rawKey === 'srNo') {
    rows = [...rows].sort((a, b) => (srNoOf(a) - srNoOf(b)) * dir);
  } else {
    const key: SortKey = SORT_KEYS.find((k) => k === rawKey) ?? 'name';
    rows = [...rows].sort((a, b) => {
      const va = a[key];
      const vb = b[key];
      if (va === vb) return a.name.localeCompare(b.name);
      if (va === null) return 1; // empty values always last
      if (vb === null) return -1;
      return va.localeCompare(vb) * dir;
    });
  }

  const pageSize = clampInt(params.get('pageSize'), 1, 50, 20);
  const page = clampInt(params.get('page'), 1, 10_000, 1);
  const start = (page - 1) * pageSize;
  const items: EmployeeListItem[] = rows.slice(start, start + pageSize).map((e) => ({
    id: e.id,
    srNo: srNoOf(e),
    employeeId: e.employeeId,
    name: e.name,
    loginEmail: e.loginEmail,
    designation: e.designation,
    role: e.role,
    accountStatus: e.accountStatus,
    dateOfJoining: e.dateOfJoining,
    capabilities: rowCaps(actor, e),
  }));

  return ok(200, {
    items,
    page,
    pageSize,
    total: rows.length,
    totals: {
      active: all.filter((e) => e.accountStatus === 'active').length,
      inactive: all.filter((e) => e.accountStatus === 'inactive').length,
      revoked: all.filter((e) => e.accountStatus === 'revoked').length,
    },
    capabilities: { canCreate: true, canAssignRole: actor.isMain },
  });
}

// ---------------------------------------------------------------- field validation

const todayIso = (): string => new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });

function isIsoDate(v: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(v)) return false;
  const d = new Date(`${v}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === v;
}

function optionalDate(
  rec: Rec,
  key: string,
  fields: Record<string, string>,
  rule: 'past' | 'notFuture',
): string | null | undefined {
  if (!(key in rec)) return undefined;
  const v = rec[key];
  if (v === null || v === '') return null;
  if (typeof v !== 'string' || !isIsoDate(v)) {
    fields[key] = 'INVALID_FORMAT';
    return undefined;
  }
  const today = todayIso();
  if (rule === 'past' && v >= today) fields[key] = 'PAST_REQUIRED';
  else if (rule === 'notFuture' && v > today) fields[key] = 'FUTURE_DATE';
  else return v;
  return undefined;
}

interface ParsedFields {
  name?: string;
  employeeId?: string;
  designation?: string | null;
  dateOfBirth?: string | null;
  dateOfJoining?: string | null;
  aadhaar?: string;
}

/** `partial` = PATCH: only keys that are present are checked. */
function parseFields(rec: Rec, partial: boolean, current?: StoredEmployee) {
  const fields: Record<string, string> = {};
  const values: ParsedFields = {};
  const present = (k: string) => !partial || k in rec;

  if (present('name')) {
    const v = typeof rec.name === 'string' ? rec.name.trim() : '';
    if (!v) fields.name = 'REQUIRED';
    else if (v.length < 2) fields.name = 'TOO_SHORT';
    else if (v.length > 100) fields.name = 'TOO_LONG';
    else values.name = v;
  }

  if (present('employeeId')) {
    const v = typeof rec.employeeId === 'string' ? rec.employeeId.trim() : '';
    if (!v) fields.employeeId = 'REQUIRED';
    else if (v.length < 3) fields.employeeId = 'TOO_SHORT';
    else if (v.length > 30) fields.employeeId = 'TOO_LONG';
    else if (!/^[A-Za-z0-9/-]+$/.test(v)) fields.employeeId = 'INVALID_FORMAT';
    else values.employeeId = v;
  }

  if ('designation' in rec) {
    const v = rec.designation;
    if (v === null || v === '') values.designation = null;
    else if (typeof v !== 'string') fields.designation = 'INVALID_FORMAT';
    else if (v.trim().length > 80) fields.designation = 'TOO_LONG';
    else values.designation = v.trim();
  }

  const dob = optionalDate(rec, 'dateOfBirth', fields, 'past');
  if (dob !== undefined) values.dateOfBirth = dob;
  const joined = optionalDate(rec, 'dateOfJoining', fields, 'notFuture');
  if (joined !== undefined) values.dateOfJoining = joined;
  const effectiveDob = fields.dateOfBirth ? null : dob !== undefined ? dob : (current?.dateOfBirth ?? null);
  if (joined && effectiveDob && joined < effectiveDob) fields.dateOfJoining = 'BEFORE_DOB';

  if (present('aadhaar')) {
    const raw = typeof rec.aadhaar === 'string' ? rec.aadhaar : '';
    const problem = aadhaarProblem(raw);
    if (problem) fields.aadhaar = problem;
    else values.aadhaar = raw.replace(/[\s-]/g, '');
  }

  return { fields, values };
}

function isPermission(v: unknown): v is Permission {
  return typeof v === 'string' && PERMISSION_ORDER.some((p) => p === v);
}

/** Returns sorted permissions, or an error code for the `permissions` field. */
function parsePermissions(value: unknown, required: boolean): { permissions: Permission[] } | { code: string } {
  if (value === undefined || value === null) return required ? { code: 'AT_LEAST_ONE' } : { permissions: [] };
  if (!Array.isArray(value) || !value.every(isPermission)) return { code: 'NOT_ALLOWED' };
  if (required && value.length === 0) return { code: 'AT_LEAST_ONE' };
  const set = new Set<Permission>(value);
  return { permissions: PERMISSION_ORDER.filter((p) => set.has(p)) };
}

function parseReason(value: unknown, required: boolean): { reason: string | null } | { code: string } {
  if (value === undefined || value === null || value === '') return required ? { code: 'REQUIRED' } : { reason: null };
  if (typeof value !== 'string') return { code: 'INVALID_FORMAT' };
  const v = value.trim();
  if (v.length < 5) return { code: 'TOO_SHORT' };
  if (v.length > 500) return { code: 'TOO_LONG' };
  return { reason: v };
}

function isTaken(
  pick: (e: StoredEmployee) => string,
  value: string,
  exceptId?: string,
): boolean {
  const needle = value.toLowerCase();
  return getStore().employees.some((e) => e.id !== exceptId && pick(e).toLowerCase() === needle);
}

// ---------------------------------------------------------------- create / update

function tempPassword(): string {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
  const bytes = crypto.getRandomValues(new Uint8Array(10));
  return `Tmp-${Array.from(bytes, (b) => alphabet.charAt(b % alphabet.length)).join('')}`;
}

function createEmployee(body: unknown, actor: Actor): MockResponse {
  if (!isRec(body)) return invalid({ name: 'REQUIRED' });
  if (!actor.isMain && body.role === 'sub_admin') return fail(403, 'FORBIDDEN');

  const { fields, values } = parseFields(body, false);

  const email = typeof body.loginEmail === 'string' ? body.loginEmail.trim() : '';
  if (!email) fields.loginEmail = 'REQUIRED';
  else if (email.length > 254) fields.loginEmail = 'TOO_LONG';
  else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) fields.loginEmail = 'INVALID_FORMAT';

  const rawRole = body.role;
  const role = rawRole === 'worker' || rawRole === 'sub_admin' ? rawRole : null;
  let permissions: Permission[] = [];
  if (role === null) {
    fields.role = 'NOT_ALLOWED';
  } else {
    const parsed = parsePermissions(body.permissions, role === 'sub_admin');
    if ('code' in parsed) fields.permissions = parsed.code;
    else if (role === 'worker' && parsed.permissions.length > 0) fields.permissions = 'NOT_ALLOWED';
    else permissions = parsed.permissions;
  }

  if (Object.keys(fields).length > 0 || role === null) return invalid(fields);
  if (!values.name || !values.employeeId || !values.aadhaar) return invalid(fields);

  if (isTaken((e) => e.employeeId, values.employeeId)) return fail(409, 'EMPLOYEE_ID_TAKEN');
  if (isTaken((e) => e.loginEmail, email)) return fail(409, 'EMAIL_TAKEN');
  if (isTaken((e) => e.aadhaar, values.aadhaar)) return fail(409, 'AADHAAR_TAKEN');

  const now = new Date().toISOString();
  const created: StoredEmployee = {
    id: crypto.randomUUID(),
    employeeId: values.employeeId,
    name: values.name,
    loginEmail: email,
    designation: values.designation ?? null,
    role,
    accountStatus: 'active',
    dateOfBirth: values.dateOfBirth ?? null,
    dateOfJoining: values.dateOfJoining ?? null,
    aadhaar: values.aadhaar,
    permissions,
    lastLoginAt: null,
    createdAt: now,
    createdByName: actor.name,
    updatedAt: now,
    version: 1,
  };
  getStore().employees.push(created);
  getStore().audit.set(created.id, []);
  addAudit(created.id, { action: 'USER_CREATED', actor });
  if (role === 'sub_admin') {
    addAudit(created.id, {
      action: 'SUBADMIN_CREATED',
      actor,
      changes: [{ field: 'permissions', from: null, to: permissions.join(', ') || null }],
    });
  }
  return ok(201, { employee: toDetail(actor, created), temporaryPassword: tempPassword() });
}

/** `?mock=conflict`: someone else saved a change a moment ago, so the version the client holds is stale. */
function simulateOtherEditor(t: StoredEmployee): void {
  const other: Actor = { id: 'mock-other-admin', name: 'Another admin', isMain: true };
  const from = t.designation;
  const to = `${from ?? 'Surveyor'} (updated)`.slice(0, 60);
  t.designation = to;
  t.version += 1;
  t.updatedAt = new Date().toISOString();
  addAudit(t.id, { action: 'USER_UPDATED', actor: other, changes: [{ field: 'designation', from, to }] });
}

function updateEmployee(t: StoredEmployee, body: unknown, actor: Actor): MockResponse {
  if (!rowCaps(actor, t).canEdit) return fail(403, 'FORBIDDEN');
  if (!isRec(body) || typeof body.version !== 'number') return invalid({ version: 'REQUIRED' });
  if (takeConflictTrigger()) simulateOtherEditor(t);
  if (body.version !== t.version) return fail(409, 'VERSION_CONFLICT');

  const { fields, values } = parseFields(body, true, t);
  if (Object.keys(fields).length > 0) return invalid(fields);

  if (values.employeeId !== undefined && isTaken((e) => e.employeeId, values.employeeId, t.id)) {
    return fail(409, 'EMPLOYEE_ID_TAKEN');
  }
  if (values.aadhaar !== undefined && isTaken((e) => e.aadhaar, values.aadhaar, t.id)) {
    return fail(409, 'AADHAAR_TAKEN');
  }

  const changes: ActivityChange[] = [];
  const track = (field: string, from: string | null, to: string | null) => {
    if (from !== to) changes.push({ field, from, to });
  };
  if (values.name !== undefined) {
    track('name', t.name, values.name);
    t.name = values.name;
  }
  if (values.employeeId !== undefined) {
    track('employeeId', t.employeeId, values.employeeId);
    t.employeeId = values.employeeId;
  }
  if (values.designation !== undefined) {
    track('designation', t.designation, values.designation);
    t.designation = values.designation;
  }
  if (values.dateOfBirth !== undefined) {
    track('dateOfBirth', t.dateOfBirth, values.dateOfBirth);
    t.dateOfBirth = values.dateOfBirth;
  }
  if (values.dateOfJoining !== undefined) {
    track('dateOfJoining', t.dateOfJoining, values.dateOfJoining);
    t.dateOfJoining = values.dateOfJoining;
  }
  const aadhaarChanged = values.aadhaar !== undefined && values.aadhaar !== t.aadhaar;
  if (values.aadhaar !== undefined && aadhaarChanged) t.aadhaar = values.aadhaar;

  if (changes.length > 0 || aadhaarChanged) {
    t.version += 1;
    t.updatedAt = new Date().toISOString();
    if (changes.length > 0) addAudit(t.id, { action: 'USER_UPDATED', actor, changes });
    // A separate entry, and never a value: the trail only says that the number changed.
    if (aadhaarChanged) addAudit(t.id, { action: 'USER_AADHAAR_CHANGED', actor });
  }
  return ok(200, { employee: toDetail(actor, t) });
}

// ---------------------------------------------------------------- status / role / permissions

function changeStatus(t: StoredEmployee, body: unknown, actor: Actor): MockResponse {
  if (!isRec(body)) return invalid({ action: 'REQUIRED' });
  const action = body.action;
  if (action !== 'deactivate' && action !== 'reactivate' && action !== 'revoke') {
    return invalid({ action: 'NOT_ALLOWED' });
  }

  if (!canManage(actor, t)) return fail(403, 'FORBIDDEN');
  if (action === 'revoke' && !actor.isMain) return fail(403, 'FORBIDDEN');
  if (action === 'reactivate' && t.accountStatus === 'revoked' && !actor.isMain) return fail(403, 'FORBIDDEN');
  if (t.role === 'main_admin' && action !== 'reactivate') return fail(409, 'LAST_MAIN_ADMIN_PROTECTED');

  const reason = parseReason(body.reason, action !== 'reactivate');
  if ('code' in reason) return invalid({ reason: reason.code });

  const from = t.accountStatus;
  const allowed =
    (action === 'deactivate' && from === 'active') ||
    (action === 'reactivate' && (from === 'inactive' || from === 'revoked')) ||
    (action === 'revoke' && (from === 'active' || from === 'inactive'));
  if (!allowed) return fail(409, 'INVALID_STATE');

  t.accountStatus = action === 'deactivate' ? 'inactive' : action === 'revoke' ? 'revoked' : 'active';
  t.version += 1;
  t.updatedAt = new Date().toISOString();
  addAudit(t.id, {
    action: action === 'deactivate' ? 'USER_DEACTIVATED' : action === 'reactivate' ? 'USER_REACTIVATED' : 'USER_REVOKED',
    actor,
    reason: reason.reason,
    changes: [{ field: 'accountStatus', from, to: t.accountStatus }],
  });
  return ok(200, { employee: toDetail(actor, t) });
}

function changeRole(t: StoredEmployee, body: unknown, actor: Actor): MockResponse {
  if (!actor.isMain) return fail(403, 'FORBIDDEN');
  if (t.role === 'main_admin') return fail(409, 'LAST_MAIN_ADMIN_PROTECTED');
  if (!isRec(body)) return invalid({ role: 'REQUIRED' });

  const role = body.role;
  if (role !== 'worker' && role !== 'sub_admin') return invalid({ role: 'NOT_ALLOWED' });
  const perms = parsePermissions(body.permissions, role === 'sub_admin');
  if ('code' in perms) return invalid({ permissions: perms.code });
  if (role === 'worker' && perms.permissions.length > 0) return invalid({ permissions: 'NOT_ALLOWED' });
  const reason = parseReason(body.reason, false);
  if ('code' in reason) return invalid({ reason: reason.code });

  if (t.accountStatus === 'revoked') return fail(409, 'INVALID_STATE');
  const samePerms = perms.permissions.join() === t.permissions.join();
  if (t.role === role && samePerms) return fail(409, 'INVALID_STATE');

  const changes: ActivityChange[] = [];
  if (t.role !== role) changes.push({ field: 'role', from: t.role, to: role });
  if (!samePerms) {
    changes.push({
      field: 'permissions',
      from: t.permissions.join(', ') || null,
      to: perms.permissions.join(', ') || null,
    });
  }
  t.role = role;
  t.permissions = perms.permissions;
  t.version += 1;
  t.updatedAt = new Date().toISOString();
  // worker -> sub_admin, sub_admin -> worker, or (role kept) only the permissions changed.
  const roleAction = changes.some((c) => c.field === 'role')
    ? role === 'sub_admin'
      ? 'SUBADMIN_CREATED'
      : 'SUBADMIN_REVOKED'
    : 'SUBADMIN_PERMISSIONS_CHANGED';
  addAudit(t.id, { action: roleAction, actor, reason: reason.reason, changes });
  return ok(200, { employee: toDetail(actor, t) });
}

function changePermissions(t: StoredEmployee, body: unknown, actor: Actor): MockResponse {
  if (!actor.isMain) return fail(403, 'FORBIDDEN');
  if (t.role !== 'sub_admin' || t.accountStatus === 'revoked') return fail(409, 'INVALID_STATE');
  if (!isRec(body)) return invalid({ permissions: 'REQUIRED' });

  const perms = parsePermissions(body.permissions, true);
  if ('code' in perms) return invalid({ permissions: perms.code });
  const reason = parseReason(body.reason, false);
  if ('code' in reason) return invalid({ reason: reason.code });

  if (perms.permissions.join() !== t.permissions.join()) {
    const from = t.permissions.join(', ') || null;
    t.permissions = perms.permissions;
    t.version += 1;
    t.updatedAt = new Date().toISOString();
    addAudit(t.id, {
      action: 'SUBADMIN_PERMISSIONS_CHANGED',
      actor,
      reason: reason.reason,
      changes: [{ field: 'permissions', from, to: perms.permissions.join(', ') }],
    });
  }
  return ok(200, { employee: toDetail(actor, t) });
}

// ---------------------------------------------------------------- reveal / activity

function revealAadhaar(t: StoredEmployee, actor: Actor): MockResponse {
  if (!actor.isMain) return fail(403, 'FORBIDDEN');
  if (!t.aadhaar) return fail(404, 'NOT_FOUND');
  const wait = checkRevealRate();
  if (wait > 0) return fail(429, 'RATE_LIMITED', { retryAfterSeconds: wait });
  addAudit(t.id, { action: 'AADHAAR_REVEALED', actor });
  return ok(200, { aadhaar: t.aadhaar, expiresInSeconds: 30 });
}

function activity(t: StoredEmployee, params: URLSearchParams, actor: Actor): MockResponse {
  if (!canManage(actor, t)) return fail(403, 'FORBIDDEN');
  const pageSize = clampInt(params.get('pageSize'), 1, 50, 25);
  const page = clampInt(params.get('page'), 1, 10_000, 1);
  const all = (getStore().audit.get(t.id) ?? [])
    .map((entry, index) => ({ entry, index }))
    .sort((a, b) => b.entry.at.localeCompare(a.entry.at) || b.index - a.index)
    .map(({ entry }) => entry);
  const start = (page - 1) * pageSize;
  return ok(200, { items: all.slice(start, start + pageSize), page, pageSize, total: all.length });
}
