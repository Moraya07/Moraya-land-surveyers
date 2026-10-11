import { forwardRef, useState, type InputHTMLAttributes } from 'react';
import { useI18n } from '../../i18n';
import { EyeIcon, EyeOffIcon } from '../icons';
import { Input } from './Input';

interface PasswordInputProps extends Omit<InputHTMLAttributes<HTMLInputElement>, 'type'> {
  label: string;
  error?: string;
}

export const PasswordInput = forwardRef<HTMLInputElement, PasswordInputProps>(function PasswordInput(props, ref) {
  const { t } = useI18n();
  const [visible, setVisible] = useState(false);
  const label = t('login.show'); // constant label + aria-pressed = correct toggle pattern

  return (
    <Input
      ref={ref}
      {...props}
      type={visible ? 'text' : 'password'}
      endAdornment={
        <button
          type="button"
          aria-pressed={visible}
          aria-label={label}
          title={label}
          onClick={() => setVisible((v) => !v)}
          className="flex h-11 w-11 items-center justify-center rounded-md text-text-muted hover:text-text"
        >
          {visible ? <EyeOffIcon /> : <EyeIcon />}
        </button>
      }
    />
  );
});
