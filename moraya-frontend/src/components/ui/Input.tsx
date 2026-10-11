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
    <div>
      <label htmlFor={inputId} className="mb-1.5 block text-sm font-medium text-text">
        {label}
      </label>
      <div className="relative">
        <input
          ref={ref}
          id={inputId}
          aria-invalid={error ? true : undefined}
          aria-describedby={error ? errorId : undefined}
          className={`block min-h-11 w-full rounded-md border bg-surface px-3 text-base text-text disabled:opacity-60 ${
            error ? 'border-danger' : 'border-field'
          } ${endAdornment ? 'pe-12' : ''} ${className}`}
          {...rest}
        />
        {endAdornment && <div className="absolute inset-y-0 end-0 flex items-center">{endAdornment}</div>}
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
