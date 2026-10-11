import type { UseFormRegisterReturn } from 'react-hook-form';
import { digitsOnly, formatAadhaar } from '../aadhaar';

/** Applies `transform` to the field's text before the form library reads it, keeping the caret where it was. */
export function transformInput(el: HTMLInputElement, transform: (value: string) => string): void {
  const next = transform(el.value);
  if (next === el.value) return;
  const start = el.selectionStart; // null for some input types (e.g. email): the caret then goes to the end
  const end = el.selectionEnd;
  el.value = next;
  if (start !== null && end !== null && document.activeElement === el) el.setSelectionRange(start, end);
}

/** "123456789012" -> "1234 5678 9012" while typing; pasted spaces and dashes are stripped. */
export function groupAadhaar(el: HTMLInputElement): void {
  const caret = el.selectionStart;
  const digitsBeforeCaret = caret === null ? null : digitsOnly(el.value.slice(0, caret)).length;
  const grouped = formatAadhaar(el.value);
  if (grouped === el.value) return;
  el.value = grouped;
  if (digitsBeforeCaret === null || document.activeElement !== el) return;
  // Put the caret after the same number of digits it followed before the spaces were inserted.
  let position = 0;
  let seen = 0;
  while (position < grouped.length && seen < digitsBeforeCaret) {
    if (/\d/.test(grouped.charAt(position))) seen += 1;
    position += 1;
  }
  el.setSelectionRange(position, position);
}

/** Wraps a `register()` result so `transform` runs on the input before the form library reads the value. */
export function withTransform(
  reg: UseFormRegisterReturn,
  transform: (el: HTMLInputElement) => void,
): UseFormRegisterReturn {
  return {
    ...reg,
    onChange: (event) => {
      if (event.target instanceof HTMLInputElement) transform(event.target);
      return reg.onChange(event);
    },
  };
}
