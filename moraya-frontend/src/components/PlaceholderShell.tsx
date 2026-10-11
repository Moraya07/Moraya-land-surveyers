import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import { authApi } from '../features/auth/authApi';
import { sessionKey, useSession } from '../features/auth/useSession';
import { useI18n } from '../i18n';
import { LanguageSwitch } from './LanguageSwitch';
import { Logo } from './Logo';
import { ThemeToggle } from './ThemeToggle';
import { Button } from './ui/Button';

export function PlaceholderShell({ title }: { title: string }) {
  const { t } = useI18n();
  const { data: user } = useSession();
  const queryClient = useQueryClient();
  const navigate = useNavigate();

  const logout = useMutation({
    mutationFn: authApi.logout,
    onSettled: () => {
      queryClient.clear();
      queryClient.setQueryData(sessionKey, null);
      navigate('/login', { replace: true });
    },
  });

  return (
    <div className="min-h-dvh">
      <header className="flex items-center justify-between gap-3 border-b border-border p-4">
        <Logo className="w-9" />
        <div className="flex items-center gap-3">
          <LanguageSwitch />
          <ThemeToggle />
        </div>
      </header>
      <main className="mx-auto max-w-2xl px-4 py-10">
        <h1 className="text-2xl font-semibold">{title}</h1>
        {user && (
          <p className="mt-2 text-text-muted">
            {t('placeholder.signedInAs')} <span className="font-medium text-text">{user.name}</span> ·{' '}
            {t(`role.${user.role}`)}
          </p>
        )}
        <p className="mt-4 text-sm text-text-muted">{t('placeholder.note')}</p>
        <div className="mt-6">
          <Button variant="secondary" loading={logout.isPending} onClick={() => logout.mutate()}>
            {t('common.logout')}
          </Button>
        </div>
      </main>
    </div>
  );
}
