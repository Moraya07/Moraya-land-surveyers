import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { PERMISSIONS } from '../src/env';
import { hasPermission } from '../src/middleware/rbac';
import { FakeSupabase, api, flush } from './helpers';

let fake: FakeSupabase;
beforeEach(() => {
  fake = new FakeSupabase();
  fake.install();
});
afterEach(() => vi.unstubAllGlobals());

async function as(role: 'main_admin' | 'sub_admin' | 'worker', permissions: string[] = []) {
  const id = fake.addUser(`${role}@x.com`, 'pw', { role, permissions });
  return { '__Host-moraya_at': await fake.issueToken(id) };
}

describe('route guards', () => {
  it('401 when not signed in', async () => {
    expect((await api('/api/worker/ping')).status).toBe(401);
    expect((await api('/api/admin/ping')).status).toBe(401);
  });
  it('worker: allowed on /worker/ping, 403 (not 404) on /admin/ping, and audited', async () => {
    const cookies = await as('worker');
    expect((await api('/api/worker/ping', { cookies })).status).toBe(200);
    const res = await api('/api/admin/ping', { cookies });
    expect(res.status).toBe(403);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe('FORBIDDEN');
    await flush();
    expect(fake.audits).toContainEqual(expect.objectContaining({ action: 'ACCESS_DENIED' }));
  });
  it('rate-limits ACCESS_DENIED audit rows', async () => {
    const cookies = await as('worker');
    await api('/api/admin/ping', { cookies });
    await api('/api/admin/ping', { cookies });
    await flush();
    expect(fake.audits.filter((a) => a.action === 'ACCESS_DENIED').length).toBeLessThanOrEqual(1);
  });
  it('sub_admin without the permission gets 403; with it, 200', async () => {
    expect((await api('/api/admin/report-ping', { cookies: await as('sub_admin', ['export']) })).status).toBe(403);
    fake = new FakeSupabase();
    fake.install();
    expect((await api('/api/admin/report-ping', { cookies: await as('sub_admin', ['report_view']) })).status).toBe(200);
  });
  it('main_admin passes every guard without stored permissions', async () => {
    const cookies = await as('main_admin');
    expect((await api('/api/admin/ping', { cookies })).status).toBe(200);
    expect((await api('/api/admin/report-ping', { cookies })).status).toBe(200);
  });
  it('an inactive user is refused on protected routes with 403', async () => {
    const id = fake.addUser('x@x.com', 'pw', { role: 'worker', account_status: 'inactive' });
    const res = await api('/api/worker/ping', { cookies: { '__Host-moraya_at': await fake.issueToken(id) } });
    expect(res.status).toBe(403);
  });
  it('role changes apply immediately (profile is re-read on every request)', async () => {
    const id = fake.addUser('s@x.com', 'pw', { role: 'sub_admin' });
    const cookies = { '__Host-moraya_at': await fake.issueToken(id) };
    expect((await api('/api/admin/ping', { cookies })).status).toBe(200);
    fake.profiles.get(id)!.role = 'worker';
    expect((await api('/api/admin/ping', { cookies })).status).toBe(403);
  });
});

describe('hasPermission', () => {
  it('main_admin has every permission', () => {
    for (const p of PERMISSIONS) expect(hasPermission({ role: 'main_admin', permissions: [] }, p)).toBe(true);
  });
  it('sub_admin only has granted permissions; worker none', () => {
    expect(hasPermission({ role: 'sub_admin', permissions: ['export'] }, 'export')).toBe(true);
    expect(hasPermission({ role: 'sub_admin', permissions: ['export'] }, 'report_view')).toBe(false);
    expect(hasPermission({ role: 'worker', permissions: ['export'] }, 'export')).toBe(false);
  });
});
