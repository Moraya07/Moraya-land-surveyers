import { useEffect, useState } from 'react';
import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useForm } from 'react-hook-form';
import { Link, Navigate, useNavigate } from 'react-router-dom';
import { AuthLayout } from '../../components/AuthLayout';
import { PageSkeleton } from '../../components/PageSkeleton';
import { Alert } from '../../components/ui/Alert';
import { Button } from '../../components/ui/Button';
import { Input } from '../../components/ui/Input';
import { PasswordInput } from '../../components/ui/PasswordInput';
import { useI18n, type DictKey } from '../../i18n';
import { ApiError, errorToKey } from '../../lib/errors';
import { authApi } from './authApi';
import { RateLimitAlert } from './RateLimitAlert';
import { homeFor, safeRedirect } from './routes';
import { loginSchema, type LoginValues } from './schemas';
import { useCountdown } from './useCountdown';
import { sessionKey, useSession } from './useSession';

type FormError = { kind: 'key'; key: DictKey } | { kind: 'rate' };

export function LoginPage() {
  const { t } = useI18n();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const session = useSession();
  const countdown = useCountdown();
  const [formError, setFormError] = useState<FormError | null>(null);

  const {
    register,
    handleSubmit,
    setFocus,
    formState: { errors },
  } = useForm<LoginValues>({
    resolver: zodResolver(loginSchema),
    mode: 'onSubmit',
    reValidateMode: 'onChange',
    defaultValues: { email: '', password: '' },
  });

  const login = useMutation({
    mutationFn: authApi.login,
    onSuccess: (data) => {
      queryClient.setQueryData(sessionKey, data.user);
      navigate(safeRedirect(data.redirectTo, data.user.role), { replace: true });
    },
    onError: (error) => {
      if (error instanceof ApiError && error.status === 429) {
        countdown.start(error.retryAfterSeconds ?? 30);
        setFormError({ kind: 'rate' });
      } else {
        setFormError({ kind: 'key', key: errorToKey(error) });
      }
    },
  });

  // Autofocus on desktop only (avoids opening the keyboard on phones).
  useEffect(() => {
    if (window.matchMedia('(min-width: 1024px)').matches) setFocus('email');
  }, [setFocus]);

  // Put focus back on the password after a failed sign-in (inputs are re-enabled by then).
  const wrongCredentials = login.isError && login.error instanceof ApiError && login.error.status === 401;
  useEffect(() => {
    if (wrongCredentials) setFocus('password');
  }, [wrongCredentials, setFocus]);

  const onSubmit = handleSubmit((values) => {
    if (login.isPending || countdown.remaining > 0) return;
    setFormError(null);
    login.mutate(values);
  });

  if (session.isPending) return <PageSkeleton />;
  if (session.data) return <Navigate to={homeFor(session.data.role)} replace />;

  const fieldMessage = (message?: string) => (message ? t(message as DictKey) : undefined);

  return (
    <AuthLayout>
      <h1 className="text-2xl font-semibold text-text">{t('login.title')}</h1>

      <form noValidate onSubmit={onSubmit} className="mt-6">
        <fieldset disabled={login.isPending} className="min-w-0 space-y-5">
          <Input
            label={t('login.email')}
            type="email"
            autoComplete="username"
            inputMode="email"
            autoCapitalize="none"
            spellCheck={false}
            error={fieldMessage(errors.email?.message)}
            {...register('email')}
          />
          <div>
            <PasswordInput
              label={t('login.password')}
              autoComplete="current-password"
              error={fieldMessage(errors.password?.message)}
              {...register('password')}
            />
            <div className="mt-1 flex justify-end">
              <Link to="/forgot-password" className="inline-flex min-h-11 items-center text-sm font-medium text-link hover:underline">
                {t('login.forgot')}
              </Link>
            </div>
          </div>

          {formError?.kind === 'key' && (
            <Alert variant="danger" role="alert">
              {t(formError.key)}
            </Alert>
          )}
          {formError?.kind === 'rate' && countdown.remaining > 0 && <RateLimitAlert remaining={countdown.remaining} />}

          <Button type="submit" fullWidth loading={login.isPending} disabled={countdown.remaining > 0}>
            {login.isPending ? t('login.submitting') : t('login.submit')}
          </Button>
        </fieldset>
      </form>

      <p className="mt-6 text-center text-sm text-text-muted">{t('login.noAccount')}</p>
    </AuthLayout>
  );
}
