import type { ReactNode } from 'react';
import { useI18n } from '../i18n';
import { LanguageSwitch } from './LanguageSwitch';
import { Logo } from './Logo';
import { ThemeToggle } from './ThemeToggle';

export function AuthLayout({ children }: { children: ReactNode }) {
  const { t } = useI18n();
  const footer = t('footer', { year: new Date().getFullYear() });

  return (
    <div className="min-h-dvh lg:grid lg:grid-cols-[45fr_55fr]">
      {/* Brand panel (desktop only) */}
      <aside className="hidden flex-col justify-between border-e border-border bg-panel p-12 lg:flex">
        <Logo className="h-40" />
        <div className="max-w-sm">
          <div className="mb-4 h-1 w-10 bg-primary" aria-hidden="true" />
          <p className="text-2xl font-semibold text-text">{t('brand.product')}</p>
          <p className="mt-2 text-base text-text-muted">{t('brand.tagline')}</p>
        </div>
        <p className="text-sm text-text-muted">{footer}</p>
      </aside>

      <div className="flex min-h-dvh flex-col">
        <header className="flex items-center justify-end gap-3 p-4 lg:p-6">
          <LanguageSwitch />
          <ThemeToggle />
        </header>
        <main className="flex flex-1 flex-col justify-center px-4 pb-10 sm:px-6">
          <div className="mx-auto w-full max-w-[400px]">
            <div className="mb-8 lg:hidden">
              <Logo className="h-24" />
            </div>
            {children}
          </div>
        </main>
        <footer className="px-4 pb-6 text-center text-sm text-text-muted lg:hidden">{footer}</footer>
      </div>
    </div>
  );
}
