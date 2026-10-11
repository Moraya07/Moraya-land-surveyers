import type { MiddlewareHandler } from 'hono';
import type { AppEnv } from '../env';
import { AppError } from '../lib/errors';

const SAFE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);

function originOf(value: string | undefined): string | null {
  if (!value) return null;
  try {
    return new URL(value).origin;
  } catch {
    return null;
  }
}

/** State-changing routes need the custom header AND an Origin (or Referer) equal to ALLOWED_ORIGIN. */
export const csrf: MiddlewareHandler<AppEnv> = async (c, next) => {
  if (!SAFE_METHODS.has(c.req.method)) {
    const allowed = originOf(c.env.ALLOWED_ORIGIN);
    const origin = c.req.header('Origin') ? originOf(c.req.header('Origin')) : originOf(c.req.header('Referer'));
    if (c.req.header('X-Requested-With') !== 'moraya-web' || !allowed || origin !== allowed) {
      throw new AppError(403, 'FORBIDDEN');
    }
  }
  await next();
};
