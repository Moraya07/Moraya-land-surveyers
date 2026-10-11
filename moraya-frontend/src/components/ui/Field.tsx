import { useId, type ReactNode } from 'react';
import { AlertIcon } from '../icons';

export interface FieldControlProps {
  id: string;
  'aria-describedby'?: string;
  'aria-invalid'?: true;
  'aria-required'?: true;
}

interface FieldProps {
  label: string;
  hint?: string;
  error?: string;
  required?: boolean;
  /** Receives the id and aria props to spread onto the control (input, select, textarea...). */
  children: (control: FieldControlProps) => ReactNode;
}

/** Label + control + hint + error with the aria wiring done once. Reuses the `.field` styles of Input. */
export function Field({ label, hint, error, required = false, children }: FieldProps) {
  const id = useId();
  const hintId = `${id}-hint`;
  const errorId = `${id}-error`;
  const describedBy = [hint ? hintId : null, error ? errorId : null].filter(Boolean).join(' ');

  const control: FieldControlProps = { id };
  if (describedBy) control['aria-describedby'] = describedBy;
  if (error) control['aria-invalid'] = true;
  if (required) control['aria-required'] = true;

  return (
    <div className="field">
      <label htmlFor={id} className="field-label">
        {label}
        {required && (
          <span aria-hidden="true" className="ms-0.5 text-danger">
            *
          </span>
        )}
      </label>
      {children(control)}
      {hint && (
        <p id={hintId} className="mt-1.5 text-sm text-text-muted">
          {hint}
        </p>
      )}
      {error && (
        <p id={errorId} className="mt-1.5 flex items-start gap-1.5 text-sm text-danger">
          <AlertIcon width={16} height={16} className="mt-[0.2em] shrink-0" />
          <span>{error}</span>
        </p>
      )}
    </div>
  );
}
