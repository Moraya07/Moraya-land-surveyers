import { Hono } from 'hono';
import { assertEnv, type AppEnv } from './env';
import { AppError, jsonError } from './lib/errors';
import { csrf } from './middleware/csrf';
import { requestId } from './middleware/requestId';
import { securityHeaders } from './middleware/security';
import { auth } from './routes/auth';
import { ping } from './routes/ping';

const app = new Hono<AppEnv>();

app.use('*', requestId);
app.use('*', securityHeaders);
app.use('*', async (c, next) => {
  assertEnv(c.env); // throws on misconfiguration -> generic 500, details in logs (names only)
  await next();
});
app.use('/api/*', csrf);

app.route('/api/auth', auth);
app.route('/api', ping);

app.notFound((c) => {
  if (!c.req.path.startsWith('/api/') && c.env.ASSETS) return c.env.ASSETS.fetch(c.req.raw);
  return jsonError(c, new AppError(404, 'NOT_FOUND'));
});

app.onError((err, c) => {
  if (err instanceof AppError) return jsonError(c, err);
  // Short log with correlation id. No stack, no request data, no upstream bodies.
  console.error(`unhandled error rid=${c.get('requestId')} name=${err.name} msg=${err.message.slice(0, 120)}`);
  return jsonError(c, new AppError(500, 'INTERNAL_ERROR'));
});

export default app;
