import { useI18n, type Lang } from '../i18n';

const OPTIONS: { lang: Lang; label: string; aria: 'lang.en' | 'lang.mr' }[] = [
  { lang: 'en', label: 'EN', aria: 'lang.en' },
  { lang: 'mr', label: 'मराठी', aria: 'lang.mr' },
];

export function LanguageSwitch() {
  const { lang, setLang, t } = useI18n();
  return (
    <div role="group" aria-label={t('lang.label')} className="flex items-center">
      {OPTIONS.map((o, i) => (
        <span key={o.lang} className="flex items-center">
          {i > 0 && (
            <span aria-hidden="true" className="text-text-muted">
              |
            </span>
          )}
          <button
            type="button"
            lang={o.lang}
            aria-pressed={lang === o.lang}
            aria-label={t(o.aria)}
            onClick={() => setLang(o.lang)}
            className={`min-h-11 rounded-md px-2.5 text-sm lg:min-h-9 ${
              lang === o.lang ? 'font-semibold text-text' : 'text-text-muted hover:text-text'
            }`}
          >
            {o.label}
          </button>
        </span>
      ))}
    </div>
  );
}
