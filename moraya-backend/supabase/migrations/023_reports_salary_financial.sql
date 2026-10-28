-- 023_reports_salary_financial.sql
-- PURPOSE   : Reports 10-14 of Master Specification section 13:
--               report_individual_employee_salary   (13.10 Individual Employee Salary Invoice)
--               report_overall_salary               (13.11 Overall Salary Invoice)
--               report_employee_salary_expense      (13.12 Employee Salary + Expense Summary)
--               report_site_net_balance             (13.13 titled "Site Net Balance", LD 7)
--               report_overall_financial_summary    (13.14 Overall Financial Summary Invoice)
--             Each returns jsonb { meta, rows, summary }. Shared rules are in 021 (who may call,
--             dates, paging, export variant, no Aadhaar, read-only, pending shown separately).
-- DEPENDS ON: 008, 002, 014, 019 (salary_records), 020 (fin_* formulas), 021 (rpt_check_request),
--             022 (fin_income_breakdown, fin_expense_* counts).
-- ROLLBACK  : drop function public.report_overall_financial_summary(uuid, date, date, integer, integer, boolean);
--             drop function public.report_site_net_balance(uuid, date, date, uuid, text, integer, integer, boolean);
--             drop function public.report_employee_salary_expense(uuid, date, date, uuid, text, integer, integer, boolean);
--             drop function public.report_overall_salary(uuid, date, date, uuid, text, text, integer, integer, boolean);
--             drop function public.report_individual_employee_salary(uuid, uuid, date, date, text, integer, integer, boolean);
--             drop function public.rpt_salary_rows(date, date, uuid, text, text, integer, integer, boolean);
--             drop function public.rpt_check_salary_status(text);
--             drop function public.fin_employee_site_count(uuid, date, date);
--             drop function public.fin_salary_breakdown(uuid, text, date, date);
--
-- EXTENSIONS TO 020 (kept here so 020 and 022 stay as delivered; same rules, same fact views)
--   fin_salary_breakdown     = salary rows in range (date = COALESCE(credited_date, period_end), as in 020):
--                              total_salary (sum of amount), paid and pending money (= 020 formulas),
--                              and count / amount for each of pending, partially_paid, paid.
--   fin_employee_site_count  = COUNT(DISTINCT site) over VERIFIED work entries where the employee is the
--                              surveyor OR the assistant.
--
-- THE TWO BALANCES (the client must be able to tell them apart, spec 13.14)
--   Operating Site Balance = received income - verified expenses            (fin_operating_balance)
--   After Salary Balance   = operating balance - paid salary                (fin_after_salary_balance)
--   Site Net Balance (13.13) is the OPERATING balance per site. Salary has no site, so the
--   after-salary balance appears only in the summary, using COMPANY-WIDE paid salary for the dates.
--   Formal accounting profit is not claimed.
--
-- ASSUMPTIONS (please confirm)
--   C1. "Total Income" / "Site Income" in 13.13 and 13.14 = RECEIVED income (what is actually in hand);
--       the full billed amount and the pending part are shown beside it.
--   C2. Salary reports list every salary row whose date (see above) falls in the range. Status filter:
--       'all' (default), 'pending', 'partially_paid', 'paid'. "Total Salary" = full amount of those rows.
--   C3. 13.12: SALARY is shown as salary_total (amount), salary_paid and salary_pending. Number of work
--       entries and sites count VERIFIED entries where the employee is surveyor or assistant. Only
--       employees with some activity in the range are listed.
--   C4. 13.13 / 13.14 list only sites with some activity in the range (any verified or pending expense,
--       received or pending income, or verified work entry). Ordered by site name. Client filter is an
--       exact case-insensitive match; with a client filter the summary covers those sites only.
--   C5. 13.14 rows = verified expense by site (highest first); the summary also carries expense by
--       employee (top 200, highest first) and all totals.
--   C6. Salary reports never show anything but salary data: no Aadhaar, no login email.

-- =====================================================================================
-- 1. 020 extensions
-- =====================================================================================
create or replace function public.fin_salary_breakdown(
  p_employee uuid default null, p_designation text default null,
  p_from date default null, p_to date default null
) returns jsonb language sql stable set search_path = public, pg_temp as $$
  with t as (
    select s.status::text as status, count(*) as n,
           coalesce(sum(s.amount), 0) as amt,
           coalesce(sum(f.paid_amount), 0) as paid,
           coalesce(sum(f.pending_amount), 0) as pend
    from public.fin_salary_facts f
    join public.salary_records s on s.id = f.salary_id
    join public.employees e      on e.id = f.employee_id
    where (p_employee    is null or f.employee_id = p_employee)
      and (p_designation is null or lower(e.designation) = lower(btrim(p_designation)))
      and (p_from        is null or f.fact_date >= p_from)
      and (p_to          is null or f.fact_date <= p_to)
    group by s.status
  )
  select jsonb_build_object(
    'total_salary',   coalesce((select sum(amt)  from t), 0)::bigint,
    'paid_salary',    coalesce((select sum(paid) from t), 0)::bigint,
    'pending_salary', coalesce((select sum(pend) from t), 0)::bigint,
    'total_employees', (select count(distinct f.employee_id)
                          from public.fin_salary_facts f
                          join public.employees e on e.id = f.employee_id
                         where (p_employee    is null or f.employee_id = p_employee)
                           and (p_designation is null or lower(e.designation) = lower(btrim(p_designation)))
                           and (p_from        is null or f.fact_date >= p_from)
                           and (p_to          is null or f.fact_date <= p_to)),
    'pending', jsonb_build_object(
        'count',  coalesce((select n   from t where status = 'pending'), 0),
        'amount', coalesce((select amt from t where status = 'pending'), 0)::bigint),
    'partially_paid', jsonb_build_object(
        'count',   coalesce((select n    from t where status = 'partially_paid'), 0),
        'amount',  coalesce((select amt  from t where status = 'partially_paid'), 0)::bigint,
        'paid',    coalesce((select paid from t where status = 'partially_paid'), 0)::bigint,
        'pending', coalesce((select pend from t where status = 'partially_paid'), 0)::bigint),
    'paid', jsonb_build_object(
        'count',  coalesce((select n   from t where status = 'paid'), 0),
        'amount', coalesce((select amt from t where status = 'paid'), 0)::bigint)
  )
$$;

create or replace function public.fin_employee_site_count(
  p_employee uuid, p_from date default null, p_to date default null
) returns bigint language sql stable set search_path = public, pg_temp as $$
  select count(distinct f.site_id)::bigint
  from public.fin_work_facts f
  where (f.surveyor_id = p_employee or f.assistant_id = p_employee)
    and (p_from is null or f.fact_date >= p_from)
    and (p_to   is null or f.fact_date <= p_to)
$$;

create or replace function public.rpt_check_salary_status(p_status text) returns void
language plpgsql set search_path = public, pg_temp as $$
begin
  if p_status is not null and p_status not in ('all', 'pending', 'partially_paid', 'paid') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid status');
  end if;
end $$;

-- =====================================================================================
-- 2. Salary row source (internal)
-- =====================================================================================
create or replace function public.rpt_salary_rows(
  p_date_from   date,
  p_date_to     date,
  p_employee    uuid,
  p_designation text,
  p_status      text,
  p_page        integer,
  p_page_size   integer,
  p_for_export  boolean
) returns table (
  total         bigint,
  sr_no         bigint,
  salary_id     uuid,
  employee_id   uuid,
  employee_name text,
  emp_code      text,
  designation   text,
  period_start  date,
  period_end    date,
  amount        bigint,
  paid_amount   bigint,
  pending_amount bigint,
  credited_date date,
  status        text,
  remarks       text
)
language sql
stable
set search_path = public, pg_temp
as $$
  with params as (
    select greatest(1, coalesce(p_page, 1)) as pg,
           greatest(1, least(coalesce(p_page_size, 50),
                             case when coalesce(p_for_export, false) then 5000 else 200 end)) as sz
  ),
  base as (
    select s.id, s.employee_id, e.name as employee_name, e.employee_id as emp_code, e.designation,
           s.period_start, s.period_end, s.amount, f.paid_amount, f.pending_amount,
           s.credited_date, s.status::text as status, s.remarks, f.fact_date
    from public.fin_salary_facts f
    join public.salary_records s on s.id = f.salary_id
    join public.employees e      on e.id = s.employee_id
    where f.fact_date between p_date_from and p_date_to
      and (p_employee    is null or s.employee_id = p_employee)
      and (p_designation is null or lower(e.designation) = lower(btrim(p_designation)))
      and (coalesce(p_status, 'all') = 'all' or s.status::text = p_status)
  ),
  numbered as (
    select b.*, count(*) over () as total,
           row_number() over (order by b.fact_date, b.employee_name, b.period_start, b.id) as rn
    from base b
  )
  select n.total, n.rn, n.id, n.employee_id, n.employee_name, n.emp_code, n.designation,
         n.period_start, n.period_end, n.amount, n.paid_amount, n.pending_amount,
         n.credited_date, n.status, n.remarks
  from numbered n, params p
  where n.rn >  (p.pg - 1) * p.sz
    and n.rn <= (p.pg - 1) * p.sz + p.sz
  order by n.rn
$$;

-- =====================================================================================
-- 3. Report 10: Individual Employee Salary Invoice (13.10)
--    Header: EMPLOYEE NAME, EMPLOYEE ID, DESIGNATION.
--    Rows: SALARY PERIOD, SALARY AMOUNT, SALARY CREDITED DATE, STATUS, REMARKS (+ paid / pending).
-- =====================================================================================
create or replace function public.report_individual_employee_salary(
  p_actor_auth_id uuid,
  p_employee_id   uuid,
  p_date_from     date,
  p_date_to       date,
  p_status        text    default 'all',
  p_page          integer default 1,
  p_page_size     integer default 50,
  p_for_export    boolean default false
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_emp   public.employees;
  v_rows  jsonb;
  v_total bigint;
begin
  perform public.rpt_check_request(p_actor_auth_id, p_date_from, p_date_to, null,
                                   p_for_export, p_page, p_page_size);
  perform public.rpt_check_salary_status(p_status);
  if p_employee_id is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Employee is required');
  end if;
  select * into v_emp from public.employees e where e.id = p_employee_id;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Employee not found');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'sr_no', r.sr_no,
           'salary_period', jsonb_build_object('from', r.period_start, 'to', r.period_end),
           'salary_amount', r.amount, 'paid_amount', r.paid_amount, 'pending_amount', r.pending_amount,
           'credited_date', r.credited_date, 'status', r.status, 'remarks', r.remarks)
           order by r.sr_no), '[]'::jsonb),
         coalesce(max(r.total), 0)
    into v_rows, v_total
  from public.rpt_salary_rows(p_date_from, p_date_to, p_employee_id, null, p_status,
                              p_page, p_page_size, p_for_export) r;

  return jsonb_build_object(
    'meta', jsonb_build_object(
      'report', 'individual_employee_salary', 'title', 'Individual Employee Salary Invoice',
      'date_from', p_date_from, 'date_to', p_date_to,
      'employee', jsonb_build_object('id', v_emp.id, 'employee_name', v_emp.name,
                                     'employee_id', v_emp.employee_id, 'designation', v_emp.designation),
      'row_status', coalesce(p_status, 'all'),
      'page', coalesce(p_page, 1), 'page_size', p_page_size, 'total_rows', v_total,
      'for_export', coalesce(p_for_export, false)),
    'rows', v_rows,
    'summary', public.fin_salary_breakdown(p_employee_id, null, p_date_from, p_date_to)
  );
end $$;

-- =====================================================================================
-- 4. Report 11: Overall Salary Invoice (13.11)
--    Rows: SR NO, EMPLOYEE NAME, EMPLOYEE ID, DESIGNATION, SALARY PERIOD, SALARY AMOUNT,
--          CREDITED DATE, STATUS.
--    Summary: Total Employees, Total Salary, Total Paid, Total Pending, Total Partially Paid.
-- =====================================================================================
create or replace function public.report_overall_salary(
  p_actor_auth_id uuid,
  p_date_from     date,
  p_date_to       date,
  p_employee_id   uuid    default null,
  p_designation   text    default null,
  p_status        text    default 'all',
  p_page          integer default 1,
  p_page_size     integer default 50,
  p_for_export    boolean default false
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_rows  jsonb;
  v_total bigint;
begin
  perform public.rpt_check_request(p_actor_auth_id, p_date_from, p_date_to, null,
                                   p_for_export, p_page, p_page_size);
  perform public.rpt_check_salary_status(p_status);

  select coalesce(jsonb_agg(jsonb_build_object(
           'sr_no', r.sr_no, 'employee_name', r.employee_name, 'employee_id', r.emp_code,
           'designation', r.designation,
           'salary_period', jsonb_build_object('from', r.period_start, 'to', r.period_end),
           'salary_amount', r.amount, 'paid_amount', r.paid_amount, 'pending_amount', r.pending_amount,
           'credited_date', r.credited_date, 'status', r.status)
           order by r.sr_no), '[]'::jsonb),
         coalesce(max(r.total), 0)
    into v_rows, v_total
  from public.rpt_salary_rows(p_date_from, p_date_to, p_employee_id, p_designation, p_status,
                              p_page, p_page_size, p_for_export) r;

  return jsonb_build_object(
    'meta', jsonb_build_object(
      'report', 'overall_salary', 'title', 'Overall Salary Invoice',
      'date_from', p_date_from, 'date_to', p_date_to,
      'filters', jsonb_build_object('employee_id', p_employee_id, 'designation', p_designation),
      'row_status', coalesce(p_status, 'all'),
      'page', coalesce(p_page, 1), 'page_size', p_page_size, 'total_rows', v_total,
      'for_export', coalesce(p_for_export, false)),
    'rows', v_rows,
    'summary', public.fin_salary_breakdown(p_employee_id, p_designation, p_date_from, p_date_to)
  );
end $$;

-- =====================================================================================
-- 5. Report 12: Employee Salary + Expense Summary (13.12)
--    Rows per employee: EMPLOYEE, EMPLOYEE ID, SALARY, TOTAL EXPENSE, NUMBER OF WORK ENTRIES,
--    NUMBER OF SITES (+ pending expense).
-- =====================================================================================
create or replace function public.report_employee_salary_expense(
  p_actor_auth_id uuid,
  p_date_from     date,
  p_date_to       date,
  p_employee_id   uuid    default null,
  p_designation   text    default null,
  p_page          integer default 1,
  p_page_size     integer default 50,
  p_for_export    boolean default false
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_rows  jsonb;
  v_total bigint;
  v_sum   jsonb;
  v_pg    integer := greatest(1, coalesce(p_page, 1));
  v_sz    integer;
begin
  perform public.rpt_check_request(p_actor_auth_id, p_date_from, p_date_to, null,
                                   p_for_export, p_page, p_page_size);
  v_sz := greatest(1, least(coalesce(p_page_size, 50), case when coalesce(p_for_export, false) then 5000 else 200 end));

  with per as (
    select e.id, e.name, e.employee_id as emp_code, e.designation,
           (public.fin_salary_breakdown(e.id, null, p_date_from, p_date_to) ->> 'total_salary')::bigint   as salary_total,
           public.fin_paid_salary(e.id, p_date_from, p_date_to)           as salary_paid,
           public.fin_pending_salary(e.id, p_date_from, p_date_to)        as salary_pending,
           public.fin_verified_expenses(null, e.id, p_date_from, p_date_to) as total_expense,
           public.fin_pending_expenses(null, e.id, p_date_from, p_date_to)  as pending_expense,
           public.fin_work_entry_count(null, e.id, p_date_from, p_date_to)  as work_entries,
           public.fin_employee_site_count(e.id, p_date_from, p_date_to)     as sites
    from public.employees e
    where (p_employee_id is null or e.id = p_employee_id)
      and (p_designation is null or lower(e.designation) = lower(btrim(p_designation)))
  ),
  act as (
    select * from per
    where salary_total > 0 or total_expense > 0 or pending_expense > 0 or work_entries > 0
  ),
  numbered as (
    select a.*, count(*) over () as total, row_number() over (order by a.name, a.id) as rn
    from act a
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'sr_no', n.rn, 'employee_name', n.name, 'employee_id', n.emp_code,
           'designation', n.designation,
           'salary_total', n.salary_total, 'salary_paid', n.salary_paid, 'salary_pending', n.salary_pending,
           'total_expense', n.total_expense, 'pending_expense', n.pending_expense,
           'number_of_work_entries', n.work_entries, 'number_of_sites', n.sites)
           order by n.rn) filter (where n.rn >  (v_pg - 1) * v_sz and n.rn <= v_pg * v_sz), '[]'::jsonb),
         coalesce(max(n.total), 0)
    into v_rows, v_total
  from numbered n;

  v_sum := jsonb_build_object(
    'total_employees',     v_total,
    'total_salary',        (public.fin_salary_breakdown(p_employee_id, p_designation, p_date_from, p_date_to) ->> 'total_salary')::bigint,
    'paid_salary',         public.fin_paid_salary(p_employee_id, p_date_from, p_date_to),
    'pending_salary',      public.fin_pending_salary(p_employee_id, p_date_from, p_date_to),
    'verified_expenses',   public.fin_verified_expenses(null, p_employee_id, p_date_from, p_date_to),
    'pending_expenses',    public.fin_pending_expenses(null, p_employee_id, p_date_from, p_date_to));

  return jsonb_build_object(
    'meta', jsonb_build_object(
      'report', 'employee_salary_expense', 'title', 'Employee Salary + Expense Summary',
      'date_from', p_date_from, 'date_to', p_date_to,
      'filters', jsonb_build_object('employee_id', p_employee_id, 'designation', p_designation),
      'page', v_pg, 'page_size', v_sz, 'total_rows', v_total,
      'for_export', coalesce(p_for_export, false)),
    'rows', v_rows,
    'summary', v_sum
  );
end $$;

-- =====================================================================================
-- 6. Report 13: Site Net Balance (spec 13.13; the title is "Site Net Balance", LD 7)
--    Rows: SITE, CLIENT, TOTAL INCOME (received), TOTAL EXPENSE (verified), NET BALANCE (operating),
--    plus pending income and pending expense. Summary: both balances.
-- =====================================================================================
create or replace function public.report_site_net_balance(
  p_actor_auth_id uuid,
  p_date_from     date,
  p_date_to       date,
  p_site_id       uuid    default null,
  p_client        text    default null,
  p_page          integer default 1,
  p_page_size     integer default 50,
  p_for_export    boolean default false
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_rows   jsonb;
  v_total  bigint;
  v_inc    bigint;
  v_exp    bigint;
  v_pinc   bigint;
  v_pexp   bigint;
  v_op     bigint;
  v_salary bigint;
  v_pg     integer := greatest(1, coalesce(p_page, 1));
  v_sz     integer;
begin
  perform public.rpt_check_request(p_actor_auth_id, p_date_from, p_date_to, null,
                                   p_for_export, p_page, p_page_size);
  v_sz := greatest(1, least(coalesce(p_page_size, 50), case when coalesce(p_for_export, false) then 5000 else 200 end));

  with per as (
    select s.id, s.site_name, s.site_location, s.client_name,
           public.fin_received_income(s.id, p_date_from, p_date_to)        as income,
           public.fin_pending_income(s.id, p_date_from, p_date_to)         as pending_income,
           public.fin_verified_expenses(s.id, null, p_date_from, p_date_to) as expense,
           public.fin_pending_expenses(s.id, null, p_date_from, p_date_to)  as pending_expense,
           public.fin_operating_balance(s.id, p_date_from, p_date_to)       as net_balance,
           public.fin_work_entry_count(s.id, null, p_date_from, p_date_to)  as work_entries
    from public.sites s
    where (p_site_id is null or s.id = p_site_id)
      and (p_client  is null or lower(s.client_name) = lower(btrim(p_client)))
  ),
  act as (
    select * from per
    where income > 0 or pending_income > 0 or expense > 0 or pending_expense > 0 or work_entries > 0
  ),
  numbered as (
    select a.*, count(*) over () as total, row_number() over (order by a.site_name, a.id) as rn,
           sum(a.income) over () as s_inc, sum(a.expense) over () as s_exp,
           sum(a.pending_income) over () as s_pinc, sum(a.pending_expense) over () as s_pexp,
           sum(a.net_balance) over () as s_net
    from act a
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'sr_no', n.rn, 'site_name', n.site_name, 'site_location', n.site_location,
           'client_name', n.client_name, 'total_income', n.income, 'total_expense', n.expense,
           'net_balance', n.net_balance, 'pending_income', n.pending_income,
           'pending_expense', n.pending_expense)
           order by n.rn) filter (where n.rn >  (v_pg - 1) * v_sz and n.rn <= v_pg * v_sz), '[]'::jsonb),
         coalesce(max(n.total), 0), coalesce(max(n.s_inc), 0), coalesce(max(n.s_exp), 0),
         coalesce(max(n.s_pinc), 0), coalesce(max(n.s_pexp), 0), coalesce(max(n.s_net), 0)
    into v_rows, v_total, v_inc, v_exp, v_pinc, v_pexp, v_op
  from numbered n;

  v_salary := public.fin_paid_salary(null, p_date_from, p_date_to);

  return jsonb_build_object(
    'meta', jsonb_build_object(
      'report', 'site_net_balance', 'title', 'Site Net Balance',
      'date_from', p_date_from, 'date_to', p_date_to,
      'filters', jsonb_build_object('site_id', p_site_id, 'client', p_client),
      'page', v_pg, 'page_size', v_sz, 'total_rows', v_total,
      'for_export', coalesce(p_for_export, false),
      'note', 'Net balance = received income - verified expenses. Not formal accounting profit.'),
    'rows', v_rows,
    'summary', jsonb_build_object(
      'total_sites',          v_total,
      'total_income',         v_inc,
      'total_expense',        v_exp,
      'pending_income',       v_pinc,
      'pending_expense',      v_pexp,
      'operating_balance',    v_op,
      'paid_salary',          v_salary,
      'after_salary_balance', v_op - v_salary,
      'salary_scope',         'company_wide')
  );
end $$;

-- =====================================================================================
-- 7. Report 14: Overall Financial Summary Invoice (13.14)
--    Sections: income, expenses, salary, overall (both balances).
--    rows = verified expense by site (highest first); summary.expense_by_employee = top 200.
-- =====================================================================================
create or replace function public.report_overall_financial_summary(
  p_actor_auth_id uuid,
  p_date_from     date,
  p_date_to       date,
  p_page          integer default 1,
  p_page_size     integer default 50,
  p_for_export    boolean default false
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_rows   jsonb;
  v_total  bigint;
  v_byemp  jsonb;
  v_inc    jsonb;
  v_sal    jsonb;
  v_sum    jsonb;
  v_pg     integer := greatest(1, coalesce(p_page, 1));
  v_sz     integer;
begin
  perform public.rpt_check_request(p_actor_auth_id, p_date_from, p_date_to, null,
                                   p_for_export, p_page, p_page_size);
  v_sz := greatest(1, least(coalesce(p_page_size, 50), case when coalesce(p_for_export, false) then 5000 else 200 end));

  with per as (
    select s.id, s.site_name, s.client_name,
           public.fin_verified_expenses(s.id, null, p_date_from, p_date_to) as expense
    from public.sites s
  ),
  act as (select * from per where expense > 0),
  numbered as (
    select a.*, count(*) over () as total,
           row_number() over (order by a.expense desc, a.site_name, a.id) as rn
    from act a
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'sr_no', n.rn, 'site_name', n.site_name, 'client_name', n.client_name, 'expense', n.expense)
           order by n.rn) filter (where n.rn >  (v_pg - 1) * v_sz and n.rn <= v_pg * v_sz), '[]'::jsonb),
         coalesce(max(n.total), 0)
    into v_rows, v_total
  from numbered n;

  select coalesce(jsonb_agg(jsonb_build_object(
           'employee_name', q.name, 'employee_id', q.emp_code, 'expense', q.expense)
           order by q.expense desc, q.name), '[]'::jsonb)
    into v_byemp
  from (
    select e.name, e.employee_id as emp_code,
           public.fin_verified_expenses(null, e.id, p_date_from, p_date_to) as expense
    from public.employees e
    order by 3 desc, e.name
    limit 200
  ) q
  where q.expense > 0;

  v_inc := public.fin_income_breakdown(null, p_date_from, p_date_to);
  v_sal := public.fin_salary_breakdown(null, null, p_date_from, p_date_to);
  v_sum := public.fin_summary(null, null, p_date_from, p_date_to);

  return jsonb_build_object(
    'meta', jsonb_build_object(
      'report', 'overall_financial_summary', 'title', 'Overall Financial Summary Invoice',
      'date_from', p_date_from, 'date_to', p_date_to,
      'page', v_pg, 'page_size', v_sz, 'total_rows', v_total,
      'for_export', coalesce(p_for_export, false),
      'note', 'Operating balance = received income - verified expenses. After-salary balance = operating balance - paid salary.'),
    'rows', v_rows,
    'summary', jsonb_build_object(
      'income', jsonb_build_object(
          'total_income',        v_inc -> 'total_income',
          'received_income',     v_sum -> 'received_income',
          'pending_income',      v_sum -> 'pending_income',
          'partially_received',  v_inc -> 'partially_received',
          'pending_status',      v_inc -> 'pending',
          'received_status',     v_inc -> 'received'),
      'expenses', jsonb_build_object(
          'total_site_expenses', v_sum -> 'verified_expenses',
          'pending_expenses',    v_sum -> 'pending_expenses',
          'by_employee',         v_byemp),
      'salary', jsonb_build_object(
          'total_salary',        v_sal -> 'total_salary',
          'paid_salary',         v_sum -> 'paid_salary',
          'pending_salary',      v_sum -> 'pending_salary'),
      'overall', jsonb_build_object(
          'income',               v_sum -> 'received_income',
          'expenses',             v_sum -> 'verified_expenses',
          'salary',               v_sum -> 'paid_salary',
          'operating_balance',    v_sum -> 'operating_balance',
          'after_salary_balance', v_sum -> 'after_salary_balance'))
  );
end $$;

-- =====================================================================================
-- 8. Grants: service_role only; internal helpers get no grant (matches 007 / 014 / 021 / 022)
-- =====================================================================================
revoke all on function public.fin_salary_breakdown(uuid, text, date, date)                         from public, anon, authenticated, service_role;
revoke all on function public.fin_employee_site_count(uuid, date, date)                            from public, anon, authenticated, service_role;
revoke all on function public.rpt_check_salary_status(text)                                        from public, anon, authenticated, service_role;
revoke all on function public.rpt_salary_rows(date, date, uuid, text, text, integer, integer, boolean) from public, anon, authenticated, service_role;

revoke all on function public.report_individual_employee_salary(uuid, uuid, date, date, text, integer, integer, boolean) from public, anon, authenticated;
revoke all on function public.report_overall_salary(uuid, date, date, uuid, text, text, integer, integer, boolean)        from public, anon, authenticated;
revoke all on function public.report_employee_salary_expense(uuid, date, date, uuid, text, integer, integer, boolean)    from public, anon, authenticated;
revoke all on function public.report_site_net_balance(uuid, date, date, uuid, text, integer, integer, boolean)           from public, anon, authenticated;
revoke all on function public.report_overall_financial_summary(uuid, date, date, integer, integer, boolean)              from public, anon, authenticated;

grant execute on function public.report_individual_employee_salary(uuid, uuid, date, date, text, integer, integer, boolean) to service_role;
grant execute on function public.report_overall_salary(uuid, date, date, uuid, text, text, integer, integer, boolean)        to service_role;
grant execute on function public.report_employee_salary_expense(uuid, date, date, uuid, text, integer, integer, boolean)    to service_role;
grant execute on function public.report_site_net_balance(uuid, date, date, uuid, text, integer, integer, boolean)           to service_role;
grant execute on function public.report_overall_financial_summary(uuid, date, date, integer, integer, boolean)              to service_role;