-- moraya_all_tests.sql
-- ONE self-contained test file: financial consistency + permissions + state machine + dates +
-- Main Admin protection + Aadhaar + delete protection.
-- It replaces the two files from the prompt list (financial_consistency.sql and
-- permissions_and_state.sql) and needs NO seed file: it creates its own fake users, sites, work
-- entries, expenses, income and salary rows, checks them, and ROLLS EVERYTHING BACK at the end.
--
-- RUN IT ON AN EMPTY DEV/TEST DATABASE ONLY (migrations 001-026 applied, no seed rows, no real data).
--   * The first statement aborts if public.employees has any row (the exact numbers below assume an
--     empty database, and the test creates its own Main Admin).
--   * Supabase SQL editor (runs as postgres) or: psql "$DB_URL" -f supabase/tests/moraya_all_tests.sql
--   * Output: one NOTICE per check ("PASS name" / "FAIL name (detail)"), then a result table, then
--     "ALL n CHECKS PASSED", or an exception "FAILED: x of n checks failed" when anything fails.
--   * Fake data only: fake names, @test.local emails, a fake Aadhaar-like number, a fake key.
--
-- ROLLBACK : nothing to undo; the script ends with ROLLBACK.
--
-- WHAT THE FAKE DATA LOOKS LIKE (all money in paise; Rs 500 = 50000)
--   People : T-MAIN main admin | T-SUB sub admin, all 7 permissions | T-SUBR sub admin, report_view only
--            T-SUBI sub admin, all 7 permissions but INACTIVE | T-W1, T-W2 workers
--            T-WI inactive worker | T-WR revoked worker
--   Sites  : A (rate Rs 1000 per visit), B
--   Work   : WE1 A, W1 (+W2), 05 Oct, expense 50000   -> VERIFIED   (the "Rs 500 verified expense")
--            WE2 A, W2 (+W1), 05 Oct, expense 30000   -> VERIFIED   (same site, same day: one visit)
--            WE3 B, W1,       06 Oct, expense 20000   -> PENDING
--            WE4 A, W1,       07 Oct, expense 70000   -> REJECTED
--            WE5 A, W2,       08 Oct, expense 10000   -> CHANGES REQUESTED
--            WE6 A, W2,       09 Oct, expense 90000   -> VERIFIED then CANCELLED
--   Income : I1 A 500000 received 500000 | I2 A 300000 received 100000 | I3 B 400000 received 0
--            I4 A 999900 received 0 -> CANCELLED
--   Salary : W1 Sep 2026 amount 400000 paid 400000 (credited 01 Oct) | W2 Sep 2026 amount 300000 paid 100000 (02 Oct)
--   Report window: 2026-10-01 to 2026-10-31
--   Expected official numbers: verified expenses 80000, pending expenses 20000, received income 600000,
--     pending income 600000, paid salary 500000, pending salary 200000, operating balance 520000,
--     after-salary balance 20000, verified work entries 2, unique workers (site A) 2, visits (site A) 1.

begin;

-- 0. Safety guard -----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from public.employees) then
    raise exception 'STOP: public.employees is not empty. Run this file only on an empty dev/test database (migrations 001-026 applied, no seed rows).';
  end if;
end $$;

-- 1. Helpers (temporary: they vanish with the session) --------------------------------------------
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

-- 2. Fake users and permissions -------------------------------------------------------------------
do $$
begin
  insert into auth.users (id, email) values
    ('a0000000-0000-0000-0000-000000000001', 'main@test.local'),
    ('a0000000-0000-0000-0000-000000000002', 'sub@test.local'),
    ('a0000000-0000-0000-0000-000000000003', 'subr@test.local'),
    ('a0000000-0000-0000-0000-000000000004', 'subi@test.local'),
    ('a0000000-0000-0000-0000-000000000005', 'w1@test.local'),
    ('a0000000-0000-0000-0000-000000000006', 'w2@test.local'),
    ('a0000000-0000-0000-0000-000000000007', 'wi@test.local'),
    ('a0000000-0000-0000-0000-000000000008', 'wr@test.local'),
    ('a0000000-0000-0000-0000-000000000099', 'extra@test.local');

  insert into public.employees (auth_user_id, employee_id, name, login_email, role, designation)
  values ('a0000000-0000-0000-0000-000000000001', 'T-MAIN', 'Test Main Admin', 'main@test.local', 'main_admin', 'Director');

  insert into public.employees (auth_user_id, employee_id, name, login_email, role, designation) values
    ('a0000000-0000-0000-0000-000000000002', 'T-SUB',  'Test Sub Admin',        'sub@test.local',  'sub_admin', 'Manager'),
    ('a0000000-0000-0000-0000-000000000003', 'T-SUBR', 'Test Sub Reports',      'subr@test.local', 'sub_admin', 'Analyst'),
    ('a0000000-0000-0000-0000-000000000004', 'T-SUBI', 'Test Sub Inactive',     'subi@test.local', 'sub_admin', 'Manager'),
    ('a0000000-0000-0000-0000-000000000005', 'T-W1',   'Test Worker One',       'w1@test.local',   'worker',    'Surveyor'),
    ('a0000000-0000-0000-0000-000000000006', 'T-W2',   'Test Worker Two',       'w2@test.local',   'worker',    'Assistant'),
    ('a0000000-0000-0000-0000-000000000007', 'T-WI',   'Test Worker Inactive',  'wi@test.local',   'worker',    'Surveyor'),
    ('a0000000-0000-0000-0000-000000000008', 'T-WR',   'Test Worker Revoked',   'wr@test.local',   'worker',    'Surveyor');

  insert into public.sub_admin_permissions (employee_id, permission)
  select pg_temp.eid(c), p
  from (values ('T-SUB'), ('T-SUBI')) as e(c),
       unnest(array['employee_management','site_management','verification','income_management',
                    'salary_management','report_view','export']) as p;
  insert into public.sub_admin_permissions (employee_id, permission) values (pg_temp.eid('T-SUBR'), 'report_view');

  update public.employees set account_status = 'inactive' where employee_id in ('T-SUBI', 'T-WI');
  update public.employees set account_status = 'revoked'  where employee_id = 'T-WR';
end $$;

-- 3. Fake business data (built only through the real functions) -----------------------------------
do $$
declare
  m uuid := pg_temp.aid('T-MAIN');
  s uuid := pg_temp.aid('T-SUB');
  v_id uuid;
begin
  perform pg_temp.put('siteA', (public.create_site(s, 'Test Site A', 'Test Client A', 'Test Location A', date '2026-10-01', 100000) -> 'site' ->> 'id')::uuid);
  perform pg_temp.put('siteB', (public.create_site(s, 'Test Site B', 'Test Client B', 'Test Location B', date '2026-10-01', 150000) -> 'site' ->> 'id')::uuid);

  -- work entries + expenses
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

  -- income
  perform pg_temp.put('i1', (public.create_income(s, pg_temp.g('siteA'), date '2026-10-10', 500000, 'First bill',  500000) -> 'income' ->> 'id')::uuid);
  perform pg_temp.put('i2', (public.create_income(s, pg_temp.g('siteA'), date '2026-10-12', 300000, 'Second bill', 100000) -> 'income' ->> 'id')::uuid);
  perform pg_temp.put('i3', (public.create_income(s, pg_temp.g('siteB'), date '2026-10-14', 400000, 'Third bill',       0) -> 'income' ->> 'id')::uuid);
  perform pg_temp.put('i4', (public.create_income(s, pg_temp.g('siteA'), date '2026-10-15', 999900, 'Wrong entry',      0) -> 'income' ->> 'id')::uuid);
  perform public.cancel_income(s, pg_temp.g('i4'), null, 'Duplicate entry');

  -- salary
  perform pg_temp.put('sal1', (public.create_salary(s, pg_temp.eid('T-W1'), date '2026-09-01', date '2026-09-30', 400000, 400000, date '2026-10-01') -> 'salary' ->> 'id')::uuid);
  perform pg_temp.put('sal2', (public.create_salary(s, pg_temp.eid('T-W2'), date '2026-09-01', date '2026-09-30', 300000, 100000, date '2026-10-02') -> 'salary' ->> 'id')::uuid);

  -- client bill for site A (1 visit x Rs 1000)
  perform public.generate_client_bill(m, pg_temp.g('siteA'), date '2026-10-01', date '2026-10-31', 'Survey work Oct 2026');
end $$;

-- =====================================================================================
-- PART A. FINANCIAL CONSISTENCY
-- =====================================================================================
do $$
declare
  m     uuid := pg_temp.aid('T-MAIN');
  f     date := date '2026-10-01';
  t     date := date '2026-10-31';
  a     uuid := pg_temp.g('siteA');
  b     uuid := pg_temp.g('siteB');
  w1    uuid := pg_temp.eid('T-W1');
  r     jsonb;
  v_row jsonb;
begin
  -- A1. the records themselves follow the work entry status
  perform pg_temp.chk('A1 expense of WE1 is verified, 50000',
    exists (select 1 from public.expenses where work_entry_id = pg_temp.g('we1') and verification_status = 'verified' and amount = 50000));
  perform pg_temp.chk('A1 expense of WE3 is pending_verification',
    exists (select 1 from public.expenses where work_entry_id = pg_temp.g('we3') and verification_status = 'pending_verification'));
  perform pg_temp.chk('A1 expense of WE4 is rejected',
    exists (select 1 from public.expenses where work_entry_id = pg_temp.g('we4') and verification_status = 'rejected'));
  perform pg_temp.chk('A1 expense of WE5 is changes_requested',
    exists (select 1 from public.expenses where work_entry_id = pg_temp.g('we5') and verification_status = 'changes_requested'));
  perform pg_temp.chk('A1 expense of WE6 is cancelled',
    exists (select 1 from public.expenses where work_entry_id = pg_temp.g('we6') and verification_status = 'cancelled'));

  -- A2. employee expense report: the Rs 500 verified expense of W1
  r := public.report_employee_expense(m, w1, f, t);
  perform pg_temp.chk_eq('A2 employee expense report: W1 verified = 50000', (r -> 'summary' ->> 'total_expense')::bigint, 50000);
  perform pg_temp.chk_eq('A2 employee expense report: W1 pending = 20000 (WE3)', (r -> 'summary' ->> 'pending_expense')::bigint, 20000);

  -- A3. site expense reports
  r := public.report_overall_site_expense(m, f, t);
  perform pg_temp.chk_eq('A3 overall site expense: verified total = 80000', (r -> 'summary' ->> 'total_expense_amount')::bigint, 80000);
  perform pg_temp.chk_eq('A3 overall site expense: pending total = 20000', (r -> 'summary' ->> 'pending_expense_amount')::bigint, 20000);
  r := public.report_individual_site_expense(m, f, t, a);
  perform pg_temp.chk_eq('A3 site A expense: verified = 80000', (r -> 'summary' ->> 'total_expense')::bigint, 80000);
  perform pg_temp.chk_eq('A3 site A expense: pending = 0',     (r -> 'summary' ->> 'pending_expense')::bigint, 0);
  r := public.report_individual_site_expense(m, f, t, b);
  perform pg_temp.chk_eq('A3 site B expense: verified = 0',     (r -> 'summary' ->> 'total_expense')::bigint, 0);
  perform pg_temp.chk_eq('A3 site B expense: pending = 20000',  (r -> 'summary' ->> 'pending_expense')::bigint, 20000);

  -- A4. site invoice (work report)
  r := public.report_site_invoice(m, f, t, a);
  perform pg_temp.chk_eq('A4 site invoice A: verified expenses = 80000', (r -> 'summary' ->> 'verified_expenses')::bigint, 80000);
  perform pg_temp.chk_eq('A4 site invoice A: total work entries = 2',    (r -> 'summary' ->> 'total_work_entries')::bigint, 2);
  perform pg_temp.chk_eq('A4 site invoice A: unique workers = 2',        (r -> 'summary' ->> 'unique_workers')::bigint, 2);
  perform pg_temp.chk_eq('A4 site invoice A: visits = 1 (two entries, same day)', (r -> 'summary' ->> 'visit_count')::bigint, 1);
  perform pg_temp.chk_eq('A4 site invoice A: pending work entries = 0',  (r -> 'summary' ->> 'pending_work_entries')::bigint, 0);
  r := public.report_site_invoice(m, f, t, b);
  perform pg_temp.chk_eq('A4 site invoice B: pending work entries = 1',  (r -> 'summary' ->> 'pending_work_entries')::bigint, 1);
  perform pg_temp.chk_eq('A4 site invoice B: verified work entries = 0', (r -> 'summary' ->> 'total_work_entries')::bigint, 0);

  -- A5. client bill amount = visits x rate (1 x 100000)
  perform pg_temp.chk_eq('A5 client bill for site A = 100000',
    (select amount from public.client_bills where site_id = a), 100000);

  -- A6. employee salary + expense summary
  r := public.report_employee_salary_expense(m, f, t);
  perform pg_temp.chk_eq('A6 salary+expense: paid salary = 500000',     (r -> 'summary' ->> 'paid_salary')::bigint, 500000);
  perform pg_temp.chk_eq('A6 salary+expense: pending salary = 200000',  (r -> 'summary' ->> 'pending_salary')::bigint, 200000);
  perform pg_temp.chk_eq('A6 salary+expense: verified expenses = 80000',(r -> 'summary' ->> 'verified_expenses')::bigint, 80000);
  perform pg_temp.chk_eq('A6 salary+expense: pending expenses = 20000', (r -> 'summary' ->> 'pending_expenses')::bigint, 20000);
  select x into v_row from jsonb_array_elements(r -> 'rows') x where x ->> 'employee_id' = 'T-W1';
  perform pg_temp.chk_eq('A6 salary+expense: W1 row expense = 50000 (the Rs 500)', (v_row ->> 'total_expense')::bigint, 50000);
  perform pg_temp.chk_eq('A6 salary+expense: W1 row salary paid = 400000',        (v_row ->> 'salary_paid')::bigint, 400000);

  -- A7. Site Net Balance report
  r := public.report_site_net_balance(m, f, t);
  perform pg_temp.chk_eq('A7 net balance: expense = 80000',              (r -> 'summary' ->> 'total_expense')::bigint, 80000);
  perform pg_temp.chk_eq('A7 net balance: operating balance = 520000',   (r -> 'summary' ->> 'operating_balance')::bigint, 520000);
  perform pg_temp.chk_eq('A7 net balance: after-salary balance = 20000', (r -> 'summary' ->> 'after_salary_balance')::bigint, 20000);
  perform pg_temp.chk_eq('A7 net balance: pending income = 600000',      (r -> 'summary' ->> 'pending_income')::bigint, 600000);
  perform pg_temp.chk_eq('A7 net balance: pending expense = 20000',      (r -> 'summary' ->> 'pending_expense')::bigint, 20000);
  perform pg_temp.chk_eq('A7 net balance, site A only: operating = 520000',
    (public.report_site_net_balance(m, f, t, a) -> 'summary' ->> 'operating_balance')::bigint, 520000);
  perform pg_temp.chk_eq('A7 net balance, site B only: operating = 0',
    (public.report_site_net_balance(m, f, t, b) -> 'summary' ->> 'operating_balance')::bigint, 0);

  -- A8. Overall Financial Summary
  r := public.report_overall_financial_summary(m, f, t);
  perform pg_temp.chk_eq('A8 overall summary: received income = 600000',  (r -> 'summary' -> 'income' ->> 'received_income')::bigint, 600000);
  perform pg_temp.chk_eq('A8 overall summary: pending income = 600000',   (r -> 'summary' -> 'income' ->> 'pending_income')::bigint, 600000);
  perform pg_temp.chk_eq('A8 overall summary: site expenses = 80000',     (r -> 'summary' -> 'expenses' ->> 'total_site_expenses')::bigint, 80000);
  perform pg_temp.chk_eq('A8 overall summary: pending expenses = 20000',  (r -> 'summary' -> 'expenses' ->> 'pending_expenses')::bigint, 20000);
  perform pg_temp.chk_eq('A8 overall summary: paid salary = 500000',      (r -> 'summary' -> 'salary' ->> 'paid_salary')::bigint, 500000);
  perform pg_temp.chk_eq('A8 overall summary: pending salary = 200000',   (r -> 'summary' -> 'salary' ->> 'pending_salary')::bigint, 200000);
  perform pg_temp.chk_eq('A8 overall summary: operating balance = 520000',(r -> 'summary' -> 'overall' ->> 'operating_balance')::bigint, 520000);
  perform pg_temp.chk_eq('A8 overall summary: after-salary = 20000',      (r -> 'summary' -> 'overall' ->> 'after_salary_balance')::bigint, 20000);

  -- A9. Admin dashboard
  r := public.get_admin_dashboard(m, f, t);
  perform pg_temp.chk_eq('A9 dashboard: verified expenses = 80000',  (r -> 'expenses' ->> 'verified_expenses')::bigint, 80000);
  perform pg_temp.chk_eq('A9 dashboard: pending expenses = 20000',   (r -> 'expenses' ->> 'pending_expenses')::bigint, 20000);
  perform pg_temp.chk_eq('A9 dashboard: received income = 600000',   (r -> 'income' ->> 'received_income')::bigint, 600000);
  perform pg_temp.chk_eq('A9 dashboard: pending income = 600000',    (r -> 'income' ->> 'pending_income')::bigint, 600000);
  perform pg_temp.chk_eq('A9 dashboard: paid salary = 500000',       (r -> 'salary' ->> 'paid_salary')::bigint, 500000);
  perform pg_temp.chk_eq('A9 dashboard: pending salary = 200000',    (r -> 'salary' ->> 'pending_salary')::bigint, 200000);
  perform pg_temp.chk_eq('A9 dashboard: pending verification count = 1', (r -> 'counts' ->> 'pending_verification')::bigint, 1);
  perform pg_temp.chk_eq('A9 dashboard: active sites = 2',           (r -> 'counts' ->> 'active_sites')::bigint, 2);
  perform pg_temp.chk_eq('A9 dashboard: active employees = 5',       (r -> 'counts' ->> 'active_employees')::bigint, 5);

  -- A10. the SAME net balance everywhere (report, summary report, dashboard, formula)
  perform pg_temp.chk('A10 operating balance identical in net-balance report, overall summary, dashboard and fin_summary',
    (public.report_site_net_balance(m, f, t) -> 'summary' ->> 'operating_balance')
      = (public.report_overall_financial_summary(m, f, t) -> 'summary' -> 'overall' ->> 'operating_balance')
    and (public.report_overall_financial_summary(m, f, t) -> 'summary' -> 'overall' ->> 'operating_balance')
      = (public.get_admin_dashboard(m, f, t) -> 'balances' ->> 'operating_balance')
    and (public.get_admin_dashboard(m, f, t) -> 'balances' ->> 'operating_balance')
      = (public.fin_summary(null, null, f, t) ->> 'operating_balance'));
  perform pg_temp.chk('A10 after-salary balance identical in net-balance report, overall summary, dashboard and fin_summary',
    (public.report_site_net_balance(m, f, t) -> 'summary' ->> 'after_salary_balance')
      = (public.report_overall_financial_summary(m, f, t) -> 'summary' -> 'overall' ->> 'after_salary_balance')
    and (public.report_overall_financial_summary(m, f, t) -> 'summary' -> 'overall' ->> 'after_salary_balance')
      = (public.get_admin_dashboard(m, f, t) -> 'balances' ->> 'after_salary_balance')
    and (public.get_admin_dashboard(m, f, t) -> 'balances' ->> 'after_salary_balance')
      = (public.fin_summary(null, null, f, t) ->> 'after_salary_balance'));
  perform pg_temp.chk_eq('A10 per-site operating balances add up to the overall balance',
    (public.fin_operating_balance(a, f, t) + public.fin_operating_balance(b, f, t)), 520000);

  -- A11. only VERIFIED is official; pending is separate; rejected / cancelled / changes_requested are in neither
  perform pg_temp.chk_eq('A11 official expenses exclude pending 20000, rejected 70000, changes_requested 10000, cancelled 90000',
    public.fin_verified_expenses(null, null, f, t), 80000);
  perform pg_temp.chk_eq('A11 pending expenses count only pending_verification (20000)',
    public.fin_pending_expenses(null, null, f, t), 20000);
  perform pg_temp.chk_eq('A11 cancelled income (999900) is excluded: received income = 600000',
    public.fin_received_income(null, f, t), 600000);
  perform pg_temp.chk_eq('A11 pending income = unreceived part of I2 (200000) + I3 (400000)',
    public.fin_pending_income(null, f, t), 600000);
  perform pg_temp.chk_eq('A11 verified work entries = 2 (WE3 pending, WE4 rejected, WE5 changes, WE6 cancelled excluded)',
    public.fin_work_entry_count(null, null, f, t), 2);
  perform pg_temp.chk_eq('A11 visit count = 1 (site A, 05 Oct)', public.fin_visit_count(null, f, t), 1);
  perform pg_temp.chk_eq('A11 unique workers = 2', public.fin_unique_worker_count(null, f, t), 2);
end $$;

-- =====================================================================================
-- PART B. PERMISSIONS
-- =====================================================================================
do $$
declare
  v_admin text[] := array[
    $q$create_site ## select public.create_site(%1$L::uuid, 'X Site', 'X Client', 'X Location')$q$,
    $q$list_sites ## select public.list_sites(%1$L::uuid)$q$,
    $q$approve_work_entry ## select public.approve_work_entry(%1$L::uuid, %3$L::uuid)$q$,
    $q$reject_work_entry ## select public.reject_work_entry(%1$L::uuid, %3$L::uuid, 'not allowed here')$q$,
    $q$cancel_work_entry ## select public.cancel_work_entry(%1$L::uuid, %3$L::uuid, 'not allowed here')$q$,
    $q$list_work_entries_admin ## select public.list_work_entries_admin(%1$L::uuid)$q$,
    $q$create_income ## select public.create_income(%1$L::uuid, %2$L::uuid, date '2026-10-20', 1000, 'x')$q$,
    $q$list_income ## select public.list_income(%1$L::uuid)$q$,
    $q$create_salary ## select public.create_salary(%1$L::uuid, %4$L::uuid, date '2026-08-01', date '2026-08-31', 1000)$q$,
    $q$list_salary ## select public.list_salary(%1$L::uuid)$q$,
    $q$list_employees ## select public.list_employees(%1$L::uuid)$q$,
    $q$get_app_settings ## select public.get_app_settings(%1$L::uuid)$q$,
    $q$update_app_settings ## select public.update_app_settings(%1$L::uuid, '{}'::jsonb)$q$,
    $q$generate_client_bill ## select public.generate_client_bill(%1$L::uuid, %2$L::uuid, date '2026-10-01', date '2026-10-31', 'x')$q$,
    $q$report_overall_financial_summary ## select public.report_overall_financial_summary(%1$L::uuid, date '2026-10-01', date '2026-10-31')$q$,
    $q$get_admin_dashboard ## select public.get_admin_dashboard(%1$L::uuid)$q$,
    $q$list_audit_logs ## select public.list_audit_logs(%1$L::uuid)$q$,
    $q$reveal_aadhaar ## select public.reveal_aadhaar(%1$L::uuid, %4$L::uuid, 'permission test', 'test-only-key-0123456789abcdef0123456789')$q$,
    $q$transfer_main_admin ## select public.transfer_main_admin(%1$L::uuid, %4$L::uuid, 'permission test')$q$
  ];
  v_worker text[] := array[
    $q$submit_work_entry ## select public.submit_work_entry(%1$L::uuid, %2$L::uuid, date '2026-10-21', time '10:00')$q$,
    $q$list_my_work ## select public.list_my_work(%1$L::uuid)$q$,
    $q$get_worker_dashboard ## select public.get_worker_dashboard(%1$L::uuid)$q$,
    $q$get_own_profile ## select public.get_own_profile(%1$L::uuid)$q$,
    $q$list_active_sites_for_worker ## select public.list_active_sites_for_worker(%1$L::uuid)$q$
  ];
  v_sub_denied text[] := array[   -- a sub_admin holding ONLY report_view
    $q$create_site (needs site_management) ## select public.create_site(%1$L::uuid, 'X Site', 'X Client', 'X Location')$q$,
    $q$approve_work_entry (needs verification) ## select public.approve_work_entry(%1$L::uuid, %3$L::uuid)$q$,
    $q$create_income (needs income_management) ## select public.create_income(%1$L::uuid, %2$L::uuid, date '2026-10-20', 1000, 'x')$q$,
    $q$create_salary (needs salary_management) ## select public.create_salary(%1$L::uuid, %4$L::uuid, date '2026-08-01', date '2026-08-31', 1000)$q$,
    $q$list_employees (needs employee_management) ## select public.list_employees(%1$L::uuid)$q$,
    $q$generate_client_bill (needs export) ## select public.generate_client_bill(%1$L::uuid, %2$L::uuid, date '2026-10-01', date '2026-10-31', 'x')$q$,
    $q$report export (needs export) ## select public.report_overall_financial_summary(%1$L::uuid, date '2026-10-01', date '2026-10-31', 1, 50, true)$q$,
    $q$update_app_settings (main admin only) ## select public.update_app_settings(%1$L::uuid, '{}'::jsonb)$q$,
    $q$list_audit_logs (main admin only) ## select public.list_audit_logs(%1$L::uuid)$q$,
    $q$reveal_aadhaar (main admin only) ## select public.reveal_aadhaar(%1$L::uuid, %4$L::uuid, 'permission test', 'test-only-key-0123456789abcdef0123456789')$q$,
    $q$transfer_main_admin (main admin only) ## select public.transfer_main_admin(%1$L::uuid, %4$L::uuid, 'permission test')$q$
  ];
  v_actor text;
  v_tpl   text;
  v_sql   text;
begin
  -- B1. workers cannot call any admin function
  foreach v_actor in array array['T-W1', 'T-W2'] loop
    foreach v_tpl in array v_admin loop
      perform pg_temp.expect_err(
        format('B1 worker %s denied: %s', v_actor, split_part(v_tpl, ' ## ', 1)),
        format(split_part(v_tpl, ' ## ', 2), pg_temp.aid(v_actor), pg_temp.g('siteA'), pg_temp.g('we3'), pg_temp.eid('T-W1')),
        'MORAYA_FORBIDDEN');
    end loop;
  end loop;

  -- B2. a sub_admin without the matching permission is refused (T-SUBR has report_view only)
  foreach v_tpl in array v_sub_denied loop
    perform pg_temp.expect_err(
      format('B2 sub_admin without permission denied: %s', split_part(v_tpl, ' ## ', 1)),
      format(split_part(v_tpl, ' ## ', 2), pg_temp.aid('T-SUBR'), pg_temp.g('siteA'), pg_temp.g('we3'), pg_temp.eid('T-W1')),
      'MORAYA_FORBIDDEN');
  end loop;
  -- positive control: the one permission it does have works
  begin
    perform public.report_overall_financial_summary(pg_temp.aid('T-SUBR'), date '2026-10-01', date '2026-10-31');
    perform pg_temp.chk('B2 positive control: report_view sub_admin CAN read the financial summary', true);
  exception when others then
    perform pg_temp.chk('B2 positive control: report_view sub_admin CAN read the financial summary', false, sqlerrm);
  end;

  -- B3. inactive and revoked users are refused everywhere (workers, and an inactive sub_admin who still has all permissions)
  foreach v_actor in array array['T-WI', 'T-WR', 'T-SUBI'] loop
    foreach v_tpl in array v_worker || v_admin loop
      perform pg_temp.expect_err(
        format('B3 %s (%s) denied: %s', v_actor,
               (select account_status::text from public.employees where employee_id = v_actor), split_part(v_tpl, ' ## ', 1)),
        format(split_part(v_tpl, ' ## ', 2), pg_temp.aid(v_actor), pg_temp.g('siteA'), pg_temp.g('we3'), pg_temp.eid('T-W1')),
        'MORAYA_FORBIDDEN');
    end loop;
  end loop;

  -- B4. an unknown account is refused
  foreach v_tpl in array v_worker loop
    perform pg_temp.expect_err(
      format('B4 unknown account denied: %s', split_part(v_tpl, ' ## ', 1)),
      format(split_part(v_tpl, ' ## ', 2), '00000000-0000-0000-0000-0000000000ff', pg_temp.g('siteA'), pg_temp.g('we3'), pg_temp.eid('T-W1')),
      'MORAYA_FORBIDDEN');
  end loop;

  -- B5. a worker cannot read salary while the setting is off (default)
  perform pg_temp.expect_err('B5 get_my_salary refused while workers_can_see_salary is false',
    format('select public.get_my_salary(%L::uuid)', pg_temp.aid('T-W1')), 'MORAYA_FORBIDDEN');

  -- B6. the database roles used by the browser cannot execute our functions
  perform pg_temp.chk('B6 anon and authenticated have no EXECUTE on any public function we wrote',
    not exists (
      select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      join pg_roles r on r.rolname in ('anon', 'authenticated')
      where n.nspname = 'public' and p.prokind in ('f', 'p')
        and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
        and has_function_privilege(r.oid, p.oid, 'EXECUTE')));
end $$;

-- =====================================================================================
-- PART C. STATE MACHINE (every illegal move raises MORAYA_INVALID_STATE)
-- =====================================================================================
do $$
declare
  s     uuid := pg_temp.aid('T-SUB');
  w1a   uuid := pg_temp.aid('T-W1');
  w2a   uuid := pg_temp.aid('T-W2');
  sm1   uuid; sm2 uuid; sm3 uuid; sm4 uuid;
  v_act text;
  v_sql text;
  v_st  text;
  v_ver integer;
begin
  -- helper: run an action on an entry as the reviewer and expect MORAYA_INVALID_STATE
  -- (a valid reason is always supplied so the state check is what fails)
  --  actions: approve | changes | reject | cancel | resubmit

  -- C1. verified -> approve / request changes / reject / resubmit are illegal; cancel is legal; then cancelled is final
  sm1 := pg_temp.submit('T-W1', 'siteA', date '2026-10-13', time '10:00', 'T-W2', 11000);
  perform public.approve_work_entry(s, sm1);
  perform pg_temp.chk('C1 pending -> approve gives verified',
    (select verification_status::text from public.work_entries where id = sm1) = 'verified');
  perform pg_temp.expect_err('C1 verified -> approve is illegal',        format('select public.approve_work_entry(%L, %L)', s, sm1), 'MORAYA_INVALID_STATE');
  perform pg_temp.expect_err('C1 verified -> request changes is illegal',format('select public.request_work_entry_changes(%L, %L, %L)', s, sm1, 'valid reason here'), 'MORAYA_INVALID_STATE');
  perform pg_temp.expect_err('C1 verified -> reject is illegal',         format('select public.reject_work_entry(%L, %L, %L)', s, sm1, 'valid reason here'), 'MORAYA_INVALID_STATE');
  perform pg_temp.expect_err('C1 verified -> resubmit is illegal',
    format('select public.resubmit_work_entry(%L, %L, %L, date %L, time %L)', w1a, sm1, pg_temp.g('siteA'), '2026-10-13', '10:00'), 'MORAYA_INVALID_STATE');
  perform public.cancel_work_entry(s, sm1, 'cancelled for the test');
  perform pg_temp.chk('C1 verified -> cancel is legal',
    (select verification_status::text from public.work_entries where id = sm1) = 'cancelled');
  perform pg_temp.chk('C1 cancelling the entry cancelled its expense',
    (select verification_status::text from public.expenses where work_entry_id = sm1) = 'cancelled');
  perform pg_temp.expect_err('C1 cancelled -> approve is illegal',        format('select public.approve_work_entry(%L, %L)', s, sm1), 'MORAYA_INVALID_STATE');
  perform pg_temp.expect_err('C1 cancelled -> request changes is illegal',format('select public.request_work_entry_changes(%L, %L, %L)', s, sm1, 'valid reason here'), 'MORAYA_INVALID_STATE');
  perform pg_temp.expect_err('C1 cancelled -> reject is illegal',         format('select public.reject_work_entry(%L, %L, %L)', s, sm1, 'valid reason here'), 'MORAYA_INVALID_STATE');
  perform pg_temp.expect_err('C1 cancelled -> cancel is illegal',         format('select public.cancel_work_entry(%L, %L, %L)', s, sm1, 'valid reason here'), 'MORAYA_INVALID_STATE');
  perform pg_temp.expect_err('C1 cancelled -> resubmit is illegal',
    format('select public.resubmit_work_entry(%L, %L, %L, date %L, time %L)', w1a, sm1, pg_temp.g('siteA'), '2026-10-13', '10:00'), 'MORAYA_INVALID_STATE');

  -- C2. rejected is final
  sm2 := pg_temp.submit('T-W1', 'siteA', date '2026-10-14', time '10:00', 'T-W2', 12000);
  perform public.reject_work_entry(s, sm2, 'rejected for the test');
  perform pg_temp.chk('C2 pending -> reject gives rejected',
    (select verification_status::text from public.work_entries where id = sm2) = 'rejected');
  perform pg_temp.expect_err('C2 rejected -> approve is illegal',         format('select public.approve_work_entry(%L, %L)', s, sm2), 'MORAYA_INVALID_STATE');
  perform pg_temp.expect_err('C2 rejected -> request changes is illegal', format('select public.request_work_entry_changes(%L, %L, %L)', s, sm2, 'valid reason here'), 'MORAYA_INVALID_STATE');
  perform pg_temp.expect_err('C2 rejected -> reject is illegal',          format('select public.reject_work_entry(%L, %L, %L)', s, sm2, 'valid reason here'), 'MORAYA_INVALID_STATE');
  perform pg_temp.expect_err('C2 rejected -> cancel is illegal',          format('select public.cancel_work_entry(%L, %L, %L)', s, sm2, 'valid reason here'), 'MORAYA_INVALID_STATE');
  perform pg_temp.expect_err('C2 rejected -> resubmit is illegal',
    format('select public.resubmit_work_entry(%L, %L, %L, date %L, time %L)', w1a, sm2, pg_temp.g('siteA'), '2026-10-14', '10:00'), 'MORAYA_INVALID_STATE');

  -- C3. changes_requested: only the surveyor can resubmit; approve / reject / request changes are illegal
  sm3 := pg_temp.submit('T-W1', 'siteA', date '2026-10-15', time '10:00', 'T-W2', 13000);
  perform public.request_work_entry_changes(s, sm3, 'please correct the time');
  perform pg_temp.chk('C3 pending -> request changes gives changes_requested',
    (select verification_status::text from public.work_entries where id = sm3) = 'changes_requested');
  perform pg_temp.expect_err('C3 changes_requested -> approve is illegal',         format('select public.approve_work_entry(%L, %L)', s, sm3), 'MORAYA_INVALID_STATE');
  perform pg_temp.expect_err('C3 changes_requested -> reject is illegal',          format('select public.reject_work_entry(%L, %L, %L)', s, sm3, 'valid reason here'), 'MORAYA_INVALID_STATE');
  perform pg_temp.expect_err('C3 changes_requested -> request changes is illegal', format('select public.request_work_entry_changes(%L, %L, %L)', s, sm3, 'valid reason here'), 'MORAYA_INVALID_STATE');
  perform pg_temp.expect_err('C3 resubmit by the assistant is refused',
    format('select public.resubmit_work_entry(%L, %L, %L, date %L, time %L)', w2a, sm3, pg_temp.g('siteA'), '2026-10-15', '10:00'), 'MORAYA_FORBIDDEN');
  perform pg_temp.expect_err('C3 resubmit by the reviewer is refused',
    format('select public.resubmit_work_entry(%L, %L, %L, date %L, time %L)', s, sm3, pg_temp.g('siteA'), '2026-10-15', '10:00'), 'MORAYA_FORBIDDEN');
  perform public.resubmit_work_entry(w1a, sm3, pg_temp.g('siteA'), date '2026-10-15', time '10:30', pg_temp.eid('T-W2'), 13500, 'travel', 'corrected');
  select verification_status::text, version into v_st, v_ver from public.work_entries where id = sm3;
  perform pg_temp.chk('C3 resubmit by the surveyor: back to pending_verification, round 2', v_st = 'pending_verification' and v_ver = 2,
    'status ' || v_st || ', version ' || v_ver);
  perform pg_temp.chk_eq('C3 resubmit keeps the earlier round: history has more than one row for the entry',
    (select count(*) > 1 from public.work_entry_history where work_entry_id = sm3)::int, 1);
  perform pg_temp.expect_err('C3 pending (after resubmit) -> resubmit again is illegal',
    format('select public.resubmit_work_entry(%L, %L, %L, date %L, time %L)', w1a, sm3, pg_temp.g('siteA'), '2026-10-15', '10:30'), 'MORAYA_INVALID_STATE');

  -- C4. reasons and versions
  sm4 := pg_temp.submit('T-W1', 'siteA', date '2026-10-16', time '10:00', 'T-W2', 14000);
  perform pg_temp.expect_err('C4 reject without a reason is refused',
    format('select public.reject_work_entry(%L, %L, null)', s, sm4), 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('C4 reject with a blank reason is refused',
    format('select public.reject_work_entry(%L, %L, %L)', s, sm4, '   '), 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('C4 reject with a too-short reason is refused',
    format('select public.reject_work_entry(%L, %L, %L)', s, sm4, 'ab'), 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('C4 request changes without a reason is refused',
    format('select public.request_work_entry_changes(%L, %L, null)', s, sm4), 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('C4 cancel without a reason is refused',
    format('select public.cancel_work_entry(%L, %L, null)', s, sm4), 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('C4 approve with an outdated version is refused',
    format('select public.approve_work_entry(%L, %L, 99)', s, sm4), 'MORAYA_CONFLICT');
  perform pg_temp.chk('C4 refused calls left the entry pending',
    (select verification_status::text from public.work_entries where id = sm4) = 'pending_verification');
  perform pg_temp.expect_err('C4 a worker (no verification permission) cannot approve',
    format('select public.approve_work_entry(%L, %L)', w2a, sm4), 'MORAYA_FORBIDDEN');
  perform pg_temp.expect_err('C4 a sub_admin without verification cannot approve',
    format('select public.approve_work_entry(%L, %L)', pg_temp.aid('T-SUBR'), sm4), 'MORAYA_FORBIDDEN');
  perform pg_temp.expect_err('C4 unknown work entry gives MORAYA_NOT_FOUND',
    format('select public.approve_work_entry(%L, %L)', s, '00000000-0000-0000-0000-0000000000aa'), 'MORAYA_NOT_FOUND');

  -- C5. nobody reviews their own work (surveyor or assistant), not even with the verification permission or as main admin
  perform pg_temp.put('own1', pg_temp.submit('T-SUB',  'siteA', date '2026-10-17', time '10:00', 'T-W2', 15000));   -- S is the surveyor
  perform pg_temp.put('own2', pg_temp.submit('T-W1',   'siteA', date '2026-10-18', time '10:00', 'T-SUB', 16000));  -- S is the assistant
  perform pg_temp.put('own3', pg_temp.submit('T-MAIN', 'siteA', date '2026-10-19', time '10:00', null,   17000));   -- main admin is the surveyor
  perform pg_temp.expect_err('C5 reviewer cannot approve an entry they submitted',
    format('select public.approve_work_entry(%L, %L)', s, pg_temp.g('own1')), 'MORAYA_FORBIDDEN');
  perform pg_temp.expect_err('C5 reviewer cannot reject an entry they submitted',
    format('select public.reject_work_entry(%L, %L, %L)', s, pg_temp.g('own1'), 'valid reason here'), 'MORAYA_FORBIDDEN');
  perform pg_temp.expect_err('C5 reviewer cannot request changes on an entry they submitted',
    format('select public.request_work_entry_changes(%L, %L, %L)', s, pg_temp.g('own1'), 'valid reason here'), 'MORAYA_FORBIDDEN');
  perform pg_temp.expect_err('C5 reviewer cannot approve an entry where they are the assistant',
    format('select public.approve_work_entry(%L, %L)', s, pg_temp.g('own2')), 'MORAYA_FORBIDDEN');
  perform pg_temp.expect_err('C5 main admin cannot approve their own entry',
    format('select public.approve_work_entry(%L, %L)', pg_temp.aid('T-MAIN'), pg_temp.g('own3')), 'MORAYA_FORBIDDEN');
  perform pg_temp.chk('C5 all three entries are still pending',
    (select count(*) from public.work_entries where id in (pg_temp.g('own1'), pg_temp.g('own2'), pg_temp.g('own3'))
        and verification_status = 'pending_verification') = 3);
  begin
    perform public.approve_work_entry(pg_temp.aid('T-MAIN'), pg_temp.g('own1'));
    perform pg_temp.chk('C5 positive control: a different reviewer (main admin) CAN approve the sub admin''s entry', true);
  exception when others then
    perform pg_temp.chk('C5 positive control: a different reviewer (main admin) CAN approve the sub admin''s entry', false, sqlerrm);
  end;
end $$;

-- =====================================================================================
-- PART D. DATES (no future work; Asia/Kolkata and the midnight edge)
-- =====================================================================================
do $$
declare
  v_now   timestamp := clock_timestamp() at time zone 'Asia/Kolkata';
  v_today date := (clock_timestamp() at time zone 'Asia/Kolkata')::date;
  v_plus  timestamp := (clock_timestamp() at time zone 'Asia/Kolkata') + interval '5 minutes';
  v_minus timestamp := (clock_timestamp() at time zone 'Asia/Kolkata') - interval '5 minutes';
  w1      uuid := pg_temp.aid('T-W1');
  b       uuid := pg_temp.g('siteB');
  w1id    uuid := pg_temp.eid('T-W1');
begin
  -- D1. through the function
  perform pg_temp.expect_err('D1 future date (tomorrow, India time) is rejected by submit_work_entry',
    format('select public.submit_work_entry(%L, %L, %L::date, time %L)', w1, b, v_today + 1, '09:00'), 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('D1 far-future date is rejected by submit_work_entry',
    format('select public.submit_work_entry(%L, %L, %L::date, time %L)', w1, b, v_today + 400, '09:00'), 'MORAYA_VALIDATION');

  -- D2. the trigger on the table cannot be bypassed (direct inserts), including later TODAY
  perform pg_temp.expect_err('D2 direct insert for tomorrow 00:00 is rejected by the table trigger',
    format($q$insert into public.work_entries (site_id, surveyor_id, work_date, work_time, verification_status, submitted_at)
              values (%L, %L, %L::date, time '00:00', 'pending_verification', now())$q$, b, w1id, v_today + 1),
    'MORAYA_VALIDATION');
  perform pg_temp.expect_err('D2 direct insert for 5 minutes from now (India time) is rejected, also across midnight',
    format($q$insert into public.work_entries (site_id, surveyor_id, work_date, work_time, verification_status, submitted_at)
              values (%L, %L, %L::date, %L::time, 'pending_verification', now())$q$, b, w1id, v_plus::date, v_plus::time),
    'MORAYA_VALIDATION');

  -- D3. midnight edge: today 00:00 India time is the past. It must be accepted even while the UTC date is still yesterday
  --     (between 00:00 and 05:30 India time).
  begin
    perform pg_temp.put('mid1', pg_temp.submit('T-W1', 'siteB', v_today, time '00:00', null, null));
    perform pg_temp.chk('D3 today 00:00 (India time) is accepted', true);
  exception when others then
    perform pg_temp.chk('D3 today 00:00 (India time) is accepted', false, sqlerrm);
  end;
  begin
    perform pg_temp.put('mid2', pg_temp.submit('T-W1', 'siteA', v_minus::date, v_minus::time, null, null));
    perform pg_temp.chk('D3 5 minutes ago (India time, also when that is yesterday 23:5x) is accepted', true);
  exception when others then
    perform pg_temp.chk('D3 5 minutes ago (India time, also when that is yesterday 23:5x) is accepted', false, sqlerrm);
  end;

  -- D4. changing the date of an existing entry to the future is blocked by the same trigger
  perform pg_temp.expect_err('D4 updating an existing entry to a future date is rejected',
    format($q$update public.work_entries set work_date = %L::date where id = %L$q$, v_today + 1, pg_temp.g('mid1')),
    'MORAYA_VALIDATION');
  perform pg_temp.expect_err('D4 salary period starting in the future is refused',
    format('select public.create_salary(%L, %L, %L::date, %L::date, 1000)', pg_temp.aid('T-SUB'), pg_temp.eid('T-W2'), v_today + 1, v_today + 20),
    'MORAYA_VALIDATION');
end $$;

-- =====================================================================================
-- PART E. DATA RULES (Aadhaar, deletes, surveyor <> assistant, audit trail)
-- =====================================================================================
do $$
declare
  v_key    constant text := 'test-only-key-0123456789abcdef0123456789';
  v_aad    constant text := '234567890124';    -- fake, passes the Verhoeff check
  m        uuid := pg_temp.aid('T-MAIN');
  s        uuid := pg_temp.aid('T-SUB');
  w1       uuid := pg_temp.eid('T-W1');
  v_json   jsonb;
  t        text;
begin
  -- E1. input rules
  perform pg_temp.chk('E1 "A 2345 6789 0124" is normalised to 12 digits', public.aadhaar_normalize('A 2345 6789 0124') = v_aad);
  perform pg_temp.chk('E1 "2345-6789-0124" is normalised to 12 digits',   public.aadhaar_normalize('2345-6789-0124') = v_aad);
  perform pg_temp.expect_err('E1 11 digits is rejected',                  $q$select public.aadhaar_normalize('23456789012')$q$, 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('E1 13 digits is rejected',                  $q$select public.aadhaar_normalize('2345678901245')$q$, 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('E1 a letter inside the number is rejected', $q$select public.aadhaar_normalize('23456789A124')$q$, 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('E1 a number starting with 1 is rejected',   $q$select public.aadhaar_normalize('134567890124')$q$, 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('E1 a wrong check digit is rejected',        $q$select public.aadhaar_normalize('234567890125')$q$, 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('E1 an empty value is rejected',             $q$select public.aadhaar_normalize('')$q$, 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('E1 set_employee_aadhaar refuses an invalid number',
    format('select public.set_employee_aadhaar(%L, %L, %L)', w1, '234567890125', v_key), 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('E1 set_employee_aadhaar refuses a missing/short key',
    format('select public.set_employee_aadhaar(%L, %L, %L)', w1, v_aad, 'short'), 'MORAYA_INVALID_STATE');

  -- E2. masking
  perform pg_temp.chk('E2 mask_aadhaar shows only the last 4', public.mask_aadhaar(v_aad) = 'XXXX XXXX 0124');
  perform public.set_employee_aadhaar(w1, v_aad, v_key);
  perform pg_temp.chk('E2 stored last4 = 0124', (select aadhaar_last4 from public.employees where id = w1) = '0124');
  perform pg_temp.chk('E2 the stored ciphertext is not the number',
    (select encode(aadhaar_encrypted, 'escape') not like '%' || v_aad || '%' from public.employees where id = w1));
  foreach t in array array[
    public.get_employee(m, w1)::text,
    public.list_employees(m)::text,
    public.get_employee(s, w1)::text,
    public.get_own_profile(pg_temp.aid('T-W1'))::text,
    (select string_agg(to_jsonb(e)::text, ',') from public.employees_masked e)
  ] loop
    perform pg_temp.chk('E2 output never contains the full number (output ' || left(coalesce(t, 'null'), 30) || '...)',
      t is not null and t not like '%' || v_aad || '%');
  end loop;
  perform pg_temp.chk('E2 get_employee shows the masked form ending 0124',
    public.get_employee(m, w1)::text like '%0124%');
  perform pg_temp.chk('E2 the API role cannot select the encrypted Aadhaar or its hash columns',
    not has_column_privilege('service_role', 'public.employees', 'aadhaar_encrypted', 'select')
    and not has_column_privilege('service_role', 'public.employees', 'aadhaar_hash', 'select'));

  -- E3. reveal: main admin only, with a reason, audited, and the audit never holds the number
  perform pg_temp.expect_err('E3 sub_admin (all permissions) cannot reveal Aadhaar',
    format('select public.reveal_aadhaar(%L, %L, %L, %L)', s, w1, 'permission test', v_key), 'MORAYA_FORBIDDEN');
  perform pg_temp.expect_err('E3 worker cannot reveal Aadhaar',
    format('select public.reveal_aadhaar(%L, %L, %L, %L)', pg_temp.aid('T-W2'), w1, 'permission test', v_key), 'MORAYA_FORBIDDEN');
  perform pg_temp.expect_err('E3 reveal without a proper reason is refused',
    format('select public.reveal_aadhaar(%L, %L, %L, %L)', m, w1, 'x', v_key), 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('E3 reveal with a wrong key is refused',
    format('select public.reveal_aadhaar(%L, %L, %L, %L)', m, w1, 'permission test', 'wrong-key-wrong-key-wrong-key-wrong-key'), 'MORAYA_INVALID_STATE');
  perform pg_temp.chk_eq('E3 refused reveals wrote no AADHAAR_REVEALED audit row',
    (select count(*) from public.audit_logs where action = 'AADHAAR_REVEALED'), 0);
  v_json := public.reveal_aadhaar(m, w1, 'permission test reveal', v_key);
  perform pg_temp.chk('E3 main admin gets the full number', v_json ->> 'aadhaar' = v_aad);
  perform pg_temp.chk_eq('E3 the reveal is audited (AADHAAR_REVEALED)',
    (select count(*) from public.audit_logs where action = 'AADHAAR_REVEALED'), 1);
  perform pg_temp.chk('E3 no audit row anywhere contains the full number or the key',
    not exists (select 1 from public.audit_logs a
                where coalesce(a.old_value::text, '') || coalesce(a.new_value::text, '') || coalesce(a.summary, '') || coalesce(a.reason, '')
                      like any (array['%' || v_aad || '%', '%' || v_key || '%'])));

  -- E4. surveyor and assistant cannot be the same person
  perform pg_temp.expect_err('E4 direct insert with surveyor = assistant violates the table constraint',
    format($q$insert into public.work_entries (site_id, surveyor_id, assistant_id, work_date, work_time, verification_status, submitted_at)
              values (%L, %L, %L, date '2026-10-20', time '09:00', 'pending_verification', now())$q$, pg_temp.g('siteA'), w1, w1),
    null, '23514');
  perform pg_temp.expect_err('E4 submit_work_entry refuses the actor as their own assistant',
    format('select public.submit_work_entry(%L, %L, date %L, time %L, %L)', pg_temp.aid('T-W1'), pg_temp.g('siteA'), '2026-10-20', '09:00', w1),
    'MORAYA_VALIDATION');

  -- E5. an expense can only belong to the surveyor of its work entry
  perform pg_temp.expect_err('E5 an expense owned by someone other than the surveyor is refused',
    format($q$insert into public.expenses (work_entry_id, employee_id, site_id, expense_date, amount, category)
              values (%L, %L, %L, date '2026-10-06', 100, 'travel')$q$, pg_temp.g('we3'), pg_temp.eid('T-W2'), pg_temp.g('siteB')));
  perform pg_temp.expect_err('E5 expense amount 0 is refused',
    format($q$insert into public.expenses (work_entry_id, employee_id, site_id, expense_date, amount, category)
              values (%L, %L, %L, date '2026-10-06', 0, 'travel')$q$, pg_temp.g('we3'), w1, pg_temp.g('siteB')));
end $$;

-- E6/E7. financial rows and the audit trail cannot be deleted, truncated or edited
do $$
declare
  t       text;
  v_n     bigint;
  v_after bigint;
begin
  foreach t in array array['work_entries', 'expenses', 'income_transactions', 'salary_records', 'client_bills',
                           'work_entry_history', 'expense_history', 'salary_history', 'audit_logs'] loop
    execute format('select count(*) from public.%I', t) into v_n;
    perform pg_temp.chk(t || ': table has rows to protect', v_n > 0, 'rows: ' || v_n);
    perform pg_temp.expect_err('E6 DELETE on ' || t || ' is blocked', format('delete from public.%I', t));
    perform pg_temp.expect_err('E6 TRUNCATE on ' || t || ' is blocked', format('truncate public.%I', t));
    execute format('select count(*) from public.%I', t) into v_after;
    perform pg_temp.chk_eq('E6 ' || t || ' row count unchanged after the attempts', v_after, v_n);
    perform pg_temp.chk('E6 no DELETE privilege for anon, authenticated or service_role on ' || t,
      not exists (select 1 from pg_roles r
                  where r.rolname in ('anon', 'authenticated', 'service_role')
                    and has_table_privilege(r.rolname, 'public.' || t, 'DELETE')));
  end loop;

  perform pg_temp.expect_err('E7 audit_logs rows cannot be edited', $q$update public.audit_logs set summary = 'tampered'$q$);
  perform pg_temp.expect_err('E7 history rows cannot be edited',    $q$update public.work_entry_history set code = 'tampered'$q$);
  perform pg_temp.chk('E7 audit_logs has rows and a human-readable summary on the work entry approvals',
    exists (select 1 from public.audit_logs where action = 'WORK_APPROVED' and coalesce(summary, '') <> ''));
end $$;

-- =====================================================================================
-- PART F. MAIN ADMIN PROTECTION (kept last: the hand-over changes who the Main Admin is)
-- =====================================================================================
do $$
declare
  m      uuid := pg_temp.aid('T-MAIN');
  s      uuid := pg_temp.aid('T-SUB');
  mid    uuid := pg_temp.eid('T-MAIN');
  sid    uuid := pg_temp.eid('T-SUB');
  v_ok   boolean;
  v_json jsonb;
begin
  -- F1. exactly one main admin; the other ways in or out are closed
  perform pg_temp.expect_err('F1 a second main_admin cannot be inserted',
    $q$insert into public.employees (auth_user_id, employee_id, name, login_email, role)
       values ('a0000000-0000-0000-0000-000000000099', 'T-SECOND', 'Test Second', 'extra@test.local', 'main_admin')$q$,
    null, '23505');
  perform pg_temp.expect_err('F1 a worker cannot be promoted to main_admin by a plain update',
    format($q$update public.employees set role = 'main_admin' where id = %L$q$, pg_temp.eid('T-W1')),
    'The Main Admin role can only be changed through transfer_main_admin');
  perform pg_temp.expect_err('F1 the only main admin cannot be demoted',
    format($q$update public.employees set role = 'sub_admin' where id = %L$q$, mid), 'The Main Admin cannot be demoted, deactivated or revoked');
  perform pg_temp.expect_err('F1 the only main admin cannot be demoted to worker',
    format($q$update public.employees set role = 'worker' where id = %L$q$, mid), 'The Main Admin cannot be demoted, deactivated or revoked');
  perform pg_temp.expect_err('F1 the only main admin cannot be deactivated',
    format($q$update public.employees set account_status = 'inactive' where id = %L$q$, mid), 'The Main Admin cannot be demoted, deactivated or revoked');
  perform pg_temp.expect_err('F1 the only main admin cannot be revoked',
    format($q$update public.employees set account_status = 'revoked' where id = %L$q$, mid), 'The Main Admin cannot be demoted, deactivated or revoked');
  perform pg_temp.expect_err('F1 the only main admin cannot be deleted',
    format($q$delete from public.employees where id = %L$q$, mid), 'The Main Admin cannot be deleted');
  perform pg_temp.expect_err('F1 set_employee_status cannot deactivate the main admin (even as main admin)',
    format('select public.set_employee_status(%L, %L, %L, %L)', m, mid, 'inactive', 'test reason here'));
  perform pg_temp.chk_eq('F1 still exactly one main admin',
    (select count(*) from public.employees where role = 'main_admin'), 1);

  -- F2. hand-over: who may call it, and who may receive it
  perform pg_temp.expect_err('F2 a sub_admin cannot transfer the main admin role',
    format('select public.transfer_main_admin(%L, %L, %L)', s, sid, 'permission test'), 'MORAYA_FORBIDDEN');
  perform pg_temp.expect_err('F2 a worker cannot transfer the main admin role',
    format('select public.transfer_main_admin(%L, %L, %L)', pg_temp.aid('T-W1'), pg_temp.eid('T-W2'), 'permission test'), 'MORAYA_FORBIDDEN');
  perform pg_temp.expect_err('F2 transfer to oneself is refused',
    format('select public.transfer_main_admin(%L, %L, %L)', m, mid, 'valid reason here'), 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('F2 transfer without a reason is refused',
    format('select public.transfer_main_admin(%L, %L, %L)', m, sid, ''), 'MORAYA_VALIDATION');
  perform pg_temp.expect_err('F2 transfer to an inactive employee is refused',
    format('select public.transfer_main_admin(%L, %L, %L)', m, pg_temp.eid('T-WI'), 'valid reason here'), 'MORAYA_INVALID_STATE');
  perform pg_temp.expect_err('F2 transfer to a revoked employee is refused',
    format('select public.transfer_main_admin(%L, %L, %L)', m, pg_temp.eid('T-WR'), 'valid reason here'), 'MORAYA_INVALID_STATE');
  perform pg_temp.expect_err('F2 transfer to an unknown employee is refused',
    format('select public.transfer_main_admin(%L, %L, %L)', m, '00000000-0000-0000-0000-0000000000bb', 'valid reason here'), 'MORAYA_NOT_FOUND');
  perform pg_temp.chk_eq('F2 refused transfers changed nothing: still exactly one main admin',
    (select count(*) from public.employees where role = 'main_admin' and id = mid), 1);

  -- F3. the real hand-over: main admin -> T-SUB
  v_json := public.transfer_main_admin(m, sid, 'Handover test reason');
  perform pg_temp.chk_eq('F3 after the transfer exactly one main admin exists',
    (select count(*) from public.employees where role = 'main_admin'), 1);
  perform pg_temp.chk('F3 the new main admin is the chosen employee, active',
    exists (select 1 from public.employees where id = sid and role = 'main_admin' and account_status = 'active'));
  perform pg_temp.chk('F3 the old main admin is now an active sub_admin',
    exists (select 1 from public.employees where id = mid and role = 'sub_admin' and account_status = 'active'));
  perform pg_temp.chk_eq('F3 the new main admin carries no leftover sub_admin permission rows',
    (select count(*) from public.sub_admin_permissions where employee_id = sid), 0);
  perform pg_temp.chk_eq('F3 the old main admin starts with no permissions',
    (select count(*) from public.sub_admin_permissions where employee_id = mid), 0);
  perform pg_temp.chk_eq('F3 the transfer is audited (MAIN_ADMIN_TRANSFERRED)',
    (select count(*) from public.audit_logs where action = 'MAIN_ADMIN_TRANSFERRED'), 1);
  perform pg_temp.expect_err('F3 the old main admin can no longer transfer',
    format('select public.transfer_main_admin(%L, %L, %L)', m, pg_temp.eid('T-W1'), 'valid reason here'), 'MORAYA_FORBIDDEN');
  perform pg_temp.expect_err('F3 the old main admin can no longer read the audit log',
    format('select public.list_audit_logs(%L)', m), 'MORAYA_FORBIDDEN');
  begin
    perform public.list_audit_logs(s);
    perform pg_temp.chk('F3 the new main admin can read the audit log', true);
  exception when others then
    perform pg_temp.chk('F3 the new main admin can read the audit log', false, sqlerrm);
  end;
  perform pg_temp.expect_err('F3 the new main admin is protected as well (cannot be demoted)',
    format($q$update public.employees set role = 'worker' where id = %L$q$, sid), 'The Main Admin cannot be demoted, deactivated or revoked');

  -- F4. the deferred "exactly one active main admin" check passes at commit time
  begin
    set constraints all immediate;
    v_ok := true;
  exception when others then
    v_ok := false;
  end;
  perform pg_temp.chk('F4 deferred check: exactly one active main admin when the transaction ends', v_ok);
end $$;

-- =====================================================================================
-- RESULT
-- =====================================================================================
select n, case when passed then 'PASS' else 'FAIL' end as result, name, detail
from test_results
order by passed, n;      -- failures first

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