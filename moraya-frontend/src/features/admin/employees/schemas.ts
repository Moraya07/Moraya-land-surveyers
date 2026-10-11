import { z } from 'zod';
import type {
  ActivityResponse,
  CreateEmployeeResult,
  EmployeeEnvelope,
  EmployeeListResponse,
  RevealAadhaarResult,
} from './types';

/** The server answered 2xx but the body is not what the contract says. Carries no payload on purpose. */
export class ApiShapeError extends Error {
  constructor() {
    super('API_SHAPE_ERROR'); // never include the body or Zod issues: they may contain personal data
    this.name = 'ApiShapeError';
  }
}

const role = z.enum(['main_admin', 'sub_admin', 'worker']);
const accountStatus = z.enum(['active', 'inactive', 'revoked']);
const permission = z.enum([
  'employee_management',
  'site_management',
  'verification',
  'income_management',
  'salary_management',
  'report_view',
  'export',
]);

const rowCapabilities = z.object({
  canEdit: z.boolean(),
  canDeactivate: z.boolean(),
  canReactivate: z.boolean(),
});

const listItem = z.object({
  id: z.string().min(1),
  srNo: z.number().int(),
  employeeId: z.string(),
  name: z.string(),
  loginEmail: z.string(),
  designation: z.string().nullable(),
  role,
  accountStatus,
  dateOfJoining: z.string().nullable(),
  capabilities: rowCapabilities,
});

const listResponse: z.ZodType<EmployeeListResponse> = z.object({
  items: z.array(listItem),
  page: z.number().int(),
  pageSize: z.number().int(),
  total: z.number().int(),
  totals: z.object({ active: z.number().int(), inactive: z.number().int(), revoked: z.number().int() }),
  capabilities: z.object({ canCreate: z.boolean(), canAssignRole: z.boolean() }),
});

const employeeCapabilities = z.object({
  canEdit: z.boolean(),
  canChangeAadhaar: z.boolean(),
  canRevealAadhaar: z.boolean(),
  canDeactivate: z.boolean(),
  canReactivate: z.boolean(),
  canRevoke: z.boolean(),
  canPromote: z.boolean(),
  canChangeRole: z.boolean(),
  canChangePermissions: z.boolean(),
  canViewActivity: z.boolean(),
  isProtectedMainAdmin: z.boolean(),
});

const employeeDetail = listItem.omit({ capabilities: true }).extend({
  dateOfBirth: z.string().nullable(),
  // Defence in depth: only a masked value (or nothing) may enter the query cache.
  aadhaarMasked: z.string().regex(/^(?:|X{4} X{4} \d{4})$/),
  permissions: z.array(permission),
  lastLoginAt: z.string().nullable(),
  createdAt: z.string(),
  createdByName: z.string().nullable(),
  updatedAt: z.string(),
  version: z.number().int(),
  capabilities: employeeCapabilities,
});

const employeeEnvelope: z.ZodType<EmployeeEnvelope> = z.object({ employee: employeeDetail });

const createResult: z.ZodType<CreateEmployeeResult> = z.object({
  employee: employeeDetail,
  temporaryPassword: z.string().min(1),
});

const activityItem = z.object({
  id: z.string(),
  at: z.string(),
  action: z.string(),
  actorName: z.string().nullable(),
  reason: z.string().nullable(),
  changes: z.array(z.object({ field: z.string(), from: z.string().nullable(), to: z.string().nullable() })).nullable(),
});

const activityResponse: z.ZodType<ActivityResponse> = z.object({
  items: z.array(activityItem),
  page: z.number().int(),
  pageSize: z.number().int(),
  total: z.number().int(),
});

const revealResult: z.ZodType<RevealAadhaarResult> = z.object({
  aadhaar: z.string().regex(/^\d{12}$/),
  expiresInSeconds: z.number().int().positive(),
});

export const schemas = {
  list: listResponse,
  employee: employeeEnvelope,
  create: createResult,
  activity: activityResponse,
  reveal: revealResult,
} as const;

/** Parses a response body, or throws ApiShapeError (no details kept). */
export function parseResponse<T>(schema: z.ZodType<T>, data: unknown): T {
  const result = schema.safeParse(data);
  if (!result.success) throw new ApiShapeError();
  return result.data;
}
