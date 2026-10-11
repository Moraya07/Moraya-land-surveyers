import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import { ChevronDownIcon, LogOutIcon } from '../../components/icons';
import { LanguageSwitch } from '../../components/LanguageSwitch';
import { ThemeToggle } from '../../components/ThemeToggle';
import { Button } from '../../components/ui/Button';
import { Menu } from '../../components/ui/Menu';
import { useI18n } from '../../i18n';
import { authApi } from '../auth/authApi';
import { sessionKey, useSession } from '../auth/useSession';

function initials(name: string): string {
  const letters = name
    .trim()
    .split(/\s+/)
    .slice(0, 2)
    .map((word) => Array.from(word)[0] ?? '');
  return letters.join('').toUpperCase();
}

export function UserMenu() {
  const { t } = useI18n();
  const { data: user } = useSession();
  const queryClient = useQueryClient();
  const navigate = useNavigate();

  const logout = useMutation({
    mutationFn: authApi.logout,
    onSettled: () => {
      queryClient.clear(); // nothing from this session stays in memory
      queryClient.setQueryData(sessionKey, null);
      navigate('/login', { replace: true });
    },
  });

  if (!user) return null;

  return (
    <Menu
      label={t('menu.account')}
      trigger={
        <>
          <span
            aria-hidden="true"
            className="flex h-8 w-8 items-center justify-center rounded-full bg-panel text-xs font-semibold"
          >
            {initials(user.name)}
          </span>
          <span className="hidden max-w-[10rem] truncate text-sm font-medium md:block">{user.name}</span>
          <ChevronDownIcon width={16} height={16} className="text-text-muted" />
        </>
      }
    >
      {() => (
        <div className="space-y-3">
          <div className="min-w-0">
            <p className="truncate font-medium">{user.name}</p>
            <p className="text-sm text-text-muted">{t(`role.${user.role}`)}</p>
          </div>
          {/* On narrow screens the language and theme controls live here to keep the top bar uncluttered. */}
          <div className="flex items-center justify-between gap-3 border-t border-border pt-3 md:hidden">
            <LanguageSwitch />
            <ThemeToggle />
          </div>
          <div className="border-t border-border pt-3">
            <Button variant="secondary" fullWidth loading={logout.isPending} onClick={() => logout.mutate()}>
              <LogOutIcon width={16} height={16} />
              {t('common.logout')}
            </Button>
          </div>
        </div>
      )}
    </Menu>
  );
}
