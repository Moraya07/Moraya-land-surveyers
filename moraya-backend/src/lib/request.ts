import type { Context } from 'hono';

const IP_PATTERN = /^[0-9a-fA-F:.]{3,45}$/;

export function clientIp(c: Context): string | null {
  const ip = c.req.header('CF-Connecting-IP');
  return ip && IP_PATTERN.test(ip) ? ip : null;
}

export function userAgent(c: Context): string | null {
  return c.req.header('User-Agent')?.slice(0, 200) ?? null;
}

/** Run a promise after the response (waitUntil); never throws; works without an execution context (tests). */
export function defer(c: Context, promise: Promise<unknown>): void {
  const guarded = promise.catch(() => undefined);
  try {
    c.executionCtx.waitUntil(guarded);
  } catch {
    /* no execution context: the promise still runs */
  }
}
