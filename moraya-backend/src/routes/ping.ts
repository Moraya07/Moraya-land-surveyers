import { Hono } from 'hono';
import type { AppEnv } from '../env';
import { requireAuth } from '../middleware/auth';
import { requirePermission, requireRole } from '../middleware/rbac';

// Sample protected routes proving the guards work. Remove or replace in later phases.
export const ping = new Hono<AppEnv>();

ping.get('/worker/ping', requireAuth, (c) => c.json({ ok: true, role: c.get('auth').role }));

ping.get('/admin/ping', requireAuth, requireRole('main_admin', 'sub_admin'), (c) =>
  c.json({ ok: true, role: c.get('auth').role }),
);

ping.get('/admin/report-ping', requireAuth, requireRole('main_admin', 'sub_admin'), requirePermission('report_view'), (c) =>
  c.json({ ok: true }),
);
