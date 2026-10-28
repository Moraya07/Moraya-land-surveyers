-- 028_031_list_functions_tests.sql
-- Tests for migrations 028-031: list_expenses, list_my_expenses, list_my_sites, list_employee_activity.
-- Self-contained like moraya_all_tests.sql: creates its own fake users, sites, work entries and audit rows
-- through the real functions, prints one PASS/FAIL NOTICE per check, and ROLLS EVERYTHING BACK.
--
-- RUN ON AN EMPTY DEV/TEST DATABASE ONLY (migrations 001-026 and 028-031 applied, no seed rows).
--   * Aborts at once if public.employees has any row.
--   * Supabase SQL editor (runs as postgres) or: psql "$DB_URL" -f supabase/tests/028_031_list_functions_tests.sql
--   * Ends with "ALL n CHECKS PASSED" or the exception "FAILED: x of n checks failed".
--
-- FAKE DATA (paise; Rs 500 = 50000)
--   People : T-MAIN main admin | T-SUB sub admin, all 7 permissions | T-SUBR report_view only
--            T-SUBS site_management only | T-W1, T-W2 workers | T-WI inactive worker
--   Sites  : A, B
--   Work   : WE1 A, W1 (+W2 assistant), 05 Oct, 50000 -> VERIFIED
--            WE2 A, W2 (+W1 assistant), 05 Oct, 30000 -> VERIFIED
--            WE3 B, W1,                 06 Oct, 20000 -> PENDING
--            WE4 A, W1,                 07 Oct, 70000 -> REJECTED
--            WE5 A, W2,                 08 Oct, 10000 -> CHANGES REQUESTED
--            WE6 A, W2,                 09 Oct, 90000 -> VERIFIED then CANCELLED
--   Audit  : four rows about W1 (created, updated, aadhaar changed, aadhaar revealed) and one about W2.

begin;

-- 0. Safety guard
do $$
begin
  if exists (select 1 from public.employees) then
    raise exception 'STOP: public.employees is not empty. Run this file only on an empty dev/test database.';
  end if;
end $$;

-- 1. Helpers (temporary)
create temp table test_results (n serial primary key, name text not null, passed boolean not null, detail text);
create temp table ctx (k text primary key, v uuid not null);

create function pg_temp.chk(p_name text, p_ok boolean, p_detail text default null) returns void
language plpgsql as $$
begin
  insert into pg_temp.test_results (name, passed, detail) values (p_name, coalesce(p_ok, false), p_detail);
  if coalesce(p_ok, false) then
    raise notice 'PASS  %', p_name;
  else
    raise notice 'FAIL  % %', p_name, coalesce('(' || p_detail || ')', '');
  end if;
end $$;

create function pg_temp.chk_eq(p_name text, p_actual bigint, p_expected bigint) returns void
language plpgsql as $$
begin
  perform pg_temp.chk(p_name, p_actual is not null and p_actual = p_expected,
                      'expected ' || p_expected::text || ', got ' || coalesce(p_actual::text, 'null'));
end $$;

-- Runs p_sql and passes when it raises the expected error.
--   p_msg  : exact error message (e.g. MORAYA_FORBIDDEN); a trailing % makes it a LIKE pattern
--   p_state: expected SQLSTATE (e.g. 23505). Either, both or neither may be given.
create function pg_temp.expect_err(p_name text, p_sql text, p_msg text default null, p_state text default null) returns void
language plpgsql as $$
declare
  v_raised boolean := false;
  v_msg    text;
  v_state  text;
  v_ok     boolean;
begin
  begin
    execute p_sql;
  exception when others then
    v_raised := true; v_msg := sqlerrm; v_state := sqlstate;
  end;
  v_ok := v_raised
          and (p_msg is null or (case when right(p_msg, 1) = '%' then v_msg like p_msg else v_msg = p_msg end))
          and (p_state is null or v_state = p_state);
  perform pg_temp.chk(p_name, v_ok,
    'expected ' || coalesce(p_msg, p_state, 'any error') || ', got ' ||
    case when v_raised then coalesce(v_state, '') || ' ' || coalesce(v_msg, '') else 'no error' end);
end $$;

create function pg_temp.put(p_k text, p_v uuid) returns uuid language sql as
$$ insert into pg_temp.ctx (k, v) values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $$;
create function pg_temp.g(p_k text) returns uuid language sql as
$$ select v from pg_temp.ctx where k = p_k $$;
create function pg_temp.eid(p_code text) returns uuid language sql as
$$ select id from public.employees where employee_id = p_code $$;
create function pg_temp.aid(p_code text) returns uuid language sql as
$$ select auth_user_id from public.employees where employee_id = p_code $$;

-- surveyor submits a work entry; returns its id
create function pg_temp.submit(p_actor text, p_site text, p_date date, p_time time, p_assistant text, p_amount bigint) returns uuid
language sql as $$
  select (public.submit_work_entry(
            pg_temp.aid(p_actor), pg_temp.g(p_site), p_date, p_time,
            case when p_assistant is null then null else pg_temp.eid(p_assistant) end,
            p_amount, case when p_amount is null then null else 'travel' end, null, null)
          -> 'work_entry' ->> 'id')::uuid
$$;

-- 2. Fake users and permissions
do $$
begin
  insert into auth.users (id, email) values
    ('a0000000-0000-0000-0000-000000000001', 'main@test.local'),
    ('a0000000-0000-0000-0000-000000000002', 'sub@test.local'),
    ('a0000000-0000-0000-0000-000000000003', 'subr@test.local'),
    ('a0000000-0000-0000-0000-000000000004', 'subs@test.local'),
    ('a0000000-0000-0000-0000-000000000005', 'w1@test.local'),
    ('a0000000-0000-0000-0000-000000000006', 'w2@test.local'),
    ('a0000000-0000-0000-0000-000000000007', 'wi@test.local');

  insert into public.employees (auth_user_id, employee_id, name, login_email, role, designation)
  values ('a0000000-0000-0000-0000-000000000001', 'T-MAIN', 'Test Main Admin', 'main@test.local', 'main_admin', 'Director');

  insert into public.employees (auth_user_id, employee_id, name, login_email, role, designation) values
    ('a0000000-0000-0000-0000-000000000002', 'T-SUB',  'Test Sub Admin',       'sub@test.local',  'sub_admin', 'Manager'),
    ('a0000000-0000-0000-0000-000000000003', 'T-SUBR', 'Test Sub Reports',     'subr@test.local', 'sub_admin', 'Analyst'),
    ('a0000000-0000-0000-0000-000000000004', 'T-SUBS', 'Test Sub Sites',       'subs@test.local', 'sub_admin', 'Coordinator'),
    ('a0000000-0000-0000-0000-000000000005', 'T-W1',   'Test Worker One',      'w1@test.local',   'worker',    'Surveyor'),
    ('a0000000-0000-0000-0000-000000000006', 'T-W2',   'Test Worker Two',      'w2@test.local',   'worker',    'Assistant'),
    ('a0000000-0000-0000-0000-000000000007', 'T-WI',   'Test Worker Inactive', 'wi@test.local',   'worker',    'Surveyor');

  insert into public.sub_admin_permissions (employee_id, permission)
  select pg_temp.eid('T-SUB'), p
  from unnest(array['employee_management','site_management','verification','income_management',
                    'salary_management','report_view','export']) as p;
  insert into public.sub_admin_permissions (employee_id, permission) values
    (pg_temp.eid('T-SUBR'), 'report_view'),
    (pg_temp.eid('T-SUBS'), 'site_management');

  update public.employees set account_status = 'inactive' where employee_id = 'T-WI';
end $$;

-- 3. Fake business data (only through the real functions)
do $$
declare
  s uuid := pg_temp.aid('T-SUB');
  m uuid := pg_temp.eid('T-MAIN');
  w1 uuid := pg_temp.eid('T-W1');
  w2 uuid := pg_temp.eid('T-W2');
begin
  perform pg_temp.put('siteA', (public.create_site(s, 'Test Site A', 'Test Client A', 'Test Location A', date '2026-10-01', 100000) -> 'site' ->> 'id')::uuid);
  perform pg_temp.put('siteB', (public.create_site(s, 'Test Site B', 'Test Client B', 'Test Location B', date '2026-10-01', 150000) -> 'site' ->> 'id')::uuid);

  perform pg_temp.put('we1', pg_temp.submit('T-W1', 'siteA', date '2026-10-05', time '10:00', 'T-W2', 50000));
  perform pg_temp.put('we2', pg_temp.submit('T-W2', 'siteA', date '2026-10-05', time '11:00', 'T-W1', 30000));
  perform pg_temp.put('we3', pg_temp.submit('T-W1', 'siteB', date '2026-10-06', time '09:00', null,    20000));
  perform pg_temp.put('we4', pg_temp.submit('T-W1', 'siteA', date '2026-10-07', time '09:30', null,    70000));
  perform pg_temp.put('we5', pg_temp.submit('T-W2', 'siteA', date '2026-10-08', time '09:30', null,    10000));
  perform pg_temp.put('we6', pg_temp.submit('T-W2', 'siteA', date '2026-10-09', time '09:30', null,    90000));

  perform public.approve_work_entry(s, pg_temp.g('we1'));
  perform public.approve_work_entry(s, pg_temp.g('we2'));
  perform public.reject_work_entry(s, pg_temp.g('we4'), 'Wrong site recorded');
  perform public.request_work_entry_changes(s, pg_temp.g('we5'), 'Please fix the time');
  perform public.approve_work_entry(s, pg_temp.g('we6'));
  perform public.cancel_work_entry(s, pg_temp.g('we6'), 'Entered by mistake');

  -- audit rows about W1 (oldest first), one about W2
  perform public.write_audit(m, 'USER_CREATED', 'employee', w1::text, null,
    jsonb_build_object('employee_code', 'T-W1', 'name', 'Test Worker One', 'password', 'Secret123'),
    null, 'req-1', 'Created employee T-W1');
  perform public.write_audit(m, 'USER_UPDATED', 'employee', w1::text,
    jsonb_build_object('designation', 'Surveyor'), jsonb_build_object('designation', 'Senior Surveyor'),
    null, 'req-2', 'Changed employee T-W1');
  perform public.write_audit(m, 'USER_AADHAAR_CHANGED', 'employee', w1::text,
    jsonb_build_object('aadhaar_masked', 'XXXX XXXX 1111'), jsonb_build_object('aadhaar_masked', 'XXXX XXXX 2222'),
    null, 'req-3', 'Aadhaar replaced for T-W1');
  perform public.write_audit(m, 'AADHAAR_REVEALED', 'employee', w1::text, null,
    jsonb_build_object('employee_code', 'T-W1', 'aadhaar_masked', 'XXXX XXXX 2222'),
    'Identity check', 'req-4', 'Revealed Aadhaar of T-W1');
  perform public.write_audit(m, 'USER_UPDATED', 'employee', w2::text,
    jsonb_build_object('designation', 'Assistant'), jsonb_build_object('designation', 'Senior Assistant'),
    null, 'req-5', 'Changed employee T-W2');
end $$;

-- =====================================================================================
-- PART A. list_expenses (028)
-- =====================================================================================
do $$
declare
  s  uuid := pg_temp.aid('T-SUB');
  m  uuid := pg_temp.aid('T-MAIN');
  sr uuid := pg_temp.aid('T-SUBR');
  ss uuid := pg_temp.aid('T-SUBS');
  w1 uuid := pg_temp.aid('T-W1');
  wi uuid := pg_temp.aid('T-WI');
  r  jsonb;
begin
  r := public.list_expenses(s);
  perform pg_temp.chk_eq('A1 sub admin sees all 6 expenses', (r ->> 'total')::bigint, 6);
  perform pg_temp.chk_eq('A1 default page size is 20', (r ->> 'page_size')::bigint, 20);
  perform pg_temp.chk_eq('A1 totals: verified 2', (r -> 'totals' ->> 'verified')::bigint, 2);
  perform pg_temp.chk_eq('A1 totals: pending 1', (r -> 'totals' ->> 'pending_verification')::bigint, 1);
  perform pg_temp.chk_eq('A1 totals: rejected 1', (r -> 'totals' ->> 'rejected')::bigint, 1);
  perform pg_temp.chk_eq('A1 totals: changes requested 1', (r -> 'totals' ->> 'changes_requested')::bigint, 1);
  perform pg_temp.chk_eq('A1 totals: cancelled 1', (r -> 'totals' ->> 'cancelled')::bigint, 1);
  perform pg_temp.chk_eq('A1 amounts: verified 80000', (r -> 'amounts' ->> 'verified')::bigint, 80000);
  perform pg_temp.chk_eq('A1 amounts: pending 20000', (r -> 'amounts' ->> 'pending_verification')::bigint, 20000);
  perform pg_temp.chk_eq('A1 amounts: cancelled 90000', (r -> 'amounts' ->> 'cancelled')::bigint, 90000);
  perform pg_temp.chk('A1 amount is a whole number of paise (no decimals)',
    not exists (select 1 from jsonb_array_elements(r -> 'items') x where (x ->> 'amount') !~ '^[0-9]+$'));
  perform pg_temp.chk('A1 every item has an employee object and a site object',
    not exists (select 1 from jsonb_array_elements(r -> 'items') x where not (x ? 'employee') or not (x ? 'site')));
  perform pg_temp.chk('A1 newest expense_date first (WE6, 9 Oct)',
    (r -> 'items' -> 0 ->> 'expense_date') = '2026-10-09');

  perform pg_temp.chk_eq('A2 main admin allowed', (public.list_expenses(m) ->> 'total')::bigint, 6);
  perform pg_temp.chk_eq('A2 report_view sub admin allowed', (public.list_expenses(sr) ->> 'total')::bigint, 6);

  r := public.list_expenses(s, p_status => 'verified');
  perform pg_temp.chk_eq('A3 status verified: total 2', (r ->> 'total')::bigint, 2);
  perform pg_temp.chk_eq('A3 status filter does not change the totals block', (r -> 'totals' ->> 'pending_verification')::bigint, 1);
  r := public.list_expenses(s, p_employee_id => pg_temp.eid('T-W1'));
  perform pg_temp.chk_eq('A3 employee W1: total 3', (r ->> 'total')::bigint, 3);
  r := public.list_expenses(s, p_site_id => pg_temp.g('siteB'));
  perform pg_temp.chk_eq('A3 site B: total 1', (r ->> 'total')::bigint, 1);
  r := public.list_expenses(s, p_date_from => date '2026-10-05', p_date_to => date '2026-10-06');
  perform pg_temp.chk_eq('A3 date range 5-6 Oct: total 3', (r ->> 'total')::bigint, 3);
  r := public.list_expenses(s, p_category => 'travel');
  perform pg_temp.chk_eq('A3 category travel: total 6', (r ->> 'total')::bigint, 6);
  r := public.list_expenses(s, p_q => 'Test Site B');
  perform pg_temp.chk_eq('A3 search by site name: total 1', (r ->> 'total')::bigint, 1);
  r := public.list_expenses(s, p_q => 'Worker One');
  perform pg_temp.chk_eq('A3 search by employee name: total 3', (r ->> 'total')::bigint, 3);
  r := public.list_expenses(s, p_q => '%');
  perform pg_temp.chk_eq('A3 a lone % is literal, not a wildcard: total 0', (r ->> 'total')::bigint, 0);

  r := public.list_expenses(s, p_sort => 'amount:desc');
  perform pg_temp.chk_eq('A4 sort amount desc: first is 90000', (r -> 'items' -> 0 ->> 'amount')::bigint, 90000);
  r := public.list_expenses(s, p_sort => 'amount:asc');
  perform pg_temp.chk_eq('A4 sort amount asc: first is 10000', (r -> 'items' -> 0 ->> 'amount')::bigint, 10000);

  r := public.list_expenses(s, p_page => 1, p_page_size => 2);
  perform pg_temp.chk_eq('A5 page size 2: 2 items', jsonb_array_length(r -> 'items'), 2);
  perform pg_temp.chk_eq('A5 page size 2: total still 6', (r ->> 'total')::bigint, 6);
  r := public.list_expenses(s, p_page => 3, p_page_size => 2);
  perform pg_temp.chk_eq('A5 page 3 of 2: 2 items', jsonb_array_length(r -> 'items'), 2);
  r := public.list_expenses(s, p_page => 4, p_page_size => 2);
  perform pg_temp.chk_eq('A5 page 4 of 2: 0 items', jsonb_array_length(r -> 'items'), 0);
  r := public.list_expenses(s, p_page_size => 1000);
  perform pg_temp.chk_eq('A5 page size 1000 is capped to 100', (r ->> 'page_size')::bigint, 100);
  r := public.list_expenses(s, p_page_size => 0);
  perform pg_temp.chk_eq('A5 page size 0 is raised to 1', (r ->> 'page_size')::bigint, 1);

  perform pg_temp.expect_err('A6 invalid sort field', format('select public.list_expenses(%L, p_sort => %L)', s, 'amount; drop table x:asc'), 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('A6 invalid sort direction', format('select public.list_expenses(%L, p_sort => %L)', s, 'amount:up'), 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('A6 invalid status', format('select public.list_expenses(%L, p_status => %L)', s, 'paid'), 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('A6 invalid category', format('select public.list_expenses(%L, p_category => %L)', s, 'nonexistent'), 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('A6 reversed date range', format('select public.list_expenses(%L, p_date_from => %L, p_date_to => %L)', s, '2026-10-10', '2026-10-01'), 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('A6 search text over 100 characters', format('select public.list_expenses(%L, p_q => %L)', s, repeat('x', 101)), 'MORAYA_VALIDATION');

  perform pg_temp.expect_err('A7 worker is forbidden', format('select public.list_expenses(%L)', w1), 'MORAYA_FORBIDDEN');
  perform pg_temp.expect_err('A7 sub admin with only site_management is forbidden', format('select public.list_expenses(%L)', ss), 'MORAYA_FORBIDDEN');
  perform pg_temp.expect_err('A7 inactive worker is forbidden', format('select public.list_expenses(%L)', wi), 'MORAYA_FORBIDDEN');
  perform pg_temp.expect_err('A7 unknown auth user is forbidden', format('select public.list_expenses(%L)', gen_random_uuid()), 'MORAYA_FORBIDDEN');
end $$;

-- =====================================================================================
-- PART B. list_my_expenses (029)
-- =====================================================================================
do $$
declare
  m  uuid := pg_temp.aid('T-MAIN');
  w1 uuid := pg_temp.aid('T-W1');
  w2 uuid := pg_temp.aid('T-W2');
  wi uuid := pg_temp.aid('T-WI');
  r  jsonb;
begin
  r := public.list_my_expenses(w1);
  perform pg_temp.chk_eq('B1 W1 sees own 3 expenses (WE1, WE3, WE4)', (r ->> 'total')::bigint, 3);
  perform pg_temp.chk('B1 W1 does not see the expense of WE2 (W1 was only the assistant)',
    not exists (select 1 from jsonb_array_elements(r -> 'items') x where x ->> 'work_entry_id' = pg_temp.g('we2')::text));
  perform pg_temp.chk('B1 no employee object in the worker list',
    not exists (select 1 from jsonb_array_elements(r -> 'items') x where x ? 'employee'));
  perform pg_temp.chk_eq('B1 amounts: verified 50000', (r -> 'amounts' ->> 'verified')::bigint, 50000);

  r := public.list_my_expenses(w2);
  perform pg_temp.chk_eq('B2 W2 sees own 3 expenses (WE2, WE5, WE6)', (r ->> 'total')::bigint, 3);
  perform pg_temp.chk('B2 W2 never sees the expense of WE1 (assistant: no amounts)',
    not exists (select 1 from jsonb_array_elements(r -> 'items') x where x ->> 'work_entry_id' = pg_temp.g('we1')::text)
    and not exists (select 1 from jsonb_array_elements(r -> 'items') x where (x ->> 'amount')::bigint = 50000));
  perform pg_temp.chk_eq('B2 cancelled expense is listed as cancelled', (r -> 'totals' ->> 'cancelled')::bigint, 1);

  r := public.list_my_expenses(w1, p_status => 'rejected');
  perform pg_temp.chk_eq('B3 status filter rejected: 1', (r ->> 'total')::bigint, 1);
  r := public.list_my_expenses(w1, p_site_id => pg_temp.g('siteB'));
  perform pg_temp.chk_eq('B3 site filter B: 1', (r ->> 'total')::bigint, 1);
  r := public.list_my_expenses(w1, p_page_size => 5000);
  perform pg_temp.chk_eq('B3 page size capped to 100', (r ->> 'page_size')::bigint, 100);

  perform pg_temp.chk_eq('B4 an admin sees only expenses they submitted themselves (none)', (public.list_my_expenses(m) ->> 'total')::bigint, 0);
  perform pg_temp.expect_err('B4 invalid sort', format('select public.list_my_expenses(%L, p_sort => %L)', w1, 'owner:asc'), 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('B4 inactive worker is forbidden', format('select public.list_my_expenses(%L)', wi), 'MORAYA_FORBIDDEN');
end $$;

-- =====================================================================================
-- PART C. list_my_sites (030)
-- =====================================================================================
do $$
declare
  m  uuid := pg_temp.aid('T-MAIN');
  w1 uuid := pg_temp.aid('T-W1');
  w2 uuid := pg_temp.aid('T-W2');
  wi uuid := pg_temp.aid('T-WI');
  r  jsonb;
  v  jsonb;
begin
  r := public.list_my_sites(w1);
  perform pg_temp.chk_eq('C1 W1 has 2 sites (A and B)', (r ->> 'total')::bigint, 2);
  select x into v from jsonb_array_elements(r -> 'items') x where (x ->> 'id')::uuid = pg_temp.g('siteA');
  perform pg_temp.chk_eq('C1 W1 site A: entry_count 2 (WE1, WE2; the rejected WE4 is not counted)', (v ->> 'entry_count')::bigint, 2);
  perform pg_temp.chk_eq('C1 W1 site A: verified_entry_count 2', (v ->> 'verified_entry_count')::bigint, 2);
  perform pg_temp.chk_eq('C1 W1 site A: visit_count 1 (two verified entries on one day)', (v ->> 'visit_count')::bigint, 1);
  select x into v from jsonb_array_elements(r -> 'items') x where (x ->> 'id')::uuid = pg_temp.g('siteB');
  perform pg_temp.chk_eq('C1 W1 site B: entry_count 1', (v ->> 'entry_count')::bigint, 1);
  perform pg_temp.chk_eq('C1 W1 site B: visit_count 0 (pending is not a visit yet)', (v ->> 'visit_count')::bigint, 0);
  perform pg_temp.chk('C1 W1 site B: last_work_date 2026-10-06', (v ->> 'last_work_date') = '2026-10-06');
  perform pg_temp.chk('C1 no rate and no money anywhere in the response',
    position('rate' in r::text) = 0 and position('amount' in r::text) = 0 and position('site_date' in r::text) = 0);

  r := public.list_my_sites(w2);
  perform pg_temp.chk_eq('C2 W2 has 1 site (A; as surveyor and as assistant)', (r ->> 'total')::bigint, 1);
  v := r -> 'items' -> 0;
  perform pg_temp.chk_eq('C2 W2 site A: entry_count 3 (WE2, WE5, WE1; the cancelled WE6 is not counted)', (v ->> 'entry_count')::bigint, 3);
  perform pg_temp.chk_eq('C2 W2 site A: verified_entry_count 2', (v ->> 'verified_entry_count')::bigint, 2);
  perform pg_temp.chk_eq('C2 W2 site A: visit_count 1', (v ->> 'visit_count')::bigint, 1);
  perform pg_temp.chk('C2 W2 site A: last_work_date 2026-10-08', (v ->> 'last_work_date') = '2026-10-08');

  r := public.list_my_sites(w1, p_q => 'Site B');
  perform pg_temp.chk_eq('C3 search Site B: 1', (r ->> 'total')::bigint, 1);
  r := public.list_my_sites(w1, p_status => 'completed');
  perform pg_temp.chk_eq('C3 status completed: 0', (r ->> 'total')::bigint, 0);
  r := public.list_my_sites(w1, p_sort => 'site_name:desc');
  perform pg_temp.chk('C3 sort site_name desc: Site B first', (r -> 'items' -> 0 ->> 'site_name') = 'Test Site B');
  r := public.list_my_sites(w1, p_page_size => 1);
  perform pg_temp.chk_eq('C3 page size 1: 1 item, total 2', jsonb_array_length(r -> 'items') * 10 + (r ->> 'total')::int, 12);
  r := public.list_my_sites(w1, p_page_size => 9999);
  perform pg_temp.chk_eq('C3 page size capped to 100', (r ->> 'page_size')::bigint, 100);

  perform pg_temp.chk_eq('C4 main admin without own work entries: 0 sites', (public.list_my_sites(m) ->> 'total')::bigint, 0);
  perform pg_temp.expect_err('C4 invalid sort', format('select public.list_my_sites(%L, p_sort => %L)', w1, 'rate_per_visit:asc'), 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('C4 invalid status', format('select public.list_my_sites(%L, p_status => %L)', w1, 'deleted'), 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('C4 inactive worker is forbidden', format('select public.list_my_sites(%L)', wi), 'MORAYA_FORBIDDEN');
end $$;

-- =====================================================================================
-- PART D. list_employee_activity (031)
-- =====================================================================================
do $$
declare
  m  uuid := pg_temp.aid('T-MAIN');
  s  uuid := pg_temp.aid('T-SUB');
  sr uuid := pg_temp.aid('T-SUBR');
  w1a uuid := pg_temp.aid('T-W1');
  wi uuid := pg_temp.aid('T-WI');
  w1 uuid := pg_temp.eid('T-W1');
  w2 uuid := pg_temp.eid('T-W2');
  r  jsonb;
  v  jsonb;
begin
  r := public.list_employee_activity(m, w1);
  perform pg_temp.chk_eq('D1 main admin sees all 4 rows about W1', (r ->> 'total')::bigint, 4);
  perform pg_temp.chk('D1 newest first: the Aadhaar reveal', (r -> 'items' -> 0 ->> 'action') = 'AADHAAR_REVEALED');
  perform pg_temp.chk('D1 main admin sees the reason of the reveal', (r -> 'items' -> 0 ->> 'reason') = 'Identity check');
  perform pg_temp.chk('D1 row about W2 is not in the list of W1',
    not exists (select 1 from jsonb_array_elements(r -> 'items') x where x ->> 'summary' like '%T-W2%'));

  r := public.list_employee_activity(s, w1);
  perform pg_temp.chk_eq('D2 sub admin (employee_management) sees 3 rows: reveal rows are hidden', (r ->> 'total')::bigint, 3);
  perform pg_temp.chk('D2 no AADHAAR_REVEALED row for the sub admin',
    not exists (select 1 from jsonb_array_elements(r -> 'items') x where x ->> 'action' = 'AADHAAR_REVEALED'));
  perform pg_temp.chk('D2 sub admin newest row is USER_AADHAAR_CHANGED', (r -> 'items' -> 0 ->> 'action') = 'USER_AADHAAR_CHANGED');
  perform pg_temp.chk('D2 the reveal reason does not appear anywhere in the sub admin response', position('Identity check' in r::text) = 0);

  v := r -> 'items' -> 1;
  perform pg_temp.chk('D3 USER_UPDATED: one change, designation', jsonb_array_length(v -> 'changes') = 1 and (v -> 'changes' -> 0 ->> 'field') = 'designation');
  perform pg_temp.chk('D3 USER_UPDATED: from Surveyor to Senior Surveyor',
    (v -> 'changes' -> 0 ->> 'from') = 'Surveyor' and (v -> 'changes' -> 0 ->> 'to') = 'Senior Surveyor');
  perform pg_temp.chk('D3 actor name is returned', (v ->> 'actor_name') = 'Test Main Admin');
  v := r -> 'items' -> 2;
  perform pg_temp.chk('D3 USER_CREATED: password field never appears', position('password' in v::text) = 0 and position('Secret123' in r::text) = 0);
  perform pg_temp.chk('D3 USER_CREATED: name is listed as a change', exists (select 1 from jsonb_array_elements(v -> 'changes') c where c ->> 'field' = 'name'));
  perform pg_temp.chk('D3 Aadhaar change shows only masked values',
    exists (select 1 from jsonb_array_elements(r -> 'items' -> 0 -> 'changes') c where c ->> 'field' = 'aadhaar_masked' and (c ->> 'to') = 'XXXX XXXX 2222'));

  perform pg_temp.chk('D4 no old_value, new_value, ip, user_agent or request_id in any item',
    not exists (select 1 from jsonb_array_elements(r -> 'items') x
                where x ? 'old_value' or x ? 'new_value' or x ? 'ip' or x ? 'user_agent' or x ? 'request_id' or x ? 'actor_employee_id'));
  perform pg_temp.chk('D4 request ids are not in the response text', position('req-' in r::text) = 0);

  perform pg_temp.chk_eq('D5 the activity of W2 has 1 row', (public.list_employee_activity(m, w2) ->> 'total')::bigint, 1);
  r := public.list_employee_activity(m, w1, 1, 1);
  perform pg_temp.chk_eq('D5 page size 1: 1 item, total 4', jsonb_array_length(r -> 'items') * 10 + (r ->> 'total')::int, 14);
  r := public.list_employee_activity(m, w1, 1, 1000);
  perform pg_temp.chk_eq('D5 page size capped to 100', (r ->> 'page_size')::bigint, 100);
  r := public.list_employee_activity(m, w1, 2, 3);
  perform pg_temp.chk_eq('D5 page 2 of size 3: 1 item', jsonb_array_length(r -> 'items'), 1);

  perform pg_temp.expect_err('D6 report_view-only sub admin is forbidden', format('select public.list_employee_activity(%L, %L)', sr, w1), 'MORAYA_FORBIDDEN');
  perform pg_temp.expect_err('D6 worker is forbidden', format('select public.list_employee_activity(%L, %L)', w1a, w1), 'MORAYA_FORBIDDEN');
  perform pg_temp.expect_err('D6 inactive worker is forbidden', format('select public.list_employee_activity(%L, %L)', wi, w1), 'MORAYA_FORBIDDEN');
  perform pg_temp.expect_err('D6 unknown employee', format('select public.list_employee_activity(%L, %L)', s, gen_random_uuid()), 'MORAYA_NOT_FOUND');
  perform pg_temp.expect_err('D6 missing employee id', format('select public.list_employee_activity(%L, null)', s), 'MORAYA_VALIDATION');
end $$;

-- =====================================================================================
-- PART E. Grants: service_role only; the helpers are closed to everyone
-- =====================================================================================
do $$
begin
  perform pg_temp.chk('E1 list_expenses: service_role yes, anon and authenticated no',
    has_function_privilege('service_role', 'public.list_expenses(uuid,date,date,uuid,uuid,text,text,text,text,integer,integer)', 'execute')
    and not has_function_privilege('anon', 'public.list_expenses(uuid,date,date,uuid,uuid,text,text,text,text,integer,integer)', 'execute')
    and not has_function_privilege('authenticated', 'public.list_expenses(uuid,date,date,uuid,uuid,text,text,text,text,integer,integer)', 'execute'));
  perform pg_temp.chk('E1 list_my_expenses: service_role yes, anon and authenticated no',
    has_function_privilege('service_role', 'public.list_my_expenses(uuid,date,date,uuid,text,text,text,text,integer,integer)', 'execute')
    and not has_function_privilege('anon', 'public.list_my_expenses(uuid,date,date,uuid,text,text,text,text,integer,integer)', 'execute')
    and not has_function_privilege('authenticated', 'public.list_my_expenses(uuid,date,date,uuid,text,text,text,text,integer,integer)', 'execute'));
  perform pg_temp.chk('E1 list_my_sites: service_role yes, anon and authenticated no',
    has_function_privilege('service_role', 'public.list_my_sites(uuid,text,text,text,integer,integer)', 'execute')
    and not has_function_privilege('anon', 'public.list_my_sites(uuid,text,text,text,integer,integer)', 'execute')
    and not has_function_privilege('authenticated', 'public.list_my_sites(uuid,text,text,text,integer,integer)', 'execute'));
  perform pg_temp.chk('E1 list_employee_activity: service_role yes, anon and authenticated no',
    has_function_privilege('service_role', 'public.list_employee_activity(uuid,uuid,integer,integer)', 'execute')
    and not has_function_privilege('anon', 'public.list_employee_activity(uuid,uuid,integer,integer)', 'execute')
    and not has_function_privilege('authenticated', 'public.list_employee_activity(uuid,uuid,integer,integer)', 'execute'));
  perform pg_temp.chk('E2 helpers expenses_page and employee_activity_changes: nobody can execute them',
    not has_function_privilege('service_role', 'public.expenses_page(uuid,text,date,date,uuid,uuid,text,text,text,text,integer,integer)', 'execute')
    and not has_function_privilege('anon', 'public.expenses_page(uuid,text,date,date,uuid,uuid,text,text,text,text,integer,integer)', 'execute')
    and not has_function_privilege('service_role', 'public.employee_activity_changes(jsonb,jsonb)', 'execute')
    and not has_function_privilege('authenticated', 'public.employee_activity_changes(jsonb,jsonb)', 'execute'));
end $$;

-- =====================================================================================
-- RESULT
-- =====================================================================================
select n, case when passed then 'PASS' else 'FAIL' end as result, name, detail
from test_results
order by passed, n;

do $$
declare
  v_fail  int;
  v_total int;
begin
  select count(*) filter (where not passed), count(*) into v_fail, v_total from pg_temp.test_results;
  if v_fail > 0 then
    raise exception 'FAILED: % of % checks failed. Read the FAIL notices above (or the result table).', v_fail, v_total;
  end if;
  raise notice 'ALL % CHECKS PASSED', v_total;
end $$;

rollback;