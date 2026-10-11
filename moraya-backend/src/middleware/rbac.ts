import type { Context, MiddlewareHandler } from 'hono';
import type { AppEnv, Permission, Role } from '../env';
import { AppError } from '../lib/errors';
import { clientIp, defer, userAgent } from '../lib/request';
import { writeAudit } from '../services/audit';

/** main_admin implicitly has every permission; sub_admin only what is granted; worker none. */
export function hasPermission(user: { role: Role; permissions: readonly string[] }, permission: Permission): boolean {
  return user.role === 'main_admin' || (user.role === 'sub_admin' && user.permissions.includes(permission));
}

// ACCESS_DENIED audit noise control: at most one row per employee + path per minute (per isolate).
const recentDenials = new Map<string, number>();
const DENIAL_WINDOW_MS = 60_000;

function auditDenied(c: Context<AppEnv>, required: string): void {
  const auth = c.get('auth');
  const key = `${auth.employee.id}:${c.req.path}`;
  const now = Date.now();
  if (now - (recentDenials.get(key) ?? 0) < DENIAL_WINDOW_MS) return;
  if (recentDenials.size > 500) recentDenials.clear();
  recentDenials.set(key, now);
  defer(
    c,
    writeAudit(c.env, {
      action: 'ACCESS_DENIED',
      actorEmployeeId: auth.employee.id,
      entityType: 'route',
      entityId: c.req.path,
      ip: clientIp(c),
      userAgent: userAgent(c),
      reason: `REQUIRED_${required}`,
      requestId: c.get('requestId'),
    }),
  );
}

/** Use after requireAuth. Always 403 (never 404) on failure. */
export const requireRole =
  (...roles: Role[]): MiddlewareHandler<AppEnv> =>
  async (c, next) => {
    if (!roles.includes(c.get('auth').role)) {
      auditDenied(c, roles.join('|'));
      throw new AppError(403, 'FORBIDDEN');
    }
    await next();
  };

export const requirePermission =
  (permission: Permission): MiddlewareHandler<AppEnv> =>
  async (c, next) => {
    if (!hasPermission(c.get('auth'), permission)) {
      auditDenied(c, permission);
      throw new AppError(403, 'FORBIDDEN');
    }
    await next();
  };
