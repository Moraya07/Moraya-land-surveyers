-- Test for 009_main_admin_protection.sql. Run in the Supabase SQL editor (as postgres).
-- Everything is rolled back. Expect only NOTICE lines starting with PASS.
-- Fake data only.
begin;

-- helper: runs a statement and passes only if it raises the expected error
create function pg_temp.expect(p_name text, p_sql text, p_message text default null, p_sqlstate text default null)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if (p_message is null or sqlerrm = p_message) and (p_sqlstate is null or sqlstate = p_sqlstate) then
      raise notice 'PASS %', p_name;
      return;
    end if;
    raise exception 'FAIL %: got % / %', p_name, sqlstate, sqlerrm;
  end;
  raise exception 'FAIL %: no error raised', p_name;
end $$;

insert into auth.users (id, email) values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'm@test.local'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 's@test.local'),
  ('bbbbbbbb-0000-0000-0000-000000000003', 'w@test.local'),
  ('bbbbbbbb-0000-0000-0000-000000000004', 'x@test.local'),
  ('bbbbbbbb-0000-0000-0000-000000000005', 'y@test.local');

insert into public.employees (auth_user_id, employee_id, name, login_email, role, account_status) values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'M-1', 'Main One',     'm@test.local', 'main_admin', 'active'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'S-1', 'Sub One',      's@test.local', 'sub_admin',  'active'),
  ('bbbbbbbb-0000-0000-0000-000000000003', 'W-1', 'Worker One',   'w@test.local', 'worker',     'active'),
  ('bbbbbbbb-0000-0000-0000-000000000004', 'X-1', 'Inactive One', 'x@test.local', 'worker',     'inactive');

insert into public.sub_admin_permissions (employee_id, permission)
select id, p from public.employees, unnest(array['site_management','report_view']) p
where employee_id = 'S-1';

-- 1. A second main_admin cannot be inserted
select pg_temp.expect('second main admin insert rejected',
  $q$ insert into public.employees (auth_user_id, employee_id, name, login_email, role)
      values ('bbbbbbbb-0000-0000-0000-000000000005','Y-1','Second','y@test.local','main_admin') $q$,
  null, '23505');

-- 2. The only main admin cannot be demoted, deactivated, revoked or deleted
select pg_temp.expect('demote only main admin rejected',
  $q$ update public.employees set role='worker' where employee_id='M-1' $q$, null, 'P0001');
select pg_temp.expect('deactivate only main admin rejected',
  $q$ update public.employees set account_status='inactive' where employee_id='M-1' $q$, null, 'P0001');
select pg_temp.expect('revoke only main admin rejected',
  $q$ update public.employees set account_status='revoked' where employee_id='M-1' $q$, null, 'P0001');
select pg_temp.expect('delete main admin rejected',
  $q$ delete from public.employees where employee_id='M-1' $q$, null, 'P0001');

-- 3. Promoting someone by a plain update is rejected
select pg_temp.expect('plain promotion rejected',
  $q$ update public.employees set role='main_admin' where employee_id='S-1' $q$, null, 'P0001');

-- 4. A hand-set flag does not unlock demotion (it must equal the transaction id)
select pg_temp.expect('fake transfer flag ignored',
  $q$ select set_config('moraya.main_admin_transfer','on',true);
      update public.employees set role='sub_admin' where employee_id='M-1' $q$, null, 'P0001');

-- 5. Non-main-admin callers are refused
select pg_temp.expect('sub admin cannot transfer',
  $q$ select public.transfer_main_admin('bbbbbbbb-0000-0000-0000-000000000002',
        (select id from public.employees where employee_id='W-1'), 'test', 'r1') $q$, 'MORAYA_FORBIDDEN');
select pg_temp.expect('worker cannot transfer',
  $q$ select public.transfer_main_admin('bbbbbbbb-0000-0000-0000-000000000003',
        (select id from public.employees where employee_id='S-1'), 'test', 'r2') $q$, 'MORAYA_FORBIDDEN');
select pg_temp.expect('unknown caller cannot transfer',
  $q$ select public.transfer_main_admin('bbbbbbbb-0000-0000-0000-0000000000ff',
        (select id from public.employees where employee_id='S-1'), 'test', 'r3') $q$, 'MORAYA_FORBIDDEN');

-- 6. Bad inputs from the real Main Admin
select pg_temp.expect('blank reason rejected',
  $q$ select public.transfer_main_admin('bbbbbbbb-0000-0000-0000-000000000001',
        (select id from public.employees where employee_id='S-1'), '   ', 'r4') $q$, 'MORAYA_VALIDATION');
select pg_temp.expect('null target rejected',
  $q$ select public.transfer_main_admin('bbbbbbbb-0000-0000-0000-000000000001', null, 'test', 'r5') $q$, 'MORAYA_VALIDATION');
select pg_temp.expect('transfer to self rejected',
  $q$ select public.transfer_main_admin('bbbbbbbb-0000-0000-0000-000000000001',
        (select id from public.employees where employee_id='M-1'), 'test', 'r6') $q$, 'MORAYA_VALIDATION');
select pg_temp.expect('unknown target rejected',
  $q$ select public.transfer_main_admin('bbbbbbbb-0000-0000-0000-000000000001',
        'cccccccc-0000-0000-0000-000000000000', 'test', 'r7') $q$, 'MORAYA_NOT_FOUND');
select pg_temp.expect('inactive target rejected',
  $q$ select public.transfer_main_admin('bbbbbbbb-0000-0000-0000-000000000001',
        (select id from public.employees where employee_id='X-1'), 'test', 'r8') $q$, 'MORAYA_INVALID_STATE');

-- 7. Successful transfer M-1 -> S-1
select public.transfer_main_admin('bbbbbbbb-0000-0000-0000-000000000001',
  (select id from public.employees where employee_id='S-1'), 'Owner is stepping down', 'req-ok-1');

do $$
declare v_cnt int; v_who text; v_old text; v_perms int; a public.audit_logs;
begin
  select count(*), max(employee_id) into v_cnt, v_who from public.employees where role = 'main_admin';
  if v_cnt = 1 and v_who = 'S-1' then raise notice 'PASS exactly one main admin after transfer (S-1)';
  else raise exception 'FAIL after transfer: % main admins, %', v_cnt, v_who; end if;

  select role::text into v_old from public.employees where employee_id = 'M-1';
  if v_old = 'sub_admin' then raise notice 'PASS old main admin is now sub_admin';
  else raise exception 'FAIL old main admin role is %', v_old; end if;

  select count(*) into v_perms from public.sub_admin_permissions
   where employee_id in (select id from public.employees where employee_id in ('S-1','M-1'));
  if v_perms = 0 then raise notice 'PASS no stale permission rows after transfer';
  else raise exception 'FAIL % permission rows remain', v_perms; end if;

  select * into a from public.audit_logs where action = 'MAIN_ADMIN_TRANSFERRED' and request_id = 'req-ok-1';
  if found and a.reason = 'Owner is stepping down'
     and a.summary = 'Main Admin changed from Main One (M-1) to Sub One (S-1)'
     and a.actor_employee_id = (select id from public.employees where employee_id = 'M-1')
  then raise notice 'PASS transfer audited with reason and summary';
  else raise exception 'FAIL audit row: %', to_jsonb(a); end if;
end $$;

-- 8. The old main admin has lost the power; the new one has it
select pg_temp.expect('old main admin can no longer transfer',
  $q$ select public.transfer_main_admin('bbbbbbbb-0000-0000-0000-000000000001',
        (select id from public.employees where employee_id='W-1'), 'test', 'r9') $q$, 'MORAYA_FORBIDDEN');
select pg_temp.expect('new main admin is protected from demotion',
  $q$ update public.employees set role='worker' where employee_id='S-1' $q$, null, 'P0001');
select pg_temp.expect('new main admin is protected from deletion',
  $q$ delete from public.employees where employee_id='S-1' $q$, null, 'P0001');

-- 9. Transfer back (S-1 -> M-1) also leaves exactly one
select public.transfer_main_admin('bbbbbbbb-0000-0000-0000-000000000002',
  (select id from public.employees where employee_id='M-1'), 'Handing back', 'req-ok-2');
do $$
declare v_cnt int; v_who text;
begin
  select count(*), max(employee_id) into v_cnt, v_who from public.employees where role = 'main_admin';
  if v_cnt = 1 and v_who = 'M-1' then raise notice 'PASS transfer back leaves exactly one (M-1)';
  else raise exception 'FAIL transfer back: % / %', v_cnt, v_who; end if;
end $$;

-- 10. Deferred check: a demotion without a promotion cannot commit
--     (uses the real flag to get past the trigger, then forces the deferred check)
select pg_temp.expect('commit check: zero main admins refused',
  $q$ select set_config('moraya.main_admin_transfer', txid_current()::text, true);
      update public.employees set role='sub_admin' where employee_id='M-1';
      set constraints all immediate $q$, 'MORAYA_INVALID_STATE');

-- 11. Privileges
do $$ begin
  if has_function_privilege('service_role', 'public.transfer_main_admin(uuid,uuid,text,text)', 'execute')
     and not has_function_privilege('anon', 'public.transfer_main_admin(uuid,uuid,text,text)', 'execute')
     and not has_function_privilege('authenticated', 'public.transfer_main_admin(uuid,uuid,text,text)', 'execute')
  then raise notice 'PASS transfer_main_admin is service_role only';
  else raise exception 'FAIL grants'; end if;
end $$;

rollback;