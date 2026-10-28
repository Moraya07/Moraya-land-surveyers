-- 009_main_admin_protection.sql
-- PURPOSE   : Make the Main Admin handover possible and safe.
--             1. Replace protect_main_admin() so that ONLY transfer_main_admin() can demote
--                the current Main Admin or create a new one.
--             2. Add a deferred check: at commit there must be exactly one ACTIVE main_admin.
--             3. Add transfer_main_admin(): atomic swap, audited.
-- DEPENDS ON: 001, 002 (employees, protect_main_admin, employees_single_main_admin),
--             003 (permissions are dropped automatically when a role changes),
--             008 (write_audit, moraya_require_actor, moraya_fail, MAIN_ADMIN_TRANSFERRED).
-- ALREADY IN 002 (not repeated): the partial unique index employees_single_main_admin.
--             It allows ONE main_admin row of any status, which is stricter than
--             "one active main_admin", and protect_main_admin already stops that row
--             from being deactivated.
-- ROLLBACK  : drop function public.transfer_main_admin(uuid,uuid,text,text);
--             drop trigger if exists employees_one_main_admin on public.employees;
--             drop function public.employees_enforce_one_main_admin();
--             then re-run the "create or replace function public.protect_main_admin()"
--             block from 002_employees.sql to restore the old trigger function.
--
-- HOW THE SWAP WORKS
--   The unique index forbids two main admins, and the old trigger forbade demoting the
--   only one, so a swap was impossible. Inside transfer_main_admin() the transaction sets
--   the setting moraya.main_admin_transfer to its own transaction id. The trigger only
--   honours the setting when it equals txid_current(), so a value set by anyone else,
--   or left over from another transaction, does nothing. Order inside the function:
--   demote the old one (zero main admins for a moment), then promote the new one.
--   Nothing is visible to other sessions until commit, and the deferred check below
--   refuses to commit unless exactly one active main_admin exists.

-- =====================================================================================
-- 1. protect_main_admin(): same rules as 002, plus the transfer exception
-- =====================================================================================
create or replace function public.protect_main_admin() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_transfer boolean;
begin
  v_transfer := coalesce(current_setting('moraya.main_admin_transfer', true), '') = txid_current()::text;

  if tg_op = 'DELETE' then
    if old.role = 'main_admin' then
      raise exception 'The Main Admin cannot be deleted' using errcode = 'P0001';
    end if;
    return old;
  end if;

  -- UPDATE
  if old.role = 'main_admin' and (new.role <> 'main_admin' or new.account_status <> 'active') then
    -- the only allowed path: transfer_main_admin() demotes to sub_admin, still active
    if v_transfer and new.role = 'sub_admin' and new.account_status = 'active' then
      return new;
    end if;
    raise exception 'The Main Admin cannot be demoted, deactivated or revoked' using errcode = 'P0001';
  end if;

  -- nobody becomes Main Admin by a plain update
  if old.role <> 'main_admin' and new.role = 'main_admin' and not v_transfer then
    raise exception 'The Main Admin role can only be changed through transfer_main_admin' using errcode = 'P0001';
  end if;

  return new;
end $$;

-- (the trigger employees_protect_main_admin from 002 already points at this function name)

-- =====================================================================================
-- 2. Deferred check: exactly one ACTIVE main_admin at commit
--    Only checked when the changed row is or was a main_admin, so creating ordinary
--    employees before the first Main Admin is seeded still works.
-- =====================================================================================
create or replace function public.employees_enforce_one_main_admin() returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_total  int;
  v_active int;
begin
  if tg_op = 'INSERT' and new.role <> 'main_admin' then return null; end if;
  if tg_op = 'DELETE' and old.role <> 'main_admin' then return null; end if;
  if tg_op = 'UPDATE' and old.role <> 'main_admin' and new.role <> 'main_admin' then return null; end if;

  select count(*), count(*) filter (where e.account_status = 'active')
    into v_total, v_active
    from public.employees e
   where e.role = 'main_admin';

  if v_total <> 1 or v_active <> 1 then
    raise exception using errcode = 'P0001', message = 'MORAYA_INVALID_STATE',
      detail = 'Exactly one active Main Admin must exist';
  end if;
  return null;
end $$;

drop trigger if exists employees_one_main_admin on public.employees;
create constraint trigger employees_one_main_admin
  after insert or update or delete on public.employees
  deferrable initially deferred
  for each row execute function public.employees_enforce_one_main_admin();

-- =====================================================================================
-- 3. transfer_main_admin
--    Who may call : the current Main Admin only (active).
--    New Main Admin: any OTHER employee whose account_status is 'active'.
--    Result        : new person -> main_admin (their sub_admin permission rows are
--                    removed by trigger 003), old Main Admin -> sub_admin with NO
--                    permissions (the new Main Admin can grant some afterwards).
--    A reason is required (1 to 1000 characters).
--    Errors        : MORAYA_FORBIDDEN, MORAYA_VALIDATION, MORAYA_NOT_FOUND,
--                    MORAYA_INVALID_STATE
-- =====================================================================================
create or replace function public.transfer_main_admin(
  p_actor_auth_id   uuid,
  p_new_employee_id uuid,
  p_reason          text,
  p_request_id      text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  public.employees;
  v_cur    public.employees;
  v_new    public.employees;
  v_reason text;
  v_total  int;
  v_active int;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, true, null);

  v_reason := btrim(coalesce(p_reason, ''));
  if v_reason = '' or char_length(v_reason) > 1000 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'A reason of 1 to 1000 characters is required');
  end if;
  if p_new_employee_id is null or p_new_employee_id = v_actor.id then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Choose a different employee');
  end if;

  -- One transfer at a time, and both rows locked in a fixed order (no deadlocks).
  perform pg_advisory_xact_lock(hashtext('moraya_main_admin_transfer'));
  perform 1 from public.employees e
   where e.id in (v_actor.id, p_new_employee_id)
   order by e.id
     for update;

  -- Re-read after the lock: the caller must still be the active Main Admin.
  select * into v_cur from public.employees e where e.id = v_actor.id;
  if not found or v_cur.role <> 'main_admin' or v_cur.account_status <> 'active' then
    perform public.moraya_fail('MORAYA_FORBIDDEN');
  end if;

  select * into v_new from public.employees e where e.id = p_new_employee_id;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Employee not found');
  end if;
  if v_new.account_status <> 'active' or v_new.role = 'main_admin' then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'The new Main Admin must be another active employee');
  end if;

  -- Swap. The setting is local to this transaction and equals its transaction id.
  perform set_config('moraya.main_admin_transfer', txid_current()::text, true);
  update public.employees set role = 'sub_admin'  where id = v_cur.id;
  update public.employees set role = 'main_admin' where id = v_new.id;
  perform set_config('moraya.main_admin_transfer', '', true);

  -- Belt and braces (the deferred trigger checks again at commit).
  select count(*), count(*) filter (where e.account_status = 'active')
    into v_total, v_active
    from public.employees e where e.role = 'main_admin';
  if v_total <> 1 or v_active <> 1 then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'Exactly one active Main Admin must exist');
  end if;

  perform public.write_audit(
    v_cur.id,
    'MAIN_ADMIN_TRANSFERRED',
    'employee',
    v_new.id::text,
    jsonb_build_object('main_admin_employee_id', v_cur.employee_id,
                       'new_admin_role', v_new.role::text),
    jsonb_build_object('main_admin_employee_id', v_new.employee_id,
                       'previous_admin_role', 'sub_admin'),
    v_reason,
    p_request_id,
    'Main Admin changed from ' || v_cur.name || ' (' || v_cur.employee_id || ') to '
      || v_new.name || ' (' || v_new.employee_id || ')'
  );

  return jsonb_build_object(
    'old_main_admin_id', v_cur.id,
    'new_main_admin_id', v_new.id,
    'old_main_admin_new_role', 'sub_admin'
  );
end $$;

-- =====================================================================================
-- 4. Grants: service_role only
-- =====================================================================================
revoke all on function public.transfer_main_admin(uuid, uuid, text, text)  from public, anon, authenticated;
revoke all on function public.protect_main_admin()                          from public, anon, authenticated;
revoke all on function public.employees_enforce_one_main_admin()            from public, anon, authenticated;
grant execute on function public.transfer_main_admin(uuid, uuid, text, text) to service_role;