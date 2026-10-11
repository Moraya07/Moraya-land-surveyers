import type { ActivityChange, ActivityItem } from '../types';
import { buildDemoHistory } from './demoHistory';
import { MAIN_ADMIN_ID, SUB_ADMIN_ID, buildSeed, type StoredEmployee } from './seed';

export type Scenario = 'main' | 'sub' | 'error' | 'slow' | 'malformed' | 'conflict';

export interface Actor {
  id: string;
  name: string;
  isMain: boolean;
}

interface Store {
  employees: StoredEmployee[];
  audit: Map<string, ActivityItem[]>;
  revealTimes: number[];
}

let store: Store | null = null;

/** Lazily seeded, lives in memory only (a page reload resets it). */
export function getStore(): Store {
  if (!store) {
    store = { employees: buildSeed(), audit: new Map(), revealTimes: [] };
    for (const e of store.employees) {
      store.audit.set(e.id, [
        {
          id: `a-${e.id}-0`,
          at: e.createdAt,
          action: 'USER_CREATED',
          actorName: e.createdByName,
          reason: null,
          changes: null,
        },
      ]);
    }
    // One employee gets a long trail (59 entries) so "Load more" and the edge cases can be tried straight away.
    const demo = store.employees.find((e) => e.name === 'Vikram Patil');
    if (demo) {
      const created = store.audit.get(demo.id) ?? [];
      store.audit.set(demo.id, [...created, ...buildDemoHistory(demo.id, Date.now())]);
    }
  }
  return store;
}

export function findEmployee(id: string): StoredEmployee | undefined {
  return getStore().employees.find((e) => e.id === id);
}

let auditCounter = 0;

/** Never pass an Aadhaar value in `changes`: record the field name only. */
export function addAudit(
  employeeId: string,
  entry: { action: string; actor: Actor; reason?: string | null; changes?: ActivityChange[] | null },
): void {
  const list = getStore().audit.get(employeeId) ?? [];
  auditCounter += 1;
  list.push({
    id: `a-${employeeId}-${Date.now()}-${auditCounter}`,
    at: new Date().toISOString(),
    action: entry.action,
    actorName: entry.actor.name,
    reason: entry.reason ?? null,
    changes: entry.changes ?? null,
  });
  getStore().audit.set(employeeId, list);
}

export function getActor(scenario: Scenario): Actor {
  const id = scenario === 'sub' ? SUB_ADMIN_ID : MAIN_ADMIN_ID;
  const e = findEmployee(id);
  return { id, name: e?.name ?? 'Admin', isMain: scenario !== 'sub' };
}

// ---- Scenario switch: ?mock=main (default) | sub | error | slow | malformed | conflict ----

const SCENARIOS: readonly Scenario[] = ['main', 'sub', 'error', 'slow', 'malformed', 'conflict'];
let remembered: Scenario = 'main';

/** A `?mock=` value in the URL wins and is remembered, because SPA navigation drops the query string. */
export function currentScenario(): Scenario {
  if (typeof window !== 'undefined') {
    const value = new URLSearchParams(window.location.search).get('mock');
    const found = SCENARIOS.find((s) => s === value);
    if (found) {
      if (found === 'conflict' && remembered !== 'conflict') conflictArmed = true;
      remembered = found;
    }
  }
  return remembered;
}

// ---- ?mock=conflict: the first employee update "loses a race" against another admin, once ----
// (Each browser tab has its own in-memory store, so a second tab cannot cause a real conflict in the mock.)

let conflictArmed = true;

/** True once per `?mock=conflict` visit; the caller then applies a change "made by someone else". */
export function takeConflictTrigger(): boolean {
  if (currentScenario() !== 'conflict' || !conflictArmed) return false;
  conflictArmed = false;
  return true;
}

// ---- Reveal rate limit: 5 per minute ----

export const REVEAL_LIMIT = 5;
export const REVEAL_WINDOW_MS = 60_000;

/** Returns seconds to wait when over the limit, or 0 after recording this attempt. */
export function checkRevealRate(): number {
  const s = getStore();
  const now = Date.now();
  s.revealTimes = s.revealTimes.filter((t) => now - t < REVEAL_WINDOW_MS);
  if (s.revealTimes.length >= REVEAL_LIMIT) {
    const oldest = s.revealTimes[0] ?? now;
    return Math.max(1, Math.ceil((REVEAL_WINDOW_MS - (now - oldest)) / 1000));
  }
  s.revealTimes.push(now);
  return 0;
}

// ---- Dev trigger: make the NEXT write (POST/PUT/PATCH) fail with a chosen error. Used by the dialog harness. ----

export type ForcedError =
  | 'LAST_MAIN_ADMIN_PROTECTED'
  | 'INVALID_STATE'
  | 'VERSION_CONFLICT'
  | 'FORBIDDEN'
  | 'NOT_FOUND'
  | 'VALIDATION_ERROR';

let forcedError: ForcedError | null = null;

export function forceNextError(code: ForcedError | null): void {
  forcedError = code;
}

/** Returns the pending forced error once, then clears it. */
export function takeForcedError(): ForcedError | null {
  const code = forcedError;
  forcedError = null;
  return code;
}
