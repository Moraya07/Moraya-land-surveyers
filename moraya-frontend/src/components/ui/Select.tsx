import { forwardRef, type ReactNode, type SelectHTMLAttributes } from 'react';
import { ChevronDownIcon } from '../icons';
import { Field } from './Field';

interface SelectProps extends Omit<SelectHTMLAttributes<HTMLSelectElement>, 'children'> {
  label: string;
  hint?: string;
  error?: string;
  /** <option> elements. */
  children: ReactNode;
}

/** Native <select> (best keyboard, screen-reader and mobile behaviour) styled like Input. */
export const Select = forwardRef<HTMLSelectElement, SelectProps>(function Select(
  { label, hint, error, required, className = '', children, ...rest },
  ref,
) {
  return (
    <Field label={label} hint={hint} error={error} required={required}>
      {(control) => (
        <div className="relative">
          <select
            ref={ref}
            required={required}
            {...control}
            className={`input appearance-none pe-10 ${className}`}
            {...rest}
          >
            {children}
          </select>
          <ChevronDownIcon
            width={18}
            height={18}
            className="pointer-events-none absolute end-3 top-1/2 -translate-y-1/2 text-text-muted"
          />
        </div>
      )}
    </Field>
  );
});
