import { digitsOnly } from '../aadhaar';
import type { EditFormValues } from '../formSchemas';
import type { UpdateEmployeeInput } from '../types';

/** The fields of a PATCH body except `version`. A key is present only when its value really changed. */
export type EmployeePatch = Omit<UpdateEmployeeInput, 'version'>;

/** What the diff reads. `useWatch` hands over a partial object; a missing key counts as "unchanged". */
export type EditSnapshot = { [K in keyof EditFormValues]?: EditFormValues[K] | undefined };

// Same normalisation the request uses, so "changed" means "the server would store something different".
const normName = (v: string): string => v.trim();
const normEmployeeId = (v: string): string => v.trim().toUpperCase();
const normDesignation = (v: string): string => v.trim();

/**
 * Pure diff of the form values against the values the form started from (or the latest loaded employee).
 * Only changed fields appear in the result, already normalised for the request body.
 *
 * Aadhaar: included only when the change field is open and holds at least one digit. The digits go
 * straight into the request; this function neither stores nor logs them.
 */
export function diffEditValues(values: EditSnapshot, initial: EditFormValues): EmployeePatch {
  const patch: EmployeePatch = {};

  if (values.name !== undefined && normName(values.name) !== normName(initial.name)) {
    patch.name = normName(values.name);
  }
  if (values.employeeId !== undefined && normEmployeeId(values.employeeId) !== normEmployeeId(initial.employeeId)) {
    patch.employeeId = normEmployeeId(values.employeeId);
  }
  if (
    values.designation !== undefined &&
    normDesignation(values.designation) !== normDesignation(initial.designation)
  ) {
    patch.designation = normDesignation(values.designation);
  }
  if (values.dateOfBirth !== undefined && values.dateOfBirth !== initial.dateOfBirth) {
    patch.dateOfBirth = values.dateOfBirth;
  }
  if (values.dateOfJoining !== undefined && values.dateOfJoining !== initial.dateOfJoining) {
    patch.dateOfJoining = values.dateOfJoining;
  }
  if (values.changeAadhaar === true && values.aadhaar !== undefined) {
    const digits = digitsOnly(values.aadhaar);
    if (digits !== '') patch.aadhaar = digits;
  }
  return patch;
}

export function hasChanges(patch: EmployeePatch): boolean {
  return Object.keys(patch).length > 0;
}

/**
 * Lays the user's changed fields over freshly loaded values ("keep my changes" after a version conflict).
 * The Aadhaar is not handled here: it stays in the form state untouched.
 */
export function applyChangedFields(fresh: EditFormValues, patch: EmployeePatch): EditFormValues {
  return {
    ...fresh,
    name: patch.name ?? fresh.name,
    employeeId: patch.employeeId ?? fresh.employeeId,
    designation: 'designation' in patch ? (patch.designation ?? '') : fresh.designation,
    dateOfBirth: 'dateOfBirth' in patch ? (patch.dateOfBirth ?? '') : fresh.dateOfBirth,
    dateOfJoining: 'dateOfJoining' in patch ? (patch.dateOfJoining ?? '') : fresh.dateOfJoining,
  };
}
