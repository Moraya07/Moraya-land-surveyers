import type { MiddlewareHandler } from 'hono';
import type { AppEnv } from '../env';

export const securityHeaders: MiddlewareHandler<AppEnv> = async (c, next) => {
  await next();
  // Copy first: responses from the assets binding have immutable headers.
  c.res = new Response(c.res.body, c.res);
  const h = c.res.headers;
  h.set('X-Content-Type-Options', 'nosniff');
  h.set('Referrer-Policy', 'same-origin');
  h.set('X-Frame-Options', 'DENY');
  if (c.env.ENVIRONMENT === 'production') h.set('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
  if (c.req.path.startsWith('/api/')) h.set('Cache-Control', 'no-store'); // covers /api/auth/*
};
