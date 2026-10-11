import { useI18n, type DictKey } from '../i18n';
import { useTheme, type Theme } from '../theme/ThemeProvider';
import { MonitorIcon, MoonIcon, SunIcon } from './icons';

const OPTIONS: { theme: Theme; key: DictKey; Icon: typeof SunIcon }[] = [
  { theme: 'light', key: 'theme.light', Icon: SunIcon },
  { theme: 'dark', key: 'theme.dark', Icon: MoonIcon },
  { theme: 'system', key: 'theme.system', Icon: MonitorIcon },
];

export function ThemeToggle() {
  const { theme, setTheme } = useTheme();
  const { t } = useI18n();
  return (
    <div role="group" aria-label={t('theme.label')} className="flex items-center rounded-md border border-border">
      {OPTIONS.map(({ theme: value, key, Icon }) => (
        <button
          key={value}
          type="button"
          aria-pressed={theme === value}
          aria-label={t(key)}
          title={t(key)}
          onClick={() => setTheme(value)}
          className={`flex h-11 w-11 items-center justify-center rounded-md lg:h-9 lg:w-9 ${
            theme === value ? 'bg-panel text-text' : 'text-text-muted hover:text-text'
          }`}
        >
          <Icon width={18} height={18} />
        </button>
      ))}
    </div>
  );
}
