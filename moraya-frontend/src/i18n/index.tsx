import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { en, type DictKey, type Dictionary } from './en';
import { mr } from './mr';

export type Lang = 'en' | 'mr';
export type { DictKey };
type Params = Record<string, string | number>;

const dictionaries: Record<Lang, Dictionary> = { en, mr };
const STORAGE_KEY = 'moraya.lang';

function readStoredLang(): Lang {
  try {
    return localStorage.getItem(STORAGE_KEY) === 'mr' ? 'mr' : 'en';
  } catch {
    return 'en';
  }
}

interface I18nValue {
  lang: Lang;
  setLang: (lang: Lang) => void;
  t: (key: DictKey, params?: Params) => string;
}

const I18nContext = createContext<I18nValue | null>(null);

export function I18nProvider({ children }: { children: ReactNode }) {
  const [lang, setLangState] = useState<Lang>(readStoredLang);

  useEffect(() => {
    document.documentElement.lang = lang;
  }, [lang]);

  const setLang = useCallback((next: Lang) => {
    setLangState(next);
    try {
      localStorage.setItem(STORAGE_KEY, next);
    } catch {
      /* storage unavailable: keep in-memory only */
    }
  }, []);

  const t = useCallback(
    (key: DictKey, params?: Params) => {
      const template = dictionaries[lang][key];
      if (!params) return template;
      return template.replace(/\{(\w+)\}/g, (match, name: string) => {
        const value = params[name];
        return value === undefined ? match : String(value);
      });
    },
    [lang],
  );

  const value = useMemo(() => ({ lang, setLang, t }), [lang, setLang, t]);
  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n(): I18nValue {
  const ctx = useContext(I18nContext);
  if (!ctx) throw new Error('useI18n must be used inside <I18nProvider>');
  return ctx;
}
