-- Test for 011_profile_and_password.sql. Run in the Supabase SQL editor (as postgres).
-- Needs 008, 009, 010 and 011 applied. Everything is rolled back.
-- Expect only NOTICE lines starting with PASS; any FAIL stops the script with an error.
-- Fake data only.
begin;

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

create function pg_temp.assert_true(p_name text, p_ok boolean) returns void language plpgsql as $$
begin
  if p_ok then raise notice 'PASS %', p_name;
  else raise exception 'FAIL %', p_name; end if;
end $$;

insert into auth.users (id, email) values
  ('eeeeeeee-0000-0000-0000-000000000001', 'm@test.local'),
  ('eeeeeeee-0000-0000-0000-000000000002', 'sub@test.local'),
  ('eeeeeeee-0000-0000-0000-000000000003', 'w@test.local'),
  ('eeeeeeee-0000-0000-0000-000000000004', 'off@test.local'),
  ('eeeeeeee-0000-0000-0000-000000000005', 'rev@test.local'),
  ('eeeeeeee-0000-0000-0000-000000000006', 'nobody@test.local');

insert into public.employees
  (auth_user_id, employee_id, name, login_email, role, account_status, designation, date_of_joining) values
  ('eeeeeeee-0000-0000-0000-000000000001', 'M-1',   'Main',     'm@test.local',   'main_admin', 'active',   'Owner',  '2020-04-01'),
  ('eeeeeeee-0000-0000-0000-000000000002', 'SUB-1', 'Sub',      'sub@test.local', 'sub_admin',  'active',   'Clerk',  '2021-06-15'),
  ('eeeeeeee-0000-0000-0000-000000000003', 'W-1',   'Worker',   'w@test.local',   'worker',     'active',   'Surveyor', '2022-01-10'),
  ('eeeeeeee-0000-0000-0000-000000000004', 'OFF-1', 'Inactive', 'off@test.local', 'worker',     'inactive', null,     null),
  ('eeeeeeee-0000-0000-0000-000000000005', 'REV-1', 'Revoked',  'rev@test.local', 'worker',     'revoked',  null,     null);

insert into public.sub_admin_permissions (employee_id, permission)
select id, p from public.employees, unnest(array['site_management','report_view']) p
 where employee_id = 'SUB-1';

-- 1. Column and constraint exist
select pg_temp.assert_true('employees.phone column exists',
  exists (select 1 from information_schema.columns
           where table_schema = 'public' and table_name = 'employees' and column_name = 'phone'));
select pg_temp.expect('bad phone rejected by the table itself',
  $q$ update public.employees set phone = 'abc' where employee_id = 'W-1' $q$, null, '23514');

-- 2. get_own_profile: shape and safety
do $$
declare p jsonb;
begin
  p := public.get_own_profile('eeeeeeee-0000-0000-0000-000000000003');
  perform pg_temp.assert_true('worker profile has the expected fields',
    p ->> 'employee_id' = 'W-1' and p ->> 'name' = 'Worker' and p ->> 'login_email' = 'w@test.local'
    and p ->> 'role' = 'worker' and p ->> 'designation' = 'Surveyor'
    and p ->> 'date_of_joining' = '2022-01-10' and p -> 'permissions' = '[]'::jsonb);
  perform pg_temp.assert_true('profile never exposes ids or internals',
    not (p ? 'auth_user_id') and not (p ? 'id') and not (p ? 'sr_no') and not (p ? 'created_by'));
  perform pg_temp.assert_true('aadhaar_masked is null while no last4 exists (before 012)',
    p -> 'aadhaar_masked' = 'null'::jsonb);

  p := public.get_own_profile('eeeeeeee-0000-0000-0000-000000000002');
  perform pg_temp.assert_true('sub admin sees own permissions, sorted',
    p -> 'permissions' = '["report_view","site_management"]'::jsonb);
end $$;

-- 3. Aadhaar masking when a last4 column exists (simulates 012; skipped if 012 not applied)
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'employees' and column_name = 'aadhaar_last4') then
    update public.employees set aadhaar_last4 = '4321' where employee_id = 'W-1';
    perform pg_temp.assert_true('aadhaar shows only the last 4',
      public.get_own_profile('eeeeeeee-0000-0000-0000-000000000003') ->> 'aadhaar_masked' = 'XXXX XXXX 4321');
  else
    raise notice 'SKIP aadhaar masking (012 not applied yet)';
  end if;
end $$;

-- 4. Who may call
select pg_temp.expect('inactive user cannot read profile',
  $q$ select public.get_own_profile('eeeeeeee-0000-0000-0000-000000000004') $q$, 'MORAYA_FORBIDDEN', 'P0001');
select pg_temp.expect('revoked user cannot read profile',
  $q$ select public.get_own_profile('eeeeeeee-0000-0000-0000-000000000005') $q$, 'MORAYA_FORBIDDEN', 'P0001');
select pg_temp.expect('auth user without employee row cannot read profile',
  $q$ select public.get_own_profile('eeeeeeee-0000-0000-0000-000000000006') $q$, 'MORAYA_FORBIDDEN', 'P0001');
select pg_temp.expect('inactive user cannot update profile',
  $q$ select public.update_own_profile('eeeeeeee-0000-0000-0000-000000000004', '{"phone":"9876543210"}') $q$,
  'MORAYA_FORBIDDEN', 'P0001');
select pg_temp.expect('inactive user cannot log a password change',
  $q$ select public.log_password_change('eeeeeeee-0000-0000-0000-000000000004') $q$, 'MORAYA_FORBIDDEN', 'P0001');

-- 5. update_own_profile: happy path, normalisation, audit
do $$
declare r jsonb; n int; a record;
begin
  r := public.update_own_profile('eeeeeeee-0000-0000-0000-000000000003',
                                 '{"phone":" +91 98765-43210 "}', 'req-1');
  perform pg_temp.assert_true('phone normalised and saved',
    (r ->> 'changed')::boolean and r -> 'profile' ->> 'phone' = '+919876543210');

  select * into a from public.audit_logs
   where action = 'PROFILE_UPDATED' and request_id = 'req-1';
  perform pg_temp.assert_true('PROFILE_UPDATED audited against the actor',
    a.actor_employee_id = (select id from public.employees where employee_id = 'W-1')
    and a.entity_type = 'employee' and a.summary like 'Updated own profile: phone%');
  perform pg_temp.assert_true('audit holds only the masked phone',
    a.new_value ->> 'phone_masked' = 'XXXXXXXXX3210' and a.old_value ->> 'phone_masked' is null
    and a.new_value::text not like '%9876543210%' and a.summary not like '%9876543210%');

  select count(*) into n from public.audit_logs where action = 'PROFILE_UPDATED';
  r := public.update_own_profile('eeeeeeee-0000-0000-0000-000000000003', '{"phone":"+919876543210"}', 'req-2');
  perform pg_temp.assert_true('same phone again: changed = false',
    not (r ->> 'changed')::boolean);
  perform pg_temp.assert_true('same phone again: nothing audited',
    (select count(*) from public.audit_logs where action = 'PROFILE_UPDATED') = n);

  r := public.update_own_profile('eeeeeeee-0000-0000-0000-000000000003', '{"phone":null}', 'req-3');
  perform pg_temp.assert_true('null clears the phone',
    (r ->> 'changed')::boolean and r -> 'profile' -> 'phone' = 'null'::jsonb);
  r := public.update_own_profile('eeeeeeee-0000-0000-0000-000000000003', '{"phone":"  "}', 'req-4');
  perform pg_temp.assert_true('blank on an empty phone: changed = false', not (r ->> 'changed')::boolean);
end $$;

-- 6. Main admin may edit own phone (protect_main_admin must not get in the way)
do $$
declare r jsonb;
begin
  r := public.update_own_profile('eeeeeeee-0000-0000-0000-000000000001', '{"phone":"02012345678"}');
  perform pg_temp.assert_true('main admin can set own phone', (r ->> 'changed')::boolean);
end $$;

-- 7. Everything except phone is refused
select pg_temp.expect('role cannot be changed',
  $q$ select public.update_own_profile('eeeeeeee-0000-0000-0000-000000000003', '{"role":"main_admin"}') $q$,
  'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('account_status cannot be changed',
  $q$ select public.update_own_profile('eeeeeeee-0000-0000-0000-000000000003', '{"account_status":"active"}') $q$,
  'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('employee_id cannot be changed',
  $q$ select public.update_own_profile('eeeeeeee-0000-0000-0000-000000000003', '{"employee_id":"X-9"}') $q$,
  'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('permissions cannot be changed',
  $q$ select public.update_own_profile('eeeeeeee-0000-0000-0000-000000000002', '{"permissions":["export"]}') $q$,
  'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('designation cannot be changed',
  $q$ select public.update_own_profile('eeeeeeee-0000-0000-0000-000000000003', '{"designation":"Boss"}') $q$,
  'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('joining date cannot be changed',
  $q$ select public.update_own_profile('eeeeeeee-0000-0000-0000-000000000003', '{"date_of_joining":"2000-01-01"}') $q$,
  'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('aadhaar cannot be changed',
  $q$ select public.update_own_profile('eeeeeeee-0000-0000-0000-000000000003', '{"aadhaar":"123412341234"}') $q$,
  'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('a valid phone does not smuggle in a second, forbidden key',
  $q$ select public.update_own_profile('eeeeeeee-0000-0000-0000-000000000003', '{"phone":"9876543210","role":"main_admin"}') $q$,
  'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('invalid phone rejected',
  $q$ select public.update_own_profile('eeeeeeee-0000-0000-0000-000000000003', '{"phone":"12ab"}') $q$,
  'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('phone must be a string',
  $q$ select public.update_own_profile('eeeeeeee-0000-0000-0000-000000000003', '{"phone":9876543210}') $q$,
  'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('empty patch rejected',
  $q$ select public.update_own_profile('eeeeeeee-0000-0000-0000-000000000003', '{}') $q$,
  'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('non-object patch rejected',
  $q$ select public.update_own_profile('eeeeeeee-0000-0000-0000-000000000003', '["phone"]') $q$,
  'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('null patch rejected',
  $q$ select public.update_own_profile('eeeeeeee-0000-0000-0000-000000000003', null) $q$,
  'MORAYA_VALIDATION', 'P0001');

select pg_temp.assert_true('refused patches changed nothing on the row',
  (select role::text = 'worker' and account_status::text = 'active' and employee_id = 'W-1'
          and designation = 'Surveyor' and date_of_joining = '2022-01-10'
     from public.employees where login_email = 'w@test.local'));

-- 8. log_password_change
insert into public.auth_login_attempts (key, window_start, attempts)
select 'chgpw:' || id::text, now(), 4 from public.employees where employee_id = 'W-1';
insert into public.auth_login_attempts (key, window_start, attempts)
values ('login-key-should-stay', now(), 3);

do $$
declare r jsonb; a record;
begin
  r := public.log_password_change('eeeeeeee-0000-0000-0000-000000000003', 'req-pw');
  perform pg_temp.assert_true('log_password_change returns logged = true', (r ->> 'logged')::boolean);

  select * into a from public.audit_logs where action = 'PASSWORD_CHANGED' and request_id = 'req-pw';
  perform pg_temp.assert_true('PASSWORD_CHANGED audited for the actor',
    a.actor_employee_id = (select id from public.employees where employee_id = 'W-1')
    and a.summary = 'Changed own password' and a.old_value is null and a.new_value is null);

  perform pg_temp.assert_true('change-password throttle counter cleared',
    not exists (select 1 from public.auth_login_attempts
                 where key = 'chgpw:' || (select id::text from public.employees where employee_id = 'W-1')));
  perform pg_temp.assert_true('login throttle counters left alone',
    exists (select 1 from public.auth_login_attempts where key = 'login-key-should-stay'));
end $$;

-- 9. Audit rows from this file are append-only like the rest
select pg_temp.expect('audit rows cannot be edited',
  $q$ update public.audit_logs set summary = 'x' where action = 'PASSWORD_CHANGED' $q$, null, 'P0001');

-- 10. New audit actions are in the catalogue
select pg_temp.assert_true('password audit actions catalogued',
  (select count(*) from public.audit_actions
    where action in ('PASSWORD_CHANGED','PROFILE_UPDATED','PASSWORD_CHANGE_FAILED','PASSWORD_CHANGE_BLOCKED')) = 4);

-- 11. Grants: only service_role may execute
select pg_temp.assert_true('anon and authenticated cannot execute any 011 function',
  not exists (
    select 1
      from unnest(array[
        'public.get_own_profile(uuid)',
        'public.update_own_profile(uuid,jsonb,text)',
        'public.log_password_change(uuid,text)',
        'public.own_profile_as_json(uuid)',
        'public.profile_mask_phone(text)']) f
     where has_function_privilege('anon', f, 'execute')
        or has_function_privilege('authenticated', f, 'execute')));
select pg_temp.assert_true('service_role can execute the three RPCs',
  has_function_privilege('service_role', 'public.get_own_profile(uuid)', 'execute')
  and has_function_privilege('service_role', 'public.update_own_profile(uuid,jsonb,text)', 'execute')
  and has_function_privilege('service_role', 'public.log_password_change(uuid,text)', 'execute'));

rollback;