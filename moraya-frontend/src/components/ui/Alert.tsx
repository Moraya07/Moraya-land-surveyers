import type { ReactNode } from 'react';
import { AlertIcon, CheckIcon } from '../icons';

interface AlertProps {
  variant: 'danger' | 'success';
  role?: 'alert' | 'status';
  children: ReactNode;
}

const styles = {
  danger: 'border-danger/50 bg-danger-subtle text-text [&>svg]:text-danger',
  success: 'border-success/50 bg-success-subtle text-text [&>svg]:text-success',
} as const;

/** Icon + text, so colour is never the only indicator. */
export function Alert({ variant, role, children }: AlertProps) {
  return (
    <div role={role} className={`flex items-start gap-2.5 rounded-md border p-3 text-sm ${styles[variant]}`}>
      {variant === 'danger' ? (
        <AlertIcon className="mt-[0.1em] shrink-0" />
      ) : (
        <CheckIcon className="mt-[0.1em] shrink-0" />
      )}
      <div>{children}</div>
    </div>
  );
}
