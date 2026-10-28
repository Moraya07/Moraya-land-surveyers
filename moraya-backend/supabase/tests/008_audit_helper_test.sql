-- Test for 008_audit_helper.sql. Run in the Supabase SQL editor (as postgres).
-- Everything is rolled back. Expect only NOTICE lines starting with PASS.
-- Fake data only.
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'main@test.local'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'sub@test.local'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'worker@test.local'),
  ('aaaaaaaa-0000-0000-0000-000000000004', 'off@test.local');

insert into public.employees (auth_user_id, employee_id, name, login_email, role, account_status) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'T-1', 'Main',        'main@test.local',   'main_admin', 'active'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'T-2', 'Sub',         'sub@test.local',    'sub_admin',  'active'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'T-3', 'Worker',      'worker@test.local', 'worker',     'active'),
  ('aaaaaaaa-0000-0000-0000-000000000004', 'T-4', 'Inactive Sub','off@test.local',    'sub_admin',  'inactive');

insert into public.sub_admin_permissions (employee_id, permission)
select id, 'site_management' from public.employees where employee_id = 'T-2';
insert into public.sub_admin_permissions (employee_id, permission)
select id, 'site_management' from public.employees where employee_id = 'T-4';

-- 1. write_audit writes one row with a default summary
do $$
declare v_actor uuid; v_id bigint; r public.audit_logs;
begin
  select id into v_actor from public.employees where employee_id = 'T-1';
  v_id := public.write_audit(v_actor, 'SITE_UPDATED', 'site', 'S-1', '{"a":1}', '{"a":2}', 'fix', 'req-1');
  select * into r from public.audit_logs where id = v_id;
  if r.action = 'SITE_UPDATED' and r.actor_employee_id = v_actor and r.entity_id = 'S-1'
     and r.summary = 'Site updated (site S-1)' and r.reason = 'fix' and r.request_id = 'req-1' then
    raise notice 'PASS write_audit stores a row with default summary';
  else raise exception 'FAIL write_audit row: %', to_jsonb(r); end if;
end $$;

-- 2. a custom summary is stored as given
do $$
declare v_id bigint; v_s text;
begin
  v_id := public.write_audit(null, 'INCOME_UPDATED', 'income', 'I-1', null, null, null, 'req-2',
            'Changed site income: ' || public.audit_rupees(20000) || ' -> ' || public.audit_rupees(25050));
  select summary into v_s from public.audit_logs where id = v_id;
  if v_s = 'Changed site income: ₹200 -> ₹250.50' then raise notice 'PASS custom summary and audit_rupees';
  else raise exception 'FAIL custom summary: %', v_s; end if;
end $$;

-- 3. secrets are scrubbed, masked values survive, account number is masked
do $$
declare v_id bigint; n jsonb;
begin
  v_id := public.write_audit(null, 'SETTINGS_UPDATED', 'settings', '1', null,
    jsonb_build_object('password','x','aadhaar','123412341234','aadhaar_last4','1234',
      'aadhaarMasked','XXXX XXXX 1234','account_number','50100012345678','apiKey','k',
      'bank_name','Test Bank','nested', jsonb_build_object('refresh_token','t','ok','fine'),
      'list', jsonb_build_array(jsonb_build_object('secret','s','n',1))),
    null, 'req-3');
  select new_value into n from public.audit_logs where id = v_id;
  if n->>'password' = '[REDACTED]'
     and n->>'aadhaar' = '[REDACTED]'
     and n->>'aadhaar_last4' = '1234'
     and n->>'aadhaarMasked' = 'XXXX XXXX 1234'
     and n->>'account_number' = 'XXXXXXXXXX5678'
     and n->>'apiKey' = '[REDACTED]'
     and n->>'bank_name' = 'Test Bank'
     and n->'nested'->>'refresh_token' = '[REDACTED]'
     and n->'nested'->>'ok' = 'fine'
     and n->'list'->0->>'secret' = '[REDACTED]'
     and n->'list'->0->>'n' = '1'
     and position('123412341234' in n::text) = 0
  then raise notice 'PASS secrets scrubbed, safe fields kept';
  else raise exception 'FAIL scrub: %', n; end if;
end $$;

-- 4. unknown action rejected with MORAYA_VALIDATION
do $$ begin
  begin
    perform public.write_audit(null, 'NOT_A_REAL_ACTION', null, null, null, null, null, 'req-4');
    raise exception 'FAIL unknown action accepted';
  exception when sqlstate 'P0001' then
    if sqlerrm = 'MORAYA_VALIDATION' then raise notice 'PASS unknown action rejected';
    else raise exception 'FAIL wrong code: %', sqlerrm; end if;
  end;
end $$;

-- 5. non-object old/new value rejected
do $$ begin
  begin
    perform public.write_audit(null, 'SITE_UPDATED', 'site', '1', '[1,2]'::jsonb, null, null, 'req-5');
    raise exception 'FAIL array value accepted';
  exception when sqlstate 'P0001' then
    if sqlerrm = 'MORAYA_VALIDATION' then raise notice 'PASS non-object value rejected';
    else raise exception 'FAIL wrong code: %', sqlerrm; end if;
  end;
end $$;

-- 6. audit rows cannot be edited or deleted
do $$ begin
  begin update public.audit_logs set reason = 'x' where request_id = 'req-1';
    raise exception 'FAIL audit update allowed';
  exception when sqlstate 'P0001' then raise notice 'PASS audit update rejected'; end;
  begin delete from public.audit_logs where request_id = 'req-1';
    raise exception 'FAIL audit delete allowed';
  exception when sqlstate 'P0001' then raise notice 'PASS audit delete rejected'; end;
end $$;

-- 7. audit_diff_summary
do $$ declare s text;
begin
  s := public.audit_diff_summary('Changed', '{"site_income":20000,"same":1}', '{"site_income":25000,"same":1}');
  if s = 'Changed site income: 20000 -> 25000' then raise notice 'PASS audit_diff_summary';
  else raise exception 'FAIL diff summary: %', s; end if;
end $$;

-- 8. moraya_require_actor
do $$
declare a public.employees;
begin
  a := public.moraya_require_actor('aaaaaaaa-0000-0000-0000-000000000001', true, null);
  if a.employee_id = 'T-1' then raise notice 'PASS main admin passes main-admin-only'; else raise exception 'FAIL'; end if;

  a := public.moraya_require_actor('aaaaaaaa-0000-0000-0000-000000000001', false, array['export']);
  raise notice 'PASS main admin passes any permission';

  a := public.moraya_require_actor('aaaaaaaa-0000-0000-0000-000000000002', false, array['report_view','site_management']);
  raise notice 'PASS sub admin with one of the permissions passes';

  begin a := public.moraya_require_actor('aaaaaaaa-0000-0000-0000-000000000002', false, array['salary_management']);
    raise exception 'FAIL sub admin without permission passed';
  exception when sqlstate 'P0001' then
    if sqlerrm = 'MORAYA_FORBIDDEN' then raise notice 'PASS sub admin without permission refused';
    else raise exception 'FAIL code %', sqlerrm; end if; end;

  begin a := public.moraya_require_actor('aaaaaaaa-0000-0000-0000-000000000002', true, null);
    raise exception 'FAIL sub admin passed main-admin-only';
  exception when sqlstate 'P0001' then
    if sqlerrm = 'MORAYA_FORBIDDEN' then raise notice 'PASS sub admin refused main-admin-only';
    else raise exception 'FAIL code %', sqlerrm; end if; end;

  begin a := public.moraya_require_actor('aaaaaaaa-0000-0000-0000-000000000003', false, array['site_management']);
    raise exception 'FAIL worker passed';
  exception when sqlstate 'P0001' then
    if sqlerrm = 'MORAYA_FORBIDDEN' then raise notice 'PASS worker refused';
    else raise exception 'FAIL code %', sqlerrm; end if; end;

  begin a := public.moraya_require_actor('aaaaaaaa-0000-0000-0000-000000000004', false, array['site_management']);
    raise exception 'FAIL inactive user passed';
  exception when sqlstate 'P0001' then
    if sqlerrm = 'MORAYA_FORBIDDEN' then raise notice 'PASS inactive user refused';
    else raise exception 'FAIL code %', sqlerrm; end if; end;

  begin a := public.moraya_require_actor('bbbbbbbb-0000-0000-0000-000000000000', false, null);
    raise exception 'FAIL unknown auth user passed';
  exception when sqlstate 'P0001' then
    if sqlerrm = 'MORAYA_FORBIDDEN' then raise notice 'PASS unknown auth user refused';
    else raise exception 'FAIL code %', sqlerrm; end if; end;

  begin a := public.moraya_require_actor('aaaaaaaa-0000-0000-0000-000000000001', false, array['typo_permission']);
    raise exception 'FAIL typo permission accepted';
  exception when sqlstate 'P0001' then
    if sqlerrm = 'MORAYA_VALIDATION' then raise notice 'PASS unknown permission name rejected';
    else raise exception 'FAIL code %', sqlerrm; end if; end;
end $$;

-- 9. privileges: service_role only
do $$ begin
  if has_function_privilege('service_role', 'public.write_audit(uuid,text,text,text,jsonb,jsonb,text,text,text)', 'execute')
     and not has_function_privilege('anon', 'public.write_audit(uuid,text,text,text,jsonb,jsonb,text,text,text)', 'execute')
     and not has_function_privilege('authenticated', 'public.write_audit(uuid,text,text,text,jsonb,jsonb,text,text,text)', 'execute')
     and not has_function_privilege('authenticated', 'public.moraya_require_actor(uuid,boolean,text[])', 'execute')
     and not has_function_privilege('anon', 'public.protect_main_admin()', 'execute')
     and not has_table_privilege('authenticated', 'public.employees', 'select')
     and not has_table_privilege('service_role', 'public.employees', 'delete')
  then raise notice 'PASS grants are service_role only';
  else raise exception 'FAIL grants'; end if;
end $$;

-- 10. old objects still behave (existing function and triggers)
do $$ begin
  perform public.get_auth_profile('aaaaaaaa-0000-0000-0000-000000000001');
  begin update public.employees set role = 'worker' where employee_id = 'T-1';
    raise exception 'FAIL main admin demoted';
  exception when sqlstate 'P0001' then raise notice 'PASS 002 trigger still protects main admin'; end;
end $$;

rollback;