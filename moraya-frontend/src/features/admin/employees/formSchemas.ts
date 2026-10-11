import { z } from 'zod';
import type { DictKey } from '../../../i18n/en';
import { aadhaarProblem, digitsOnly } from './aadhaar';
import { PERMISSION_ORDER } from './labels';
import type { CreateEmployeeInput, EmployeeDetail, Permission } from './types';

// Messages are dictionary keys, translated at render time (same convention as the auth schemas).
const k = (key: DictKey): DictKey => key;

const TIME_ZONE = 'Asia/Kolkata';

/** Today as YYYY-MM-DD in the business time zone. Evaluated on every call, never cached. */
export function todayIso(): string {
  return new Date().toLocaleDateString('en-CA', { timeZone: TIME_ZONE });
}

/** The day before an ISO date (used as the `max` of the date-of-birth input). */
export function dayBefore(iso: string): string {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
}

export function isIsoDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const d = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === value;
}

/** Form fields in the order they appear on screen (used for focus and for the error summary). */
export const FORM_FIELDS = [
  'name',
  'employeeId',
  'designation',
  'dateOfBirth',
  'dateOfJoining',
  'aadhaar',
  'loginEmail',
  'role',
  'permissions',
] as const;

export type FormFieldName = (typeof FORM_FIELDS)[number];

export const FIELD_LABEL: Record<FormFieldName, DictKey> = {
  name: 'field.name',
  employeeId: 'field.employeeId',
  designation: 'field.designation',
  dateOfBirth: 'field.dob',
  dateOfJoining: 'field.doj',
  aadhaar: 'field.aadhaar',
  loginEmail: 'field.loginEmail',
  role: 'field.role',
  permissions: 'field.permissions',
};

export function isFormField(name: string): name is FormFieldName {
  return (FORM_FIELDS as readonly string[]).includes(name);
}

// ---------------------------------------------------------------- field rules

/** Required text with a trimmed length range. */
function textRule(min: number, max: number) {
  return z.string().superRefine((raw, ctx) => {
    const v = raw.trim();
    if (v.length === 0) ctx.addIssue({ code: 'custom', message: k('fieldErr.REQUIRED') });
    else if (v.length < min) ctx.addIssue({ code: 'custom', message: k('fieldErr.TOO_SHORT') });
    else if (v.length > max) ctx.addIssue({ code: 'custom', message: k('fieldErr.TOO_LONG') });
  });
}

const employeeIdRule = z.string().superRefine((raw, ctx) => {
  const v = raw.trim();
  if (v.length === 0) ctx.addIssue({ code: 'custom', message: k('fieldErr.REQUIRED') });
  else if (v.length < 3) ctx.addIssue({ code: 'custom', message: k('fieldErr.TOO_SHORT') });
  else if (v.length > 30) ctx.addIssue({ code: 'custom', message: k('fieldErr.TOO_LONG') });
  else if (!/^[A-Za-z0-9/-]+$/.test(v)) ctx.addIssue({ code: 'custom', message: k('fieldErr.INVALID_FORMAT') });
});

function dateRule(kind: 'dob' | 'doj') {
  return z.string().superRefine((v, ctx) => {
    if (v === '') {
      ctx.addIssue({ code: 'custom', message: k('fieldErr.REQUIRED') });
    } else if (!isIsoDate(v)) {
      ctx.addIssue({ code: 'custom', message: k('fieldErr.INVALID_FORMAT') });
    } else if (kind === 'dob' && v >= todayIso()) {
      ctx.addIssue({ code: 'custom', message: k('err.dobFuture') });
    } else if (kind === 'doj' && v > todayIso()) {
      ctx.addIssue({ code: 'custom', message: k('err.dojFuture') });
    }
  });
}

/**
 * Aadhaar: 12 digits, first digit 2-9, Verhoeff check digit (when ENFORCE_AADHAAR_CHECKSUM is on).
 * The value is only inspected, never copied anywhere. Returns the message key, or null when acceptable.
 */
function aadhaarMessage(raw: string): DictKey | null {
  const problem = aadhaarProblem(raw);
  if (problem === 'REQUIRED') return k('fieldErr.REQUIRED');
  if (problem === 'INVALID_FORMAT') return k('err.aadhaarInvalid');
  if (!/^[2-9]/.test(digitsOnly(raw))) return k('err.aadhaarInvalid');
  if (problem === 'CHECKSUM') return k('fieldErr.CHECKSUM');
  return null;
}

const aadhaarRule = z.string().superRefine((raw, ctx) => {
  const message = aadhaarMessage(raw);
  if (message) ctx.addIssue({ code: 'custom', message });
});

/**
 * Joining date cannot be before the date of birth. Only true when both are valid and the birth date is
 * itself acceptable, so one bad date does not produce a second, misleading error.
 */
function joinsBeforeBirth(dateOfBirth: string, dateOfJoining: string): boolean {
  return (
    isIsoDate(dateOfBirth) && isIsoDate(dateOfJoining) && dateOfBirth < todayIso() && dateOfJoining < dateOfBirth
  );
}

const emailRule = z.string().superRefine((raw, ctx) => {
  const v = raw.trim().toLowerCase();
  if (v.length === 0) ctx.addIssue({ code: 'custom', message: k('err.emailRequired') });
  else if (v.length > 254) ctx.addIssue({ code: 'custom', message: k('err.emailTooLong') });
  else if (!z.string().email().safeParse(v).success) {
    ctx.addIssue({ code: 'custom', message: k('err.emailInvalid') });
  }
});

const permissionRule = z.enum([
  'employee_management',
  'site_management',
  'verification',
  'income_management',
  'salary_management',
  'report_view',
  'export',
]);

// ---------------------------------------------------------------- create

export const createSchema = z
  .object({
    name: textRule(2, 100),
    employeeId: employeeIdRule,
    designation: textRule(2, 60),
    dateOfBirth: dateRule('dob'),
    dateOfJoining: dateRule('doj'),
    aadhaar: aadhaarRule,
    loginEmail: emailRule,
    role: z.enum(['worker', 'sub_admin']),
    permissions: z.array(permissionRule),
  })
  .superRefine((v, ctx) => {
    if (joinsBeforeBirth(v.dateOfBirth, v.dateOfJoining)) {
      ctx.addIssue({ code: 'custom', path: ['dateOfJoining'], message: k('fieldErr.BEFORE_DOB') });
    }
    // Permissions: at least one for a Sub-Admin, none for a Surveyor.
    if (v.role === 'sub_admin' && v.permissions.length === 0) {
      ctx.addIssue({ code: 'custom', path: ['permissions'], message: k('fieldErr.AT_LEAST_ONE') });
    }
    if (v.role === 'worker' && v.permissions.length > 0) {
      ctx.addIssue({ code: 'custom', path: ['permissions'], message: k('fieldErr.NOT_ALLOWED') });
    }
  });

export type CreateFormValues = z.infer<typeof createSchema>;

export const defaultCreateValues: CreateFormValues = {
  name: '',
  employeeId: '',
  designation: '',
  dateOfBirth: '',
  dateOfJoining: '',
  aadhaar: '',
  loginEmail: '',
  role: 'worker',
  permissions: [],
};

/**
 * Form values -> API request. Without `canAssignRole` the role is always Surveyor, whatever the form holds.
 * The Aadhaar leaves here as plain digits and goes straight to the request: it is not stored anywhere.
 */
export function toCreateInput(values: CreateFormValues, canAssignRole: boolean): CreateEmployeeInput {
  const role = canAssignRole ? values.role : 'worker';
  const input: CreateEmployeeInput = {
    name: values.name.trim(),
    employeeId: values.employeeId.trim().toUpperCase(),
    designation: values.designation.trim(),
    dateOfBirth: values.dateOfBirth,
    dateOfJoining: values.dateOfJoining,
    aadhaar: digitsOnly(values.aadhaar),
    loginEmail: values.loginEmail.trim().toLowerCase(),
    role,
  };
  if (role === 'sub_admin') {
    const chosen = new Set<Permission>(values.permissions);
    input.permissions = PERMISSION_ORDER.filter((p) => chosen.has(p));
  }
  return input;
}

// ---------------------------------------------------------------- edit

/** The fields the create and edit forms share (the shared parts of `EmployeeForm` read only these). */
export type SharedFormValues = Pick<
  CreateFormValues,
  'name' | 'employeeId' | 'designation' | 'dateOfBirth' | 'dateOfJoining' | 'aadhaar'
>;

/** Edit form fields in on-screen order (used for focus and for the error summary). */
export const EDIT_FIELDS = ['name', 'employeeId', 'designation', 'dateOfBirth', 'dateOfJoining', 'aadhaar'] as const;
export type EditFieldName = (typeof EDIT_FIELDS)[number];

export function isEditField(name: string): name is EditFieldName {
  return (EDIT_FIELDS as readonly string[]).includes(name);
}

/**
 * Same field rules as create. Login email, role and permissions are not part of this form.
 * `aadhaar` is only checked while `changeAadhaar` is on; otherwise it is an empty string that is never sent.
 */
export const editSchema = z
  .object({
    name: textRule(2, 100),
    employeeId: employeeIdRule,
    designation: textRule(2, 60),
    dateOfBirth: dateRule('dob'),
    dateOfJoining: dateRule('doj'),
    aadhaar: z.string(),
    changeAadhaar: z.boolean(),
  })
  .superRefine((v, ctx) => {
    if (joinsBeforeBirth(v.dateOfBirth, v.dateOfJoining)) {
      ctx.addIssue({ code: 'custom', path: ['dateOfJoining'], message: k('fieldErr.BEFORE_DOB') });
    }
    if (v.changeAadhaar) {
      const message = aadhaarMessage(v.aadhaar);
      if (message) ctx.addIssue({ code: 'custom', path: ['aadhaar'], message });
    }
  });

export type EditFormValues = z.infer<typeof editSchema>;

/**
 * Employee -> form values. Dates are already YYYY-MM-DD. The Aadhaar is never prefilled: the employee
 * object only carries the masked number, and the change field always starts closed and empty.
 */
export function editValuesFrom(employee: EmployeeDetail): EditFormValues {
  return {
    name: employee.name,
    employeeId: employee.employeeId,
    designation: employee.designation ?? '',
    dateOfBirth: employee.dateOfBirth ?? '',
    dateOfJoining: employee.dateOfJoining ?? '',
    aadhaar: '',
    changeAadhaar: false,
  };
}
