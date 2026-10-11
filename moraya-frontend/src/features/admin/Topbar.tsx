import { MenuIcon } from '../../components/icons';
import { LanguageSwitch } from '../../components/LanguageSwitch';
import { ThemeToggle } from '../../components/ThemeToggle';
import { useI18n } from '../../i18n';
import { UserMenu } from './UserMenu';

interface TopbarProps {
  title: string;
  menuOpen: boolean;
  onOpenMenu: () => void;
}

export function Topbar({ title, menuOpen, onOpenMenu }: TopbarProps) {
  const { t } = useI18n();
  return (
    <header className="sticky top-0 z-20 flex h-14 items-center gap-2 border-b border-border bg-background px-3 sm:px-6">
      <button
        type="button"
        onClick={onOpenMenu}
        aria-label={t('nav.open')}
        aria-expanded={menuOpen}
        aria-controls="admin-drawer"
        className="flex h-11 w-11 shrink-0 items-center justify-center rounded-md text-text-muted hover:bg-panel hover:text-text lg:hidden"
      >
        <MenuIcon />
      </button>
      <p className="min-w-0 flex-1 truncate font-semibold" style={{ lineHeight: 'var(--lh-heading)' }}>
        {title}
      </p>
      <div className="hidden items-center gap-3 md:flex">
        <LanguageSwitch />
        <ThemeToggle />
      </div>
      <UserMenu />
    </header>
  );
}
