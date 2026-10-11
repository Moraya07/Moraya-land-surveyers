# Moraya Land Surveyors: Frontend (login phase)

React 18 + TypeScript (strict) + Vite + Tailwind + React Hook Form + Zod + TanStack Query + React Router.
Scope: `/login`, `/forgot-password`, session bootstrap, route guard, placeholder `/admin` and `/home`.
The frontend talks only to the Worker API at `/api/*`. No secrets, no Supabase keys, no tokens in JS.

## Install and run
```bash
npm install
npm run dev        # http://localhost:5173, proxies /api to http://127.0.0.1:8787 (Worker must be running)
npm run build      # type-check + production build
npm run lint
```

## Logo
Original files are in `src/assets/brand/` (`moraya-logo.svg` is used; `.png` is kept for reference).
The artwork is black + red for light backgrounds, so on dark theme `<Logo />` places it on a white plate.
To use a dark-surface variant later, edit `src/components/Logo.tsx` only. If the image fails to load, a text wordmark shows.
Favicon and PWA icons in `public/icons/` were generated from the supplied logo on white: review them.

## Fonts
`@fontsource-variable/inter` and `@fontsource-variable/noto-sans-devanagari` are bundled by Vite and served from your own origin
(woff2, `font-display: swap`, no Google Fonts links). The browser downloads only the Latin / Devanagari files actually used.

## Add a language key
1. Add it to `src/i18n/en.ts`. 2. TypeScript will then fail until the same key exists in `src/i18n/mr.ts`. 3. Use `t('your.key')`.
To add a language: create `xx.ts` typed as `Dictionary`, register it in `src/i18n/index.tsx`.
**Marathi strings are a draft and need native-speaker review.**

## Manual test checklist
- [ ] Valid admin login (main_admin and sub_admin) lands on `/admin`; worker lands on `/home`
- [ ] Wrong email/password shows "Incorrect email or password."; focus returns to password; same message for unknown email
- [ ] Inactive and revoked accounts show their own calm messages
- [ ] 429: banner counts down, submit disabled until it ends, then works again
- [ ] Server stopped / offline: network message, email still filled, form usable again
- [ ] Empty fields, bad email, 255-char email, 129-char password show inline errors with `aria-invalid`
- [ ] Visiting `/login` while signed in redirects immediately; Back after login does not return to `/login`
- [ ] Logout returns to `/login`; Back does not show a protected page with data
- [ ] Expired access token + valid refresh: `/admin` still loads (one `/auth/refresh` call); expired refresh sends you to `/login`
- [ ] Worker opening `/admin` goes to `/home`; admin opening `/home` goes to `/admin`
- [ ] Forgot password: same success text for any email; 429 handled like login
- [ ] EN/MR switch is instant, persists after reload, no layout jump, no clipped Devanagari
- [ ] Light / Dark / System: no flash on reload; System follows OS change live
- [ ] 320px width: no horizontal scroll; inputs/buttons >= 44px; no iOS zoom on focus
- [ ] Keyboard only: tab order logical, focus ring visible, Enter submits, show/hide password works
- [ ] Screen reader: labels announced, errors announced once, countdown not announced every second
- [ ] Password manager fills email + password

## Assumptions
- Brand colour `#d71f26` and ink `#111` are taken from your approved screen mockups.
- `/auth/me` also tries one refresh on 401 so a returning user with only an expired access token stays signed in.
- For an already-signed-in visit to `/login`, the destination is derived from `user.role` (`/me` returns no `redirectTo`).
- Server `redirectTo` is accepted only if it is a same-origin path; otherwise role default is used.
- Only `moraya.lang` and `moraya.theme` are stored in localStorage.
- No service worker; when one is added it must never cache `/api/*`.
