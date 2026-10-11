import { forwardRef, useState, type InputHTMLAttributes } from 'react';
import { useI18n } from '../../i18n';
import { Input } from './Input';

interface PasswordInputProps extends Omit<InputHTMLAttributes<HTMLInputElement>, 'type'> {
  label: string;
  error?: string;
}

/** Text "Show / Hide" toggle inside the field, as in the mockup. */
export const PasswordInput = forwardRef<HTMLInputElement, PasswordInputProps>(function PasswordInput(props, ref) {
  const { t } = useI18n();
  const [visible, setVisible] = useState(false);

  return (
    <Input
      ref={ref}
      {...props}
      type={visible ? 'text' : 'password'}
      endAdornment={
        <button
          type="button"
          className="input-toggle"
          aria-pressed={visible}
          aria-label={t('login.toggleAria')} // constant label + aria-pressed = correct toggle pattern
          disabled={props.disabled}
          onClick={() => setVisible((v) => !v)}
        >
          {visible ? t('login.hide') : t('login.show')}
        </button>
      }
    />
  );
});
