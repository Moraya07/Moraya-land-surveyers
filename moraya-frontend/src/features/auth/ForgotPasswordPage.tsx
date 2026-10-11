import { useState } from 'react';
import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation } from '@tanstack/react-query';
import { useForm } from 'react-hook-form';
import { Link } from 'react-router-dom';
import { AuthLayout } from '../../components/AuthLayout';
import { Alert } from '../../components/ui/Alert';
import { Button } from '../../components/ui/Button';
import { Input } from '../../components/ui/Input';
import { useI18n, type DictKey } from '../../i18n';
import { ApiError, errorToKey } from '../../lib/errors';
import { authApi } from './authApi';
import { RateLimitAlert } from './RateLimitAlert';
import { forgotSchema, type ForgotValues } from './schemas';
import { useCountdown } from './useCountdown';

type FormError = { kind: 'key'; key: DictKey } | { kind: 'rate' };

export function ForgotPasswordPage() {
  const { t } = useI18n();
  const countdown = useCountdown();
  const [formError, setFormError] = useState<FormError | null>(null);

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<ForgotValues>({
    resolver: zodResolver(forgotSchema),
    mode: 'onSubmit',
    reValidateMode: 'onChange',
    defaultValues: { email: '' },
  });

  const forgot = useMutation({
    mutationFn: (values: ForgotValues) => authApi.forgotPassword(values.email),
    onError: (error) => {
      if (error instanceof ApiError && error.status === 429) {
        countdown.start(error.retryAfterSeconds ?? 30);
        setFormError({ kind: 'rate' });
      } else {
        setFormError({ kind: 'key', key: errorToKey(error) });
      }
    },
  });

  const onSubmit = handleSubmit((values) => {
    if (forgot.isPending || countdown.remaining > 0) return;
    setFormError(null);
    forgot.mutate(values);
  });

  const emailError = errors.email?.message ? t(errors.email.message as DictKey) : undefined;

  return (
    <AuthLayout>
      <h1 className="text-2xl font-semibold text-text">{t('forgot.title')}</h1>

      {forgot.isSuccess ? (
        // Same message for every 202: never reveals whether the email exists.
        <div className="mt-6">
          <Alert variant="success" role="status">
            {t('forgot.sent')}
          </Alert>
        </div>
      ) : (
        <form noValidate onSubmit={onSubmit} className="mt-6">
          <p className="mb-5 text-sm text-text-muted">{t('forgot.hint')}</p>
          <fieldset disabled={forgot.isPending} className="min-w-0 space-y-5">
            <Input
              label={t('login.email')}
              type="email"
              autoComplete="username"
              inputMode="email"
              autoCapitalize="none"
              spellCheck={false}
              error={emailError}
              {...register('email')}
            />
            {formError?.kind === 'key' && (
              <Alert variant="danger" role="alert">
                {t(formError.key)}
              </Alert>
            )}
            {formError?.kind === 'rate' && countdown.remaining > 0 && <RateLimitAlert remaining={countdown.remaining} />}
            <Button type="submit" fullWidth loading={forgot.isPending} disabled={countdown.remaining > 0}>
              {forgot.isPending ? t('forgot.submitting') : t('forgot.submit')}
            </Button>
          </fieldset>
        </form>
      )}

      <p className="mt-6 text-center">
        <Link to="/login" className="inline-flex min-h-11 items-center text-sm font-medium text-link hover:underline">
          {t('common.backToLogin')}
        </Link>
      </p>
    </AuthLayout>
  );
}
