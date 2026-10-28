-- 020_financial_formulas.sql
-- PURPOSE   : THE single source of truth for money logic. Every report (021-023), the client bill (024)
--             and the dashboards (025) must call the objects below and must NOT re-implement any
--             formula or any "which rows count" rule. If a rule changes, it changes here only.
-- DEPENDS ON: 002 (employees), 014 (sites), 015 (work_entries, verification_status),
--             016 (expenses), 018 (income_transactions), 019 (salary_records).
-- ROLLBACK  : drop function public.fin_summary(uuid, uuid, date, date);
--             drop function public.fin_employee_totals(uuid, date, date, integer, integer);
--             drop function public.fin_site_totals(uuid, date, date, integer, integer);
--             drop function public.fin_visit_count(uuid, date, date);
--             drop function public.fin_unique_worker_count(uuid, date, date);
--             drop function public.fin_work_entry_count(uuid, uuid, date, date);
--             drop function public.fin_after_salary_balance(uuid, date, date);
--             drop function public.fin_operating_balance(uuid, date, date);
--             drop function public.fin_pending_salary(uuid, date, date);
--             drop function public.fin_paid_salary(uuid, date, date);
--             drop function public.fin_pending_income(uuid, date, date);
--             drop function public.fin_received_income(uuid, date, date);
--             drop function public.fin_pending_expenses(uuid, uuid, date, date);
--             drop function public.fin_verified_expenses(uuid, uuid, date, date);
--             drop view public.fin_work_facts;
--             drop view public.fin_salary_facts;
--             drop view public.fin_income_facts;
--             drop view public.fin_expense_facts;
--             (Drop 021+ objects that use them first.)
--
-- =====================================================================================
-- RULES (one line each; the code below is the only place they are written)
-- =====================================================================================
--  All amounts are bigint paise. A NULL filter means "no filter". Dates are inclusive on both ends.
--  A NULL date_from / date_to means unbounded on that side.
--
--  OFFICIAL totals count VERIFIED records only. PENDING is always returned separately.
--  Rejected, cancelled, draft and changes_requested records are in NEITHER bucket.
--
--  verified expenses   = SUM(expenses.amount)            WHERE status = 'verified'
--                        date = expense_date, filters: site, employee (the surveyor who spent it)
--  pending expenses    = SUM(expenses.amount)            WHERE status = 'pending_verification'
--  received income     = SUM(income.received_amount)     WHERE status IN ('received','partially_received')
--                        date = income_date, filter: site
--  pending income      = SUM(income.amount - received)   WHERE status IN ('pending','partially_received')
--                        (so a partially received row contributes to BOTH received and pending)
--  paid salary         = SUM(salary.paid_amount)         WHERE status IN ('paid','partially_paid')
--  pending salary      = SUM(salary.amount - paid)       WHERE status IN ('pending','partially_paid')
--                        salary date = COALESCE(credited_date, period_end), used for BOTH paid and
--                        pending so one salary row always falls in one date bucket. Filter: employee.
--  operating balance   = received income - verified expenses
--  after-salary balance= operating balance - paid salary
--  work entry count    = COUNT of VERIFIED work entries (date = work_date; employee filter matches the
--                        surveyor OR the assistant)
--  unique worker count = COUNT(DISTINCT person) over the surveyors and assistants of VERIFIED entries
--  visit count         = COUNT(DISTINCT (site, work_date)) over VERIFIED work entries
--                        (two entries on the same site on the same day are ONE visit)
--
-- ASSUMPTIONS (please confirm):
--  A1. Salary has no site, so it cannot be split per site. When a site filter is given, paid salary is
--      still the COMPANY-WIDE figure for the same dates, and fin_summary says so
--      (salary_scope = 'company_wide'). With no site filter salary_scope = 'all'.
--  A2. "Pending" expenses = pending_verification only. draft and changes_requested are in no bucket
--      because they are not yet awaiting a decision.
--  A3. Income "received" counts the received part of a partially received row; the unpaid rest is pending.
-- =====================================================================================

-- =====================================================================================
-- 1. Fact views. Each defines ONCE which rows count and in which bucket.
--    security_invoker + no grants: only the SECURITY DEFINER functions of later files read them.
-- =====================================================================================

create or replace view public.fin_expense_facts with (security_invoker = true) as
select
  x.id            as expense_id,
  x.work_entry_id,
  x.employee_id,
  x.site_id,
  x.expense_date  as fact_date,
  case when x.verification_status = 'verified'             then x.amount else 0 end as verified_amount,
  case when x.verification_status = 'pending_verification' then x.amount else 0 end as pending_amount
from public.expenses x
where x.verification_status in ('verified', 'pending_verification');

create or replace view public.fin_income_facts with (security_invoker = true) as
select
  i.id            as income_id,
  i.site_id,
  i.income_date   as fact_date,
  case when i.status in ('received', 'partially_received') then i.received_amount else 0 end as received_amount,
  case when i.status in ('pending', 'partially_received')  then i.amount - i.received_amount else 0 end as pending_amount
from public.income_transactions i
where i.status in ('pending', 'partially_received', 'received');

create or replace view public.fin_salary_facts with (security_invoker = true) as
select
  s.id            as salary_id,
  s.employee_id,
  coalesce(s.credited_date, s.period_end) as fact_date,
  case when s.status in ('paid', 'partially_paid')    then s.paid_amount else 0 end as paid_amount,
  case when s.status in ('pending', 'partially_paid') then s.amount - s.paid_amount else 0 end as pending_amount
from public.salary_records s;

-- One row per (verified work entry, person on it). A person is the surveyor or the assistant.
create or replace view public.fin_work_facts with (security_invoker = true) as
select
  w.id            as work_entry_id,
  w.site_id,
  w.work_date     as fact_date,
  w.surveyor_id,
  w.assistant_id
from public.work_entries w
where w.verification_status = 'verified';

revoke all on public.fin_expense_facts, public.fin_income_facts,
              public.fin_salary_facts,  public.fin_work_facts
  from public, anon, authenticated, service_role;

-- =====================================================================================
-- 2. Scalar formulas (internal: SECURITY DEFINER callers only; no grants to anyone)
-- =====================================================================================

create or replace function public.fin_verified_expenses(
  p_site uuid default null, p_employee uuid default null, p_from date default null, p_to date default null
) returns bigint language sql stable set search_path = public, pg_temp as $$
  select coalesce(sum(f.verified_amount), 0)::bigint
  from public.fin_expense_facts f
  where (p_site     is null or f.site_id     = p_site)
    and (p_employee is null or f.employee_id = p_employee)
    and (p_from     is null or f.fact_date  >= p_from)
    and (p_to       is null or f.fact_date  <= p_to)
$$;

create or replace function public.fin_pending_expenses(
  p_site uuid default null, p_employee uuid default null, p_from date default null, p_to date default null
) returns bigint language sql stable set search_path = public, pg_temp as $$
  select coalesce(sum(f.pending_amount), 0)::bigint
  from public.fin_expense_facts f
  where (p_site     is null or f.site_id     = p_site)
    and (p_employee is null or f.employee_id = p_employee)
    and (p_from     is null or f.fact_date  >= p_from)
    and (p_to       is null or f.fact_date  <= p_to)
$$;

create or replace function public.fin_received_income(
  p_site uuid default null, p_from date default null, p_to date default null
) returns bigint language sql stable set search_path = public, pg_temp as $$
  select coalesce(sum(f.received_amount), 0)::bigint
  from public.fin_income_facts f
  where (p_site is null or f.site_id    = p_site)
    and (p_from is null or f.fact_date >= p_from)
    and (p_to   is null or f.fact_date <= p_to)
$$;

create or replace function public.fin_pending_income(
  p_site uuid default null, p_from date default null, p_to date default null
) returns bigint language sql stable set search_path = public, pg_temp as $$
  select coalesce(sum(f.pending_amount), 0)::bigint
  from public.fin_income_facts f
  where (p_site is null or f.site_id    = p_site)
    and (p_from is null or f.fact_date >= p_from)
    and (p_to   is null or f.fact_date <= p_to)
$$;

create or replace function public.fin_paid_salary(
  p_employee uuid default null, p_from date default null, p_to date default null
) returns bigint language sql stable set search_path = public, pg_temp as $$
  select coalesce(sum(f.paid_amount), 0)::bigint
  from public.fin_salary_facts f
  where (p_employee is null or f.employee_id = p_employee)
    and (p_from     is null or f.fact_date  >= p_from)
    and (p_to       is null or f.fact_date  <= p_to)
$$;

create or replace function public.fin_pending_salary(
  p_employee uuid default null, p_from date default null, p_to date default null
) returns bigint language sql stable set search_path = public, pg_temp as $$
  select coalesce(sum(f.pending_amount), 0)::bigint
  from public.fin_salary_facts f
  where (p_employee is null or f.employee_id = p_employee)
    and (p_from     is null or f.fact_date  >= p_from)
    and (p_to       is null or f.fact_date  <= p_to)
$$;

-- operating balance = received income - verified expenses
create or replace function public.fin_operating_balance(
  p_site uuid default null, p_from date default null, p_to date default null
) returns bigint language sql stable set search_path = public, pg_temp as $$
  select public.fin_received_income(p_site, p_from, p_to)
       - public.fin_verified_expenses(p_site, null, p_from, p_to)
$$;

-- after-salary balance = operating balance - paid salary (company-wide salary, see A1)
create or replace function public.fin_after_salary_balance(
  p_site uuid default null, p_from date default null, p_to date default null
) returns bigint language sql stable set search_path = public, pg_temp as $$
  select public.fin_operating_balance(p_site, p_from, p_to)
       - public.fin_paid_salary(null, p_from, p_to)
$$;

-- verified work entries; the employee filter matches surveyor OR assistant
create or replace function public.fin_work_entry_count(
  p_site uuid default null, p_employee uuid default null, p_from date default null, p_to date default null
) returns bigint language sql stable set search_path = public, pg_temp as $$
  select count(*)::bigint
  from public.fin_work_facts f
  where (p_site     is null or f.site_id = p_site)
    and (p_employee is null or f.surveyor_id = p_employee or f.assistant_id = p_employee)
    and (p_from     is null or f.fact_date >= p_from)
    and (p_to       is null or f.fact_date <= p_to)
$$;

-- distinct people across surveyor and assistant of verified entries
create or replace function public.fin_unique_worker_count(
  p_site uuid default null, p_from date default null, p_to date default null
) returns bigint language sql stable set search_path = public, pg_temp as $$
  select count(distinct p.person)::bigint
  from public.fin_work_facts f
  cross join lateral (values (f.surveyor_id), (f.assistant_id)) as p(person)
  where p.person is not null
    and (p_site is null or f.site_id    = p_site)
    and (p_from is null or f.fact_date >= p_from)
    and (p_to   is null or f.fact_date <= p_to)
$$;

-- distinct (site, date) of verified entries
create or replace function public.fin_visit_count(
  p_site uuid default null, p_from date default null, p_to date default null
) returns bigint language sql stable set search_path = public, pg_temp as $$
  select count(*)::bigint
  from (
    select distinct f.site_id, f.fact_date
    from public.fin_work_facts f
    where (p_site is null or f.site_id    = p_site)
      and (p_from is null or f.fact_date >= p_from)
      and (p_to   is null or f.fact_date <= p_to)
  ) v
$$;

-- =====================================================================================
-- 3. Grouped formulas for reports and dashboards. They aggregate the SAME fact views.
-- =====================================================================================

-- One row per site that has any activity in the range (or the single site asked for).
create or replace function public.fin_site_totals(
  p_site uuid default null, p_from date default null, p_to date default null,
  p_limit integer default 50, p_offset integer default 0
) returns table (
  site_id uuid,
  verified_expenses bigint, pending_expenses bigint,
  received_income bigint,   pending_income bigint,
  operating_balance bigint,
  work_entry_count bigint,  unique_worker_count bigint, visit_count bigint
) language sql stable set search_path = public, pg_temp as $$
  with ids as (
    select e.site_id from public.fin_expense_facts e
      where (p_site is null or e.site_id = p_site) and (p_from is null or e.fact_date >= p_from) and (p_to is null or e.fact_date <= p_to)
    union
    select i.site_id from public.fin_income_facts i
      where (p_site is null or i.site_id = p_site) and (p_from is null or i.fact_date >= p_from) and (p_to is null or i.fact_date <= p_to)
    union
    select w.site_id from public.fin_work_facts w
      where (p_site is null or w.site_id = p_site) and (p_from is null or w.fact_date >= p_from) and (p_to is null or w.fact_date <= p_to)
  )
  select
    ids.site_id,
    public.fin_verified_expenses(ids.site_id, null, p_from, p_to),
    public.fin_pending_expenses(ids.site_id, null, p_from, p_to),
    public.fin_received_income(ids.site_id, p_from, p_to),
    public.fin_pending_income(ids.site_id, p_from, p_to),
    public.fin_operating_balance(ids.site_id, p_from, p_to),
    public.fin_work_entry_count(ids.site_id, null, p_from, p_to),
    public.fin_unique_worker_count(ids.site_id, p_from, p_to),
    public.fin_visit_count(ids.site_id, p_from, p_to)
  from ids
  order by ids.site_id
  limit greatest(1, least(coalesce(p_limit, 50), 500))
  offset greatest(0, coalesce(p_offset, 0))
$$;

-- One row per employee that has any activity in the range (or the single employee asked for).
create or replace function public.fin_employee_totals(
  p_employee uuid default null, p_from date default null, p_to date default null,
  p_limit integer default 50, p_offset integer default 0
) returns table (
  employee_id uuid,
  verified_expenses bigint, pending_expenses bigint,
  paid_salary bigint,       pending_salary bigint,
  work_entry_count bigint
) language sql stable set search_path = public, pg_temp as $$
  with ids as (
    select e.employee_id from public.fin_expense_facts e
      where (p_employee is null or e.employee_id = p_employee) and (p_from is null or e.fact_date >= p_from) and (p_to is null or e.fact_date <= p_to)
    union
    select s.employee_id from public.fin_salary_facts s
      where (p_employee is null or s.employee_id = p_employee) and (p_from is null or s.fact_date >= p_from) and (p_to is null or s.fact_date <= p_to)
    union
    select w.surveyor_id from public.fin_work_facts w
      where (p_employee is null or w.surveyor_id = p_employee) and (p_from is null or w.fact_date >= p_from) and (p_to is null or w.fact_date <= p_to)
    union
    select w.assistant_id from public.fin_work_facts w
      where w.assistant_id is not null and (p_employee is null or w.assistant_id = p_employee)
        and (p_from is null or w.fact_date >= p_from) and (p_to is null or w.fact_date <= p_to)
  )
  select
    ids.employee_id,
    public.fin_verified_expenses(null, ids.employee_id, p_from, p_to),
    public.fin_pending_expenses(null, ids.employee_id, p_from, p_to),
    public.fin_paid_salary(ids.employee_id, p_from, p_to),
    public.fin_pending_salary(ids.employee_id, p_from, p_to),
    public.fin_work_entry_count(null, ids.employee_id, p_from, p_to)
  from ids
  order by ids.employee_id
  limit greatest(1, least(coalesce(p_limit, 50), 500))
  offset greatest(0, coalesce(p_offset, 0))
$$;

-- Everything in one jsonb: the object the dashboard, Site Net Balance and Overall Financial Summary
-- all use, so their numbers cannot differ. Optional site and employee filters.
-- p_employee only narrows the employee-based figures (expenses, salary, work entries).
create or replace function public.fin_summary(
  p_site uuid default null, p_employee uuid default null, p_from date default null, p_to date default null
) returns jsonb language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'verified_expenses',     public.fin_verified_expenses(p_site, p_employee, p_from, p_to),
    'pending_expenses',      public.fin_pending_expenses(p_site, p_employee, p_from, p_to),
    'received_income',       public.fin_received_income(p_site, p_from, p_to),
    'pending_income',        public.fin_pending_income(p_site, p_from, p_to),
    'paid_salary',           public.fin_paid_salary(p_employee, p_from, p_to),
    'pending_salary',        public.fin_pending_salary(p_employee, p_from, p_to),
    'operating_balance',     public.fin_operating_balance(p_site, p_from, p_to),
    'after_salary_balance',  public.fin_after_salary_balance(p_site, p_from, p_to),
    'salary_scope',          case when p_site is null then 'all' else 'company_wide' end,
    'work_entry_count',      public.fin_work_entry_count(p_site, p_employee, p_from, p_to),
    'unique_worker_count',   public.fin_unique_worker_count(p_site, p_from, p_to),
    'visit_count',           public.fin_visit_count(p_site, p_from, p_to)
  )
$$;

-- =====================================================================================
-- 4. Grants: internal helpers. Nobody (including service_role) may call them from the API;
--    only SECURITY DEFINER functions in later migrations do. Matches the helper pattern in 014.
-- =====================================================================================
revoke all on function public.fin_verified_expenses(uuid, uuid, date, date)             from public, anon, authenticated, service_role;
revoke all on function public.fin_pending_expenses(uuid, uuid, date, date)              from public, anon, authenticated, service_role;
revoke all on function public.fin_received_income(uuid, date, date)                     from public, anon, authenticated, service_role;
revoke all on function public.fin_pending_income(uuid, date, date)                      from public, anon, authenticated, service_role;
revoke all on function public.fin_paid_salary(uuid, date, date)                         from public, anon, authenticated, service_role;
revoke all on function public.fin_pending_salary(uuid, date, date)                      from public, anon, authenticated, service_role;
revoke all on function public.fin_operating_balance(uuid, date, date)                   from public, anon, authenticated, service_role;
revoke all on function public.fin_after_salary_balance(uuid, date, date)                from public, anon, authenticated, service_role;
revoke all on function public.fin_work_entry_count(uuid, uuid, date, date)              from public, anon, authenticated, service_role;
revoke all on function public.fin_unique_worker_count(uuid, date, date)                 from public, anon, authenticated, service_role;
revoke all on function public.fin_visit_count(uuid, date, date)                         from public, anon, authenticated, service_role;
revoke all on function public.fin_site_totals(uuid, date, date, integer, integer)       from public, anon, authenticated, service_role;
revoke all on function public.fin_employee_totals(uuid, date, date, integer, integer)   from public, anon, authenticated, service_role;
revoke all on function public.fin_summary(uuid, uuid, date, date)                       from public, anon, authenticated, service_role;