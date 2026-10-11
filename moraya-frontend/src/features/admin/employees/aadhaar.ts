/**
 * Aadhaar helpers. Pure functions only: nothing here stores, logs or caches a number.
 * Callers must keep the value in component state and drop it when done.
 */

/** Product rule: reject numbers that fail the Verhoeff check digit. Set to false to accept any 12 digits. */
export const ENFORCE_AADHAAR_CHECKSUM = true;

export type AadhaarProblem = 'REQUIRED' | 'INVALID_FORMAT' | 'CHECKSUM';

// Verhoeff tables (dihedral group D5 multiplication, permutation, inverse).
const D: readonly (readonly number[])[] = [
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
  [1, 2, 3, 4, 0, 6, 7, 8, 9, 5],
  [2, 3, 4, 0, 1, 7, 8, 9, 5, 6],
  [3, 4, 0, 1, 2, 8, 9, 5, 6, 7],
  [4, 0, 1, 2, 3, 9, 5, 6, 7, 8],
  [5, 9, 8, 7, 6, 0, 4, 3, 2, 1],
  [6, 5, 9, 8, 7, 1, 0, 4, 3, 2],
  [7, 6, 5, 9, 8, 2, 1, 0, 4, 3],
  [8, 7, 6, 5, 9, 3, 2, 1, 0, 4],
  [9, 8, 7, 6, 5, 4, 3, 2, 1, 0],
];
const P: readonly (readonly number[])[] = [
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
  [1, 5, 7, 6, 2, 8, 3, 0, 9, 4],
  [5, 8, 0, 3, 7, 9, 6, 1, 4, 2],
  [8, 9, 1, 6, 0, 4, 3, 5, 2, 7],
  [9, 4, 5, 3, 1, 2, 6, 8, 7, 0],
  [4, 2, 8, 6, 5, 7, 3, 9, 0, 1],
  [2, 7, 9, 3, 8, 0, 6, 4, 1, 5],
  [7, 0, 4, 6, 9, 1, 3, 2, 5, 8],
];
const INV: readonly number[] = [0, 4, 3, 2, 1, 5, 6, 7, 8, 9];

const d = (row: number, col: number): number => D[row]?.[col] ?? 0;
const p = (row: number, col: number): number => P[row % 8]?.[col] ?? 0;

/** Keeps digits only, capped at 12 (so pasted "1234-5678-9012" works). */
export function digitsOnly(value: string): string {
  return value.replace(/\D/g, '').slice(0, 12);
}

/** "123456789012" -> "1234 5678 9012" (partial input is grouped as far as it goes). */
export function formatAadhaar(value: string): string {
  return digitsOnly(value)
    .replace(/(\d{4})(?=\d)/g, '$1 ')
    .trim();
}

/** True when the digit string (any length >= 2) satisfies the Verhoeff check. */
export function verhoeffValidate(digits: string): boolean {
  if (!/^\d{2,}$/.test(digits)) return false;
  let c = 0;
  const reversed = digits.split('').reverse();
  for (let i = 0; i < reversed.length; i += 1) c = d(c, p(i, Number(reversed[i])));
  return c === 0;
}

/** Check digit to append to `digits` so the result passes verhoeffValidate. */
export function verhoeffCheckDigit(digits: string): number {
  let c = 0;
  const reversed = digits.split('').reverse();
  for (let i = 0; i < reversed.length; i += 1) c = d(c, p(i + 1, Number(reversed[i])));
  return INV[c] ?? 0;
}

/** Returns the first problem with a user-typed Aadhaar, or null when it is acceptable. */
export function aadhaarProblem(input: string): AadhaarProblem | null {
  if (input.trim() === '') return 'REQUIRED';
  const digits = input.replace(/[\s-]/g, '');
  if (!/^\d{12}$/.test(digits)) return 'INVALID_FORMAT';
  if (ENFORCE_AADHAAR_CHECKSUM && !verhoeffValidate(digits)) return 'CHECKSUM';
  return null;
}

export function isValidAadhaar(input: string): boolean {
  return aadhaarProblem(input) === null;
}
