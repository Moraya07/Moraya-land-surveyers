import { forwardRef, useId, type InputHTMLAttributes, type ReactNode } from 'react';
import { AlertIcon } from '../icons';

interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  label: string;
  error?: string;
  endAdornment?: ReactNode;
}

export const Input = forwardRef<HTMLInputElement, InputProps>(function Input(
  { label, error, endAdornment, id, className = '', ...rest },
  ref,
) {
  const autoId = useId();
  const inputId = id ?? autoId;
  const errorId = `${inputId}-error`;

  return (
    <div className="field">
      <label htmlFor={inputId} className="field-label">
        {label}
      </label>
      <div className="relative">
        <input
          ref={ref}
          id={inputId}
          aria-invalid={error ? true : undefined}
          aria-describedby={error ? errorId : undefined}
          className={`input ${endAdornment ? 'input-end' : ''} ${className}`}
          {...rest}
        />
        {endAdornment}
      </div>
      {error && (
        <p id={errorId} className="mt-1.5 flex items-start gap-1.5 text-sm text-danger">
          <AlertIcon width={16} height={16} className="mt-[0.2em] shrink-0" />
          <span>{error}</span>
        </p>
      )}
    </div>
  );
});
