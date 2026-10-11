import { useEffect, useId, useRef, useState } from 'react';
import { useI18n } from '../../i18n';
import { SearchIcon, XIcon } from '../icons';

interface SearchInputProps {
  /** The committed value (what the list is currently filtered by). */
  value: string;
  onChange: (value: string) => void;
  /** Accessible name; also used as the placeholder unless one is given. */
  label: string;
  placeholder?: string;
  /** Debounce in ms (300 to 500 recommended). */
  delay?: number;
}

/** Debounced search box with a clear button. Enter commits immediately. */
export function SearchInput({ value, onChange, label, placeholder, delay = 400 }: SearchInputProps) {
  const { t } = useI18n();
  const inputId = useId();
  const [text, setText] = useState(value);
  const lastEmitted = useRef(value);
  const onChangeRef = useRef(onChange);

  useEffect(() => {
    onChangeRef.current = onChange;
  }, [onChange]);

  // External changes (e.g. "reset filters") replace what is typed.
  useEffect(() => {
    if (value !== lastEmitted.current) {
      lastEmitted.current = value;
      setText(value);
    }
  }, [value]);

  // Debounced commit.
  useEffect(() => {
    if (text === lastEmitted.current) return;
    const timer = setTimeout(() => {
      lastEmitted.current = text;
      onChangeRef.current(text);
    }, delay);
    return () => clearTimeout(timer);
  }, [text, delay]);

  const commitNow = (next: string) => {
    lastEmitted.current = next;
    onChangeRef.current(next);
  };

  return (
    <div className="relative" role="search">
      <label htmlFor={inputId} className="sr-only">
        {label}
      </label>
      <SearchIcon
        width={18}
        height={18}
        className="pointer-events-none absolute start-3 top-1/2 -translate-y-1/2 text-text-muted"
      />
      <input
        id={inputId}
        type="search"
        value={text}
        placeholder={placeholder ?? label}
        autoComplete="off"
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter') {
            e.preventDefault();
            commitNow(text);
          }
        }}
        className="input !h-11 ps-10 pe-11 [&::-webkit-search-cancel-button]:hidden [&::-webkit-search-decoration]:hidden"
      />
      {text !== '' && (
        <button
          type="button"
          aria-label={t('search.clear')}
          onClick={() => {
            setText('');
            commitNow('');
            document.getElementById(inputId)?.focus();
          }}
          className="absolute end-1 top-1/2 flex h-11 w-11 -translate-y-1/2 items-center justify-center rounded-md text-text-muted hover:text-text"
        >
          <XIcon width={16} height={16} />
        </button>
      )}
    </div>
  );
}
