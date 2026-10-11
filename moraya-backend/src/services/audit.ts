import { supabaseUrl, type Env } from '../env';
import { serviceHeaders } from './supabaseRest';

export interface AuditEntry {
  action: string;
  actorEmployeeId?: string | null;
  entityType?: string | null;
  entityId?: string | null;
  ip?: string | null;
  userAgent?: string | null;
  newValue?: Record<string, unknown> | null;
  reason?: string | null;
  requestId: string;
}

/** Best-effort, never throws. Callers must never put passwords or tokens in an entry. */
export async function writeAudit(env: Env, e: AuditEntry): Promise<void> {
  try {
    const res = await fetch(`${supabaseUrl(env)}/rest/v1/audit_logs`, {
      method: 'POST',
      headers: serviceHeaders(env, { Prefer: 'return=minimal' }),
      body: JSON.stringify({
        action: e.action,
        actor_employee_id: e.actorEmployeeId ?? null,
        entity_type: e.entityType ?? null,
        entity_id: e.entityId ?? null,
        ip: e.ip ?? null,
        user_agent: e.userAgent ?? null,
        new_value: e.newValue ?? null,
        reason: e.reason ?? null,
        request_id: e.requestId,
      }),
    });
    if (!res.ok) console.warn(`audit write failed: status ${res.status} rid=${e.requestId}`);
  } catch {
    console.warn(`audit write failed: network rid=${e.requestId}`);
  }
}
