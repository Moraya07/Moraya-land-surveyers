-- Test for 010_app_settings.sql. Run in the Supabase SQL editor (as postgres).
-- Needs 008 and 009 applied. Everything is rolled back. Expect only NOTICE lines starting with PASS.
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

insert into auth.users (id, email) values
  ('dddddddd-0000-0000-0000-000000000001', 'm@test.local'),
  ('dddddddd-0000-0000-0000-000000000002', 'rv@test.local'),
  ('dddddddd-0000-0000-0000-000000000003', 'ex@test.local'),
  ('dddddddd-0000-0000-0000-000000000004', 'st@test.local'),
  ('dddddddd-0000-0000-0000-000000000005', 'w@test.local'),
  ('dddddddd-0000-0000-0000-000000000006', 'x@test.local');

insert into public.employees (auth_user_id, employee_id, name, login_email, role, account_status) values
  ('dddddddd-0000-0000-0000-000000000001', 'M-1',  'Main',          'm@test.local',  'main_admin', 'active'),
  ('dddddddd-0000-0000-0000-000000000002', 'RV-1', 'Report Sub',    'rv@test.local', 'sub_admin',  'active'),
  ('dddddddd-0000-0000-0000-000000000003', 'EX-1', 'Export Sub',    'ex@test.local', 'sub_admin',  'active'),
  ('dddddddd-0000-0000-0000-000000000004', 'ST-1', 'Site Sub',      'st@test.local', 'sub_admin',  'active'),
  ('dddddddd-0000-0000-0000-000000000005', 'W-1',  'Worker',        'w@test.local',  'worker',     'active'),
  ('dddddddd-0000-0000-0000-000000000006', 'X-1',  'Inactive Wkr',  'x@test.local',  'worker',     'inactive');

insert into public.sub_admin_permissions (employee_id, permission)
select id, 'report_view' from public.employees where employee_id = 'RV-1';
insert into public.sub_admin_permissions (employee_id, permission)
select id, 'export' from public.employees where employee_id = 'EX-1';
insert into public.sub_admin_permissions (employee_id, permission)
select id, 'site_management' from public.employees where employee_id = 'ST-1';

-- 1. Seed row and defaults
do $$
declare n int; s public.app_settings;
begin
  select count(*) into n from public.app_settings;
  select * into s from public.app_settings;
  if n = 1 and s.id = 1 and s.bill_prefix = 'MS' and s.workers_can_see_salary = false
     and s.phones = '{}' and s.account_number is null and s.pan is null
  then raise notice 'PASS one placeholder row with defaults';
  else raise exception 'FAIL seed row: % rows, %', n, to_jsonb(s); end if;
end $$;

-- 2. Only one row can exist; it cannot be deleted or truncated
select pg_temp.expect('second row (id 2) rejected',
  $q$ insert into public.app_settings (id, company_name) values (2, 'Other') $q$, null, '23514');
select pg_temp.expect('duplicate id 1 rejected',
  $q$ insert into public.app_settings (id, company_name) values (1, 'Other') $q$, null, '23505');
select pg_temp.expect('delete rejected',  $q$ delete from public.app_settings $q$, null, 'P0001');
select pg_temp.expect('truncate rejected', $q$ truncate public.app_settings $q$, null, 'P0001');

-- 3. get_app_settings: main admin, report_view and export pass; others refused
do $$
declare j jsonb;
begin
  j := public.get_app_settings('dddddddd-0000-0000-0000-000000000001');
  if j ? 'account_number' and j ? 'bank_name' and not (j ? 'id') and not (j ? 'updated_by')
  then raise notice 'PASS main admin reads full settings';
  else raise exception 'FAIL main admin read: %', j; end if;

  perform public.get_app_settings('dddddddd-0000-0000-0000-000000000002');
  raise notice 'PASS sub admin with report_view reads settings';
  perform public.get_app_settings('dddddddd-0000-0000-0000-000000000003');
  raise notice 'PASS sub admin with export reads settings';
end $$;
select pg_temp.expect('sub admin with only site_management refused',
  $q$ select public.get_app_settings('dddddddd-0000-0000-0000-000000000004') $q$, 'MORAYA_FORBIDDEN');
select pg_temp.expect('worker refused full settings',
  $q$ select public.get_app_settings('dddddddd-0000-0000-0000-000000000005') $q$, 'MORAYA_FORBIDDEN');
select pg_temp.expect('inactive user refused full settings',
  $q$ select public.get_app_settings('dddddddd-0000-0000-0000-000000000006') $q$, 'MORAYA_FORBIDDEN');

-- 4. get_public_settings: any active user, one key only
do $$
declare j jsonb;
begin
  j := public.get_public_settings('dddddddd-0000-0000-0000-000000000005');
  if j = '{"workers_can_see_salary": false}'::jsonb then raise notice 'PASS worker gets only the salary flag';
  else raise exception 'FAIL public settings: %', j; end if;
end $$;
select pg_temp.expect('inactive user refused public settings',
  $q$ select public.get_public_settings('dddddddd-0000-0000-0000-000000000006') $q$, 'MORAYA_FORBIDDEN');
select pg_temp.expect('unknown user refused public settings',
  $q$ select public.get_public_settings('dddddddd-0000-0000-0000-0000000000ff') $q$, 'MORAYA_FORBIDDEN');

-- 5. update_app_settings: only the main admin
select pg_temp.expect('sub admin cannot update',
  $q$ select public.update_app_settings('dddddddd-0000-0000-0000-000000000002', '{"branch":"X"}', 'u1') $q$, 'MORAYA_FORBIDDEN');
select pg_temp.expect('worker cannot update',
  $q$ select public.update_app_settings('dddddddd-0000-0000-0000-000000000005', '{"branch":"X"}', 'u2') $q$, 'MORAYA_FORBIDDEN');

-- 6. Successful update with normalisation and masked audit
select public.update_app_settings('dddddddd-0000-0000-0000-000000000001', $j${
  "company_name": "  Test Surveyors  ",
  "tagline": "Survey and mapping",
  "phones": ["9999900000", "+91 88888 77777"],
  "email": "Office@Test.Local",
  "pan": "abcde1234f",
  "bank_name": "Test Bank",
  "account_holder": "Test Surveyors",
  "account_number": "0001 0160-7000-0011-94",
  "ifsc": "test0000001",
  "branch": "Test Branch",
  "bill_prefix": "ms"
}$j$::jsonb, 'req-u1');

do $$
declare s public.app_settings; a public.audit_logs;
begin
  select * into s from public.app_settings;
  if s.company_name = 'Test Surveyors' and s.email = 'office@test.local' and s.pan = 'ABCDE1234F'
     and s.ifsc = 'TEST0000001' and s.bill_prefix = 'MS' and s.account_number = '000101607000001194'
     and s.phones = array['9999900000','+91 88888 77777']
     and s.updated_by = (select id from public.employees where employee_id = 'M-1')
  then raise notice 'PASS update stored and normalised';
  else raise exception 'FAIL stored row: %', to_jsonb(s); end if;

  select * into a from public.audit_logs where action = 'SETTINGS_UPDATED' and request_id = 'req-u1';
  if found
     and a.new_value ->> 'account_number' = 'XXXXXXXXXXXXXX1194'
     and position('000101607000001194' in a.new_value::text) = 0
     and position('000101607000001194' in coalesce(a.old_value::text, '')) = 0
     and a.summary like 'Changed settings: %account number%'
     and a.old_value ->> 'company_name' = 'Company name (update in Settings)'
  then raise notice 'PASS audit has old/new values with masked account number';
  else raise exception 'FAIL audit row: %', to_jsonb(a); end if;
end $$;

-- 7. Validation errors
select pg_temp.expect('bad PAN rejected',
  $q$ select public.update_app_settings('dddddddd-0000-0000-0000-000000000001', '{"pan":"12345"}', 'v1') $q$, 'MORAYA_VALIDATION');
select pg_temp.expect('bad IFSC rejected',
  $q$ select public.update_app_settings('dddddddd-0000-0000-0000-000000000001', '{"ifsc":"ABCD1234567"}', 'v2') $q$, 'MORAYA_VALIDATION');
select pg_temp.expect('account number with letters rejected',
  $q$ select public.update_app_settings('dddddddd-0000-0000-0000-000000000001', '{"account_number":"12AB5678901"}', 'v3') $q$, 'MORAYA_VALIDATION');
select pg_temp.expect('bad email rejected',
  $q$ select public.update_app_settings('dddddddd-0000-0000-0000-000000000001', '{"email":"not-an-email"}', 'v4') $q$, 'MORAYA_VALIDATION');
select pg_temp.expect('phones must be an array',
  $q$ select public.update_app_settings('dddddddd-0000-0000-0000-000000000001', '{"phones":"9999900000"}', 'v5') $q$, 'MORAYA_VALIDATION');
select pg_temp.expect('more than 4 phones rejected',
  $q$ select public.update_app_settings('dddddddd-0000-0000-0000-000000000001',
       '{"phones":["111111","222222","333333","444444","555555"]}', 'v6') $q$, 'MORAYA_VALIDATION');
select pg_temp.expect('bad phone rejected',
  $q$ select public.update_app_settings('dddddddd-0000-0000-0000-000000000001', '{"phones":["abc"]}', 'v7') $q$, 'MORAYA_VALIDATION');
select pg_temp.expect('unknown key rejected',
  $q$ select public.update_app_settings('dddddddd-0000-0000-0000-000000000001', '{"id":2}', 'v8') $q$, 'MORAYA_VALIDATION');
select pg_temp.expect('empty patch rejected',
  $q$ select public.update_app_settings('dddddddd-0000-0000-0000-000000000001', '{}', 'v9') $q$, 'MORAYA_VALIDATION');
select pg_temp.expect('non-object patch rejected',
  $q$ select public.update_app_settings('dddddddd-0000-0000-0000-000000000001', '[1]', 'v10') $q$, 'MORAYA_VALIDATION');
select pg_temp.expect('null company name rejected',
  $q$ select public.update_app_settings('dddddddd-0000-0000-0000-000000000001', '{"company_name":null}', 'v11') $q$, 'MORAYA_VALIDATION');
select pg_temp.expect('long bill prefix rejected',
  $q$ select public.update_app_settings('dddddddd-0000-0000-0000-000000000001', '{"bill_prefix":"TOOLONGPREFIX"}', 'v12') $q$, 'MORAYA_VALIDATION');
select pg_temp.expect('salary flag must be boolean',
  $q$ select public.update_app_settings('dddddddd-0000-0000-0000-000000000001', '{"workers_can_see_salary":"yes"}', 'v13') $q$, 'MORAYA_VALIDATION');

-- 8. A rejected patch changes nothing (all-or-nothing)
select pg_temp.expect('valid + invalid field in one patch rejected',
  $q$ select public.update_app_settings('dddddddd-0000-0000-0000-000000000001',
       '{"branch":"Changed Branch","pan":"bad"}', 'v14') $q$, 'MORAYA_VALIDATION');
do $$ begin
  if (select branch from public.app_settings) = 'Test Branch' then raise notice 'PASS rejected patch changed nothing';
  else raise exception 'FAIL partial update happened'; end if;
end $$;

-- 9. No-op update writes no audit row and reports changed=false
do $$
declare before_n int; after_n int; j jsonb;
begin
  select count(*) into before_n from public.audit_logs where action = 'SETTINGS_UPDATED';
  j := public.update_app_settings('dddddddd-0000-0000-0000-000000000001', '{"bill_prefix":"MS","branch":"Test Branch"}', 'req-noop');
  select count(*) into after_n from public.audit_logs where action = 'SETTINGS_UPDATED';
  if (j ->> 'changed') = 'false' and before_n = after_n then raise notice 'PASS no-op update not audited';
  else raise exception 'FAIL no-op: %, % -> %', j, before_n, after_n; end if;
end $$;

-- 10. Blank clears an optional field; the salary switch round-trips to workers
do $$
declare j jsonb;
begin
  j := public.update_app_settings('dddddddd-0000-0000-0000-000000000001', '{"branch":"   ","workers_can_see_salary":true}', 'req-u2');
  if (select branch from public.app_settings) is null and (j ->> 'changed') = 'true' then raise notice 'PASS blank clears optional field';
  else raise exception 'FAIL blank clear: %', j; end if;

  if (public.get_public_settings('dddddddd-0000-0000-0000-000000000005') ->> 'workers_can_see_salary') = 'true'
  then raise notice 'PASS worker sees the new salary flag';
  else raise exception 'FAIL salary flag not visible'; end if;

  if (public.get_app_settings('dddddddd-0000-0000-0000-000000000001') ->> 'updated_by_name') = 'Main'
  then raise notice 'PASS updated_by_name returned';
  else raise exception 'FAIL updated_by_name'; end if;
end $$;

-- 11. Privileges
do $$ begin
  if has_function_privilege('service_role', 'public.update_app_settings(uuid,jsonb,text)', 'execute')
     and not has_function_privilege('anon', 'public.update_app_settings(uuid,jsonb,text)', 'execute')
     and not has_function_privilege('authenticated', 'public.get_app_settings(uuid)', 'execute')
     and not has_function_privilege('authenticated', 'public.get_public_settings(uuid)', 'execute')
     and not has_function_privilege('authenticated', 'public.app_settings_as_json()', 'execute')
     and has_table_privilege('service_role', 'public.app_settings', 'select')
     and not has_table_privilege('service_role', 'public.app_settings', 'update')
     and not has_table_privilege('service_role', 'public.app_settings', 'delete')
     and not has_table_privilege('authenticated', 'public.app_settings', 'select')
     and (select relrowsecurity from pg_class where oid = 'public.app_settings'::regclass)
     and exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'app_settings')
  then raise notice 'PASS grants, RLS and policy as designed';
  else raise exception 'FAIL grants'; end if;
end $$;

rollback;