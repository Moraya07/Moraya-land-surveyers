import type { Role } from '../../auth/authApi';
import type { Permission } from '../permissions';

// Role and Permission already exist in the app; re-exported so the Employees code has one import.
export type { Permission, Role };

export type AccountStatus = 'active' | 'inactive' | 'revoked';
export type StatusFilter = AccountStatus | 'all';
export type StatusAction = 'deactivate' | 'reactivate' | 'revoke';

/** Machine codes the API may return per field. Anything else is shown as "fieldErr.invalid". */
export type FieldCode =
  | 'REQUIRED'
  | 'INVALID_FORMAT'
  | 'TOO_SHORT'
  | 'TOO_LONG'
  | 'FUTURE_DATE'
  | 'PAST_REQUIRED'
  | 'BEFORE_DOB'
  | 'CHECKSUM'
  | 'AT_LEAST_ONE'
  | 'NOT_ALLOWED';

export interface RowCapabilities {
  canEdit: boolean;
  canDeactivate: boolean;
  canReactivate: boolean;
}

export interface EmployeeListItem {
  id: string;
  srNo: number;
  employeeId: string;
  name: string;
  loginEmail: string;
  designation: string | null;
  role: Role;
  accountStatus: AccountStatus;
  dateOfJoining: string | null; // YYYY-MM-DD
  capabilities: RowCapabilities;
}

export interface EmployeeListResponse {
  items: EmployeeListItem[];
  page: number;
  pageSize: number;
  total: number;
  /** Ignore filters: counts across all employees. */
  totals: { active: number; inactive: number; revoked: number };
  capabilities: { canCreate: boolean; canAssignRole: boolean };
}

export interface EmployeeCapabilities {
  canEdit: boolean;
  canChangeAadhaar: boolean;
  canRevealAadhaar: boolean;
  canDeactivate: boolean;
  canReactivate: boolean;
  canRevoke: boolean;
  canPromote: boolean;
  canChangeRole: boolean;
  canChangePermissions: boolean;
  canViewActivity: boolean;
  isProtectedMainAdmin: boolean;
}

export interface EmployeeDetail extends Omit<EmployeeListItem, 'capabilities'> {
  dateOfBirth: string | null; // YYYY-MM-DD
  /** 'XXXX XXXX 1234', or '' when none on file. The full number is never part of this object. */
  aadhaarMasked: string;
  permissions: Permission[];
  lastLoginAt: string | null; // ISO-8601 UTC
  createdAt: string;
  createdByName: string | null;
  updatedAt: string;
  version: number;
  capabilities: EmployeeCapabilities;
}

export interface ActivityChange {
  field: string;
  from: string | null;
  to: string | null;
}

export interface ActivityItem {
  id: string;
  at: string;
  action: string;
  actorName: string | null;
  reason: string | null;
  changes: ActivityChange[] | null;
}

export interface ActivityResponse {
  items: ActivityItem[];
  page: number;
  pageSize: number;
  total: number;
}

// ---- Requests ----

export interface EmployeeListParams {
  q?: string;
  status?: StatusFilter;
  role?: Role;
  /** "field:asc" | "field:desc". Default "name:asc". */
  sort?: string;
  page?: number;
  pageSize?: number;
}

export interface CreateEmployeeInput {
  name: string;
  employeeId: string;
  designation: string | null;
  dateOfBirth: string | null;
  dateOfJoining: string | null;
  aadhaar: string; // digits only; sent once, never cached or logged
  loginEmail: string;
  role: 'worker' | 'sub_admin';
  permissions?: Permission[];
}

export interface UpdateEmployeeInput {
  version: number;
  name?: string;
  employeeId?: string;
  designation?: string | null;
  dateOfBirth?: string | null;
  dateOfJoining?: string | null;
  aadhaar?: string;
}

export interface ChangeStatusInput {
  action: StatusAction;
  /** Required (5–500 chars) for deactivate and revoke. */
  reason?: string;
}

export interface ChangeRoleInput {
  role: 'worker' | 'sub_admin';
  permissions?: Permission[];
  reason?: string;
}

export interface ChangePermissionsInput {
  permissions: Permission[];
  reason?: string;
}

// ---- Responses ----

export interface EmployeeEnvelope {
  employee: EmployeeDetail;
}

export interface CreateEmployeeResult {
  employee: EmployeeDetail;
  /** Show once, then drop. Never cached, logged or persisted. */
  temporaryPassword: string;
}

export interface RevealAadhaarResult {
  /** Digits only. Never cached or persisted; `expiresInSeconds` says how long the UI may show it. */
  aadhaar: string;
  expiresInSeconds: number;
}
