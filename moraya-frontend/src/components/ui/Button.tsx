import type { ButtonHTMLAttributes } from 'react';
import { Spinner } from './Spinner';

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'primary' | 'secondary' | 'danger';
  loading?: boolean;
  fullWidth?: boolean;
}

export function Button({
  variant = 'primary',
  loading = false,
  fullWidth = false,
  disabled,
  className = '',
  type = 'button',
  children,
  ...rest
}: ButtonProps) {
  const look =
    variant === 'primary'
      ? `btn-primary ${fullWidth ? '' : '!w-auto px-5'}`
      : variant === 'danger'
        ? `inline-flex min-h-11 items-center justify-center gap-2 rounded-md bg-danger px-4 text-base font-semibold text-primary-foreground transition-opacity hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-60 ${
            fullWidth ? 'w-full' : ''
          }`
        : `inline-flex min-h-11 items-center justify-center gap-2 rounded-md border border-field bg-surface px-4 text-base font-medium text-text transition-colors hover:bg-panel disabled:cursor-not-allowed disabled:opacity-60 ${
          fullWidth ? 'w-full' : ''
        }`;
  return (
    <button
      type={type}
      disabled={disabled || loading}
      aria-busy={loading || undefined}
      className={`${look} ${className}`}
      {...rest}
    >
      {loading && <Spinner />}
      {children}
    </button>
  );
}
