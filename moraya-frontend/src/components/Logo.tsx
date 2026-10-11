import { useState } from 'react';
import logoUrl from '../assets/brand/moraya-logo.svg';

interface LogoProps {
  className?: string;
}

/**
 * Original Moraya logo (black + red artwork, designed for light backgrounds).
 * On dark theme it sits on a white plate; replace with a dark-surface variant if one is supplied.
 * Falls back to a plain text wordmark if the file fails to load.
 */
export function Logo({ className = 'h-24' }: LogoProps) {
  const [failed, setFailed] = useState(false);
  if (failed) {
    return <span className="text-2xl font-semibold tracking-tight text-text">Moraya</span>;
  }
  return (
    <img
      src={logoUrl}
      alt="Moraya"
      onError={() => setFailed(true)}
      className={`w-auto dark:box-content dark:rounded-md dark:bg-white dark:p-2 ${className}`}
    />
  );
}
