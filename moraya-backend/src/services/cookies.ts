import type { Context } from 'hono';
import { isInsecureDev, type Env } from '../env';

export interface SessionTokens {
  accessToken: string;
  refreshToken: string;
  expiresIn: number; // seconds
}

export function cookieNames(env: Env): { at: string; rt: string } {
  return isInsecureDev(env)
    ? { at: 'moraya_at', rt: 'moraya_rt' }
    : { at: '__Host-moraya_at', rt: '__Host-moraya_rt' };
}

function build(env: Env, name: string, value: string, maxAge: number): string {
  // __Host- prefix: Secure, Path=/, no Domain. HttpOnly + SameSite=Strict always.
  return `${name}=${value}; Max-Age=${maxAge}; Path=/; HttpOnly; SameSite=Strict${isInsecureDev(env) ? '' : '; Secure'}`;
}

export function setSessionCookies(c: Context, env: Env, tokens: SessionTokens): void {
  const names = cookieNames(env);
  const refreshMaxAge = Number(env.REFRESH_COOKIE_DAYS) * 86400;
  c.header('Set-Cookie', build(env, names.at, tokens.accessToken, Math.max(1, Math.floor(tokens.expiresIn))), { append: true });
  c.header('Set-Cookie', build(env, names.rt, tokens.refreshToken, refreshMaxAge), { append: true });
}

export function clearSessionCookies(c: Context, env: Env): void {
  const names = cookieNames(env);
  c.header('Set-Cookie', build(env, names.at, '', 0), { append: true });
  c.header('Set-Cookie', build(env, names.rt, '', 0), { append: true });
}

export function readCookie(header: string | undefined, name: string): string | null {
  if (!header) return null;
  for (const part of header.split(';')) {
    const idx = part.indexOf('=');
    if (idx > 0 && part.slice(0, idx).trim() === name) return part.slice(idx + 1).trim() || null;
  }
  return null;
}
