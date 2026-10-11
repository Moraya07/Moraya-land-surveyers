import type { Config } from 'tailwindcss';

// Colors are CSS-variable channels so one class works in light and dark.
const c = (name: string) => `rgb(var(--c-${name}) / <alpha-value>)`;

export default {
  darkMode: 'class',
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        background: c('background'),
        surface: c('surface'),
        panel: c('panel'),
        border: c('border'),
        field: c('field'),
        text: { DEFAULT: c('text'), muted: c('text-muted') },
        primary: { DEFAULT: c('primary'), foreground: c('primary-foreground'), hover: c('primary-hover') },
        link: c('link'),
        danger: { DEFAULT: c('danger'), subtle: c('danger-subtle') },
        success: { DEFAULT: c('success'), subtle: c('success-subtle') },
        warning: { DEFAULT: c('warning'), subtle: c('warning-subtle') },
        info: { DEFAULT: c('info'), subtle: c('info-subtle') },
      },
      fontFamily: {
        sans: [
          '"Inter Variable"',
          '"Noto Sans Devanagari Variable"',
          'system-ui',
          '-apple-system',
          '"Segoe UI"',
          'Roboto',
          'sans-serif',
        ],
      },
      // Type scale. Line-height comes from variables so Marathi gets more room.
      fontSize: {
        xs: ['0.75rem', { lineHeight: 'var(--lh-body)' }],
        sm: ['0.875rem', { lineHeight: 'var(--lh-body)' }],
        base: ['1rem', { lineHeight: 'var(--lh-body)' }],
        lg: ['1.125rem', { lineHeight: 'var(--lh-heading)' }],
        xl: ['1.25rem', { lineHeight: 'var(--lh-heading)' }],
        '2xl': ['1.5rem', { lineHeight: 'var(--lh-heading)' }],
        '3xl': ['1.875rem', { lineHeight: 'var(--lh-heading)' }],
      },
      borderRadius: { DEFAULT: '4px', md: '6px', lg: '8px' },
    },
  },
  plugins: [],
} satisfies Config;
