import type { ReactNode } from 'react';
import { useI18n } from '../i18n';
import { LanguageSwitch } from './LanguageSwitch';
import { Logo } from './Logo';
import { ThemeToggle } from './ThemeToggle';

/**
 * Shared shell for the sign-in screens. Layout follows the approved login mockup:
 * dark brand panel + form on desktop, logo on top + form on mobile.
 * Language and theme controls sit top-right on desktop and in the footer on mobile,
 * so the mockup's own layout is left untouched.
 */
export function AuthLayout({ children }: { children: ReactNode }) {
  const { t } = useI18n();
  const footer = t('footer', { year: new Date().getFullYear() });

  return (
    <div className="auth">
      <aside className="auth-brand">
        <div className="auth-brand-inner">
          <Logo className="auth-brand-logo" />
          <div className="auth-brand-copy">
            <h2>{t('brand.headline')}</h2>
            <ul>
              <li>{t('brand.point1')}</li>
              <li>{t('brand.point2')}</li>
              <li>{t('brand.point3')}</li>
            </ul>
          </div>
          <small className="auth-brand-foot">{footer}</small>
        </div>
      </aside>

      <div className="auth-side">
        <div className="auth-controls-desktop">
          <LanguageSwitch />
          <ThemeToggle />
        </div>
        <div className="auth-col auth-main">
          <Logo className="auth-mobile-logo" />
          {children}
        </div>
        <footer className="auth-col auth-foot">
          <div className="auth-foot-controls">
            <LanguageSwitch />
            <ThemeToggle />
          </div>
          {footer}
        </footer>
      </div>
    </div>
  );
}
