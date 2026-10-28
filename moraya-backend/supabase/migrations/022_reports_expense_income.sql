-- 022_reports_expense_income.sql
-- PURPOSE   : Reports 5-9 of Master Specification section 13:
--               report_overall_site_expense   (13.5 Overall Site Total Expense Invoice)
--               report_individual_site_expense(13.6 Individual Site Expense Invoice)
--               report_employee_expense       (13.7 Employee Expense Invoice)
--               report_overall_site_income    (13.8 Overall Site Total Income Invoice)
--               report_individual_site_income (13.9 Individual Site Income Invoice)
--             Each returns jsonb { meta, rows, summary }. Shared rules are in 021 (who may call,
--             dates, paging, export variant, no Aadhaar, read-only, pending shown separately).
-- DEPENDS ON: 008, 014, 016 (expenses), 018 (income_transactions), 020 (fin_* formulas and fact views),
--             021 (rpt_check_request).
-- ROLLBACK  : drop function public.report_individual_site_income(uuid, date, date, uuid, text, integer, integer, boolean);
--             drop function public.report_overall_site_income(uuid, date, date, uuid, text, text, integer, integer, boolean);
--             drop function public.report_employee_expense(uuid, uuid, date, date, uuid, text, integer, integer, boolean);
--             drop function public.report_individual_site_expense(uuid, date, date, uuid, uuid, text, integer, integer, boolean);
--             drop function public.report_overall_site_expense(uuid, date, date, uuid, uuid, text, text, integer, integer, boolean);
--             drop function public.rpt_income_rows(date, date, uuid, text, text, integer, integer, boolean);
--             drop function public.rpt_expense_rows(date, date, uuid, uuid, text, text, text, integer, integer, boolean);
--             drop function public.fin_income_breakdown(uuid, date, date);
--             drop function public.fin_expense_site_count(uuid, uuid, date, date, text);
--             drop function public.fin_expense_transaction_count(uuid, uuid, date, date, text);
--
-- EXTENSIONS TO 020 (kept here so 020 stays as delivered; they follow the same rules and also use only
-- the 020 fact views / status rules). Same filter semantics: NULL = no filter, dates inclusive.
--   fin_expense_transaction_count = COUNT of expenses with that bucket ('verified' default, or 'pending')
--   fin_expense_site_count        = COUNT(DISTINCT site) over the same expenses
--   fin_income_breakdown          = for NON-cancelled income of the filter: total_income (sum of amount),
--                                   plus count / amount / received / pending for each of pending,
--                                   partially_received, received. Reads income_transactions directly
--                                   because the 020 fact view does not carry the status.
--
-- ASSUMPTIONS (please confirm)
--   B1. Expense rows = VERIFIED expenses by default; p_status = 'pending_verification' lists pending ones.
--       Remarks = the expense remark, else the work entry remark.
--   B2. Income rows = every non-cancelled income transaction, filtered by p_status
--       ('all' default, 'pending', 'partially_received', 'received'). The row's INCOME = full amount;
--       it also carries received_amount and pending_amount. Cancelled income is never listed.
--   B3. Income "Total Income" in the summary = full amount of all non-cancelled rows in the filter;
--       "Received" and "Pending" money = fin_received_income / fin_pending_income from 020 (so a partly
--       received row counts in both); the three status groups are given with counts and amounts too.
--   B4. 13.5 "Total Sites" = number of distinct sites with at least one counted expense in the filter.
--   B5. Income report 13.8/13.9 filters: site, client (13.8 only), status. Employee and designation do
--       not apply to income.

-- =====================================================================================
-- 1. 020 extensions
-- =====================================================================================
create or replace function public.fin_expense_transaction_count(
  p_site uuid default null, p_employee uuid default null,
  p_from date default null, p_to date default null, p_bucket text default 'verified'
) returns bigint language sql stable set search_path = public, pg_temp as $$
  select count(*)::bigint
  from public.fin_expense_facts f
  where (case when p_bucket = 'pending' then f.pending_amount else f.verified_amount end) > 0
    and (p_site     is null or f.site_id     = p_site)
    and (p_employee is null or f.employee_id = p_employee)
    and (p_from     is null or f.fact_date  >= p_from)
    and (p_to       is null or f.fact_date  <= p_to)
$$;

create or replace function public.fin_expense_site_count(
  p_site uuid default null, p_employee uuid default null,
  p_from date default null, p_to date default null, p_bucket text default 'verified'
) returns bigint language sql stable set search_path = public, pg_temp as $$
  select count(distinct f.site_id)::bigint
  from public.fin_expense_facts f
  where (case when p_bucket = 'pending' then f.pending_amount else f.verified_amount end) > 0
    and (p_site     is null or f.site_id     = p_site)
    and (p_employee is null or f.employee_id = p_employee)
    and (p_from     is null or f.fact_date  >= p_from)
    and (p_to       is null or f.fact_date  <= p_to)
$$;

create or replace function public.fin_income_breakdown(
  p_site uuid default null, p_from date default null, p_to date default null
) returns jsonb language sql stable set search_path = public, pg_temp as $$
  with t as (
    select i.status, count(*) as n, coalesce(sum(i.amount), 0) as amt,
           coalesce(sum(i.received_amount), 0) as rec,
           coalesce(sum(i.amount - i.received_amount), 0) as pend
    from public.income_transactions i
    where i.status <> 'cancelled'
      and (p_site is null or i.site_id    = p_site)
      and (p_from is null or i.income_date >= p_from)
      and (p_to   is null or i.income_date <= p_to)
    group by i.status
  )
  select jsonb_build_object(
    'total_income', coalesce((select sum(amt) from t), 0)::bigint,
    'pending', jsonb_build_object(
        'count',  coalesce((select n   from t where status = 'pending'), 0),
        'amount', coalesce((select amt from t where status = 'pending'), 0)::bigint),
    'partially_received', jsonb_build_object(
        'count',    coalesce((select n    from t where status = 'partially_received'), 0),
        'amount',   coalesce((select amt  from t where status = 'partially_received'), 0)::bigint,
        'received', coalesce((select rec  from t where status = 'partially_received'), 0)::bigint,
        'pending',  coalesce((select pend from t where status = 'partially_received'), 0)::bigint),
    'received', jsonb_build_object(
        'count',  coalesce((select n   from t where status = 'received'), 0),
        'amount', coalesce((select amt from t where status = 'received'), 0)::bigint)
  )
$$;

-- =====================================================================================
-- 2. Row sources (internal)
-- =====================================================================================

-- One row per counted expense. p_status: 'verified' (default) or 'pending_verification'.
create or replace function public.rpt_expense_rows(
  p_date_from   date,
  p_date_to     date,
  p_site        uuid,
  p_employee    uuid,
  p_client      text,
  p_designation text,
  p_status      text,
  p_page        integer,
  p_page_size   integer,
  p_for_export  boolean
) returns table (
  total         bigint,
  sr_no         bigint,
  expense_id    uuid,
  expense_date  date,
  employee_id   uuid,
  employee_name text,
  emp_code      text,
  site_id       uuid,
  site_name     text,
  site_location text,
  client_name   text,
  category      text,
  expense       bigint,
  remarks       text
)
language sql
stable
set search_path = public, pg_temp
as $$
  with params as (
    select (coalesce(nullif(p_status, ''), 'verified') = 'pending_verification') as is_pending,
           greatest(1, coalesce(p_page, 1)) as pg,
           greatest(1, least(coalesce(p_page_size, 50),
                             case when coalesce(p_for_export, false) then 5000 else 200 end)) as sz
  ),
  base as (
    select f.expense_id, f.fact_date as expense_date, f.employee_id, f.site_id,
           case when p.is_pending then f.pending_amount else f.verified_amount end as expense,
           x.category, coalesce(x.remarks, w.remarks) as remarks, x.created_at,
           e.name as employee_name, e.employee_id as emp_code,
           s.site_name, s.site_location, s.client_name
    from public.fin_expense_facts f
    cross join params p
    join public.expenses x      on x.id = f.expense_id
    join public.work_entries w  on w.id = f.work_entry_id
    join public.employees e     on e.id = f.employee_id
    join public.sites s         on s.id = f.site_id
    where (case when p.is_pending then f.pending_amount else f.verified_amount end) > 0
      and f.fact_date between p_date_from and p_date_to
      and (p_site        is null or f.site_id = p_site)
      and (p_employee    is null or f.employee_id = p_employee)
      and (p_client      is null or lower(s.client_name) = lower(btrim(p_client)))
      and (p_designation is null or lower(e.designation) = lower(btrim(p_designation)))
  ),
  numbered as (
    select b.*, count(*) over () as total,
           row_number() over (order by b.expense_date, b.created_at, b.expense_id) as rn
    from base b
  )
  select n.total, n.rn, n.expense_id, n.expense_date, n.employee_id, n.employee_name, n.emp_code,
         n.site_id, n.site_name, n.site_location, n.client_name, n.category, n.expense, n.remarks
  from numbered n, params p
  where n.rn >  (p.pg - 1) * p.sz
    and n.rn <= (p.pg - 1) * p.sz + p.sz
  order by n.rn
$$;

-- One row per non-cancelled income transaction. p_status: 'all' | pending | partially_received | received.
create or replace function public.rpt_income_rows(
  p_date_from  date,
  p_date_to    date,
  p_site       uuid,
  p_client     text,
  p_status     text,
  p_page       integer,
  p_page_size  integer,
  p_for_export boolean
) returns table (
  total           bigint,
  sr_no           bigint,
  income_id       uuid,
  income_date     date,
  site_id         uuid,
  site_name       text,
  client_name     text,
  amount          bigint,
  received_amount bigint,
  pending_amount  bigint,
  description     text,
  status          text,
  remarks         text
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
    select i.id, i.income_date, i.site_id, s.site_name, s.client_name, i.amount, i.received_amount,
           (i.amount - i.received_amount) as pending_amount, i.description, i.status::text as status,
           i.remarks, i.created_at
    from public.income_transactions i
    join public.sites s on s.id = i.site_id
    where i.status <> 'cancelled'
      and i.income_date between p_date_from and p_date_to
      and (p_site   is null or i.site_id = p_site)
      and (p_client is null or lower(s.client_name) = lower(btrim(p_client)))
      and (coalesce(p_status, 'all') = 'all' or i.status::text = p_status)
  ),
  numbered as (
    select b.*, count(*) over () as total,
           row_number() over (order by b.income_date, b.created_at, b.id) as rn
    from base b
  )
  select n.total, n.rn, n.id, n.income_date, n.site_id, n.site_name, n.client_name, n.amount,
         n.received_amount, n.pending_amount, n.description, n.status, n.remarks
  from numbered n, params p
  where n.rn >  (p.pg - 1) * p.sz
    and n.rn <= (p.pg - 1) * p.sz + p.sz
  order by n.rn
$$;

-- Income status validation shared by the two income reports (internal).
create or replace function public.rpt_check_income_status(p_status text) returns void
language plpgsql set search_path = public, pg_temp as $$
begin
  if p_status is not null and p_status not in ('all', 'pending', 'partially_received', 'received') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid status');
  end if;
end $$;

-- =====================================================================================
-- 3. Report 5: Overall Site Total Expense Invoice (13.5)
--    Rows: SR NO, SITE, CLIENT, EMPLOYEE, DATE, EXPENSE, REMARKS
--    Summary: total_sites, total_expense_transactions, total_expense_amount (+ pending)
-- =====================================================================================
create or replace function public.report_overall_site_expense(
  p_actor_auth_id uuid,
  p_date_from     date,
  p_date_to       date,
  p_site_id       uuid    default null,
  p_employee_id   uuid    default null,
  p_client        text    default null,
  p_status        text    default 'verified',
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
  perform public.rpt_check_request(p_actor_auth_id, p_date_from, p_date_to, p_status,
                                   p_for_export, p_page, p_page_size);

  select coalesce(jsonb_agg(jsonb_build_object(
           'sr_no', r.sr_no, 'site_name', r.site_name, 'site_location', r.site_location,
           'client_name', r.client_name, 'employee_name', r.employee_name,
           'date', r.expense_date, 'expense', r.expense, 'remarks', r.remarks)
           order by r.sr_no), '[]'::jsonb),
         coalesce(max(r.total), 0)
    into v_rows, v_total
  from public.rpt_expense_rows(p_date_from, p_date_to, p_site_id, p_employee_id, p_client,
                               null, p_status, p_page, p_page_size, p_for_export) r;

  return jsonb_build_object(
    'meta', jsonb_build_object(
      'report', 'overall_site_expense', 'title', 'Overall Site Total Expense Invoice',
      'date_from', p_date_from, 'date_to', p_date_to,
      'filters', jsonb_build_object('site_id', p_site_id, 'employee_id', p_employee_id, 'client', p_client),
      'row_status', coalesce(p_status, 'verified'),
      'page', coalesce(p_page, 1), 'page_size', p_page_size, 'total_rows', v_total,
      'for_export', coalesce(p_for_export, false)),
    'rows', v_rows,
    'summary', jsonb_build_object(
      'total_sites',                public.fin_expense_site_count(p_site_id, p_employee_id, p_date_from, p_date_to),
      'total_expense_transactions', public.fin_expense_transaction_count(p_site_id, p_employee_id, p_date_from, p_date_to),
      'total_expense_amount',       public.fin_verified_expenses(p_site_id, p_employee_id, p_date_from, p_date_to),
      'pending_expense_transactions', public.fin_expense_transaction_count(p_site_id, p_employee_id, p_date_from, p_date_to, 'pending'),
      'pending_expense_amount',     public.fin_pending_expenses(p_site_id, p_employee_id, p_date_from, p_date_to))
  );
end $$;

-- =====================================================================================
-- 4. Report 6: Individual Site Expense Invoice (13.6)
--    Rows: SR NO, DATE, EMPLOYEE, SITE, EXPENSE, REMARKS.  Summary: Total Expense (+ pending).
-- =====================================================================================
create or replace function public.report_individual_site_expense(
  p_actor_auth_id uuid,
  p_date_from     date,
  p_date_to       date,
  p_site_id       uuid,
  p_employee_id   uuid    default null,
  p_status        text    default 'verified',
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
  v_site  public.sites;
  v_rows  jsonb;
  v_total bigint;
begin
  perform public.rpt_check_request(p_actor_auth_id, p_date_from, p_date_to, p_status,
                                   p_for_export, p_page, p_page_size);
  if p_site_id is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Site is required');
  end if;
  select * into v_site from public.sites s where s.id = p_site_id;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Site not found');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'sr_no', r.sr_no, 'date', r.expense_date, 'employee_name', r.employee_name,
           'site_name', r.site_name, 'expense', r.expense, 'remarks', r.remarks)
           order by r.sr_no), '[]'::jsonb),
         coalesce(max(r.total), 0)
    into v_rows, v_total
  from public.rpt_expense_rows(p_date_from, p_date_to, p_site_id, p_employee_id, null,
                               null, p_status, p_page, p_page_size, p_for_export) r;

  return jsonb_build_object(
    'meta', jsonb_build_object(
      'report', 'individual_site_expense', 'title', 'Individual Site Expense Invoice',
      'date_from', p_date_from, 'date_to', p_date_to,
      'site', jsonb_build_object('id', v_site.id, 'site_name', v_site.site_name,
                                 'site_location', v_site.site_location, 'client_name', v_site.client_name),
      'filters', jsonb_build_object('employee_id', p_employee_id),
      'row_status', coalesce(p_status, 'verified'),
      'page', coalesce(p_page, 1), 'page_size', p_page_size, 'total_rows', v_total,
      'for_export', coalesce(p_for_export, false)),
    'rows', v_rows,
    'summary', jsonb_build_object(
      'total_expense',   public.fin_verified_expenses(p_site_id, p_employee_id, p_date_from, p_date_to),
      'pending_expense', public.fin_pending_expenses(p_site_id, p_employee_id, p_date_from, p_date_to))
  );
end $$;

-- =====================================================================================
-- 5. Report 7: Employee Expense Invoice (13.7)
--    Rows: SR NO, DATE, EMPLOYEE, SITE, CLIENT, EXPENSE, REMARKS.
--    Summary: Total Expense, Number of Expense Transactions, Number of Sites (+ pending).
-- =====================================================================================
create or replace function public.report_employee_expense(
  p_actor_auth_id uuid,
  p_employee_id   uuid,
  p_date_from     date,
  p_date_to       date,
  p_site_id       uuid    default null,
  p_status        text    default 'verified',
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
  perform public.rpt_check_request(p_actor_auth_id, p_date_from, p_date_to, p_status,
                                   p_for_export, p_page, p_page_size);
  if p_employee_id is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Employee is required');
  end if;
  select * into v_emp from public.employees e where e.id = p_employee_id;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Employee not found');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'sr_no', r.sr_no, 'date', r.expense_date, 'employee_name', r.employee_name,
           'site_name', r.site_name, 'client_name', r.client_name,
           'expense', r.expense, 'remarks', r.remarks)
           order by r.sr_no), '[]'::jsonb),
         coalesce(max(r.total), 0)
    into v_rows, v_total
  from public.rpt_expense_rows(p_date_from, p_date_to, p_site_id, p_employee_id, null,
                               null, p_status, p_page, p_page_size, p_for_export) r;

  return jsonb_build_object(
    'meta', jsonb_build_object(
      'report', 'employee_expense', 'title', 'Employee Expense Invoice',
      'date_from', p_date_from, 'date_to', p_date_to,
      'employee', jsonb_build_object('id', v_emp.id, 'employee_id', v_emp.employee_id,
                                     'name', v_emp.name, 'designation', v_emp.designation),
      'filters', jsonb_build_object('site_id', p_site_id),
      'row_status', coalesce(p_status, 'verified'),
      'page', coalesce(p_page, 1), 'page_size', p_page_size, 'total_rows', v_total,
      'for_export', coalesce(p_for_export, false)),
    'rows', v_rows,
    'summary', jsonb_build_object(
      'total_expense',          public.fin_verified_expenses(p_site_id, p_employee_id, p_date_from, p_date_to),
      'expense_transactions',   public.fin_expense_transaction_count(p_site_id, p_employee_id, p_date_from, p_date_to),
      'number_of_sites',        public.fin_expense_site_count(p_site_id, p_employee_id, p_date_from, p_date_to),
      'pending_expense',        public.fin_pending_expenses(p_site_id, p_employee_id, p_date_from, p_date_to),
      'pending_expense_transactions', public.fin_expense_transaction_count(p_site_id, p_employee_id, p_date_from, p_date_to, 'pending'))
  );
end $$;

-- =====================================================================================
-- 6. Report 8: Overall Site Total Income Invoice (13.8)
--    Rows: SR NO, DATE, SITE, CLIENT, INCOME, REFERENCE/DESCRIPTION, STATUS, REMARKS
--    (+ received_amount, pending_amount per row)
--    Summary: Total Income, Received, Pending, Partially Received.
-- =====================================================================================
create or replace function public.report_overall_site_income(
  p_actor_auth_id uuid,
  p_date_from     date,
  p_date_to       date,
  p_site_id       uuid    default null,
  p_client        text    default null,
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
  perform public.rpt_check_income_status(p_status);

  select coalesce(jsonb_agg(jsonb_build_object(
           'sr_no', r.sr_no, 'date', r.income_date, 'site_name', r.site_name,
           'client_name', r.client_name, 'income', r.amount,
           'received_amount', r.received_amount, 'pending_amount', r.pending_amount,
           'description', r.description, 'status', r.status, 'remarks', r.remarks)
           order by r.sr_no), '[]'::jsonb),
         coalesce(max(r.total), 0)
    into v_rows, v_total
  from public.rpt_income_rows(p_date_from, p_date_to, p_site_id, p_client, p_status,
                              p_page, p_page_size, p_for_export) r;

  return jsonb_build_object(
    'meta', jsonb_build_object(
      'report', 'overall_site_income', 'title', 'Overall Site Total Income Invoice',
      'date_from', p_date_from, 'date_to', p_date_to,
      'filters', jsonb_build_object('site_id', p_site_id, 'client', p_client),
      'row_status', coalesce(p_status, 'all'),
      'page', coalesce(p_page, 1), 'page_size', p_page_size, 'total_rows', v_total,
      'for_export', coalesce(p_for_export, false)),
    'rows', v_rows,
    'summary', public.fin_income_breakdown(p_site_id, p_date_from, p_date_to)
               || jsonb_build_object(
                    'received_income', public.fin_received_income(p_site_id, p_date_from, p_date_to),
                    'pending_income',  public.fin_pending_income(p_site_id, p_date_from, p_date_to))
  );
end $$;

-- =====================================================================================
-- 7. Report 9: Individual Site Income Invoice (13.9)
--    Rows: SR NO, DATE, SITE, CLIENT, INCOME, REFERENCE, STATUS, REMARKS
--    Summary: Total Income, Total Received, Total Pending.
-- =====================================================================================
create or replace function public.report_individual_site_income(
  p_actor_auth_id uuid,
  p_date_from     date,
  p_date_to       date,
  p_site_id       uuid,
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
  v_site  public.sites;
  v_rows  jsonb;
  v_total bigint;
begin
  perform public.rpt_check_request(p_actor_auth_id, p_date_from, p_date_to, null,
                                   p_for_export, p_page, p_page_size);
  perform public.rpt_check_income_status(p_status);
  if p_site_id is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Site is required');
  end if;
  select * into v_site from public.sites s where s.id = p_site_id;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Site not found');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'sr_no', r.sr_no, 'date', r.income_date, 'site_name', r.site_name,
           'client_name', r.client_name, 'income', r.amount,
           'received_amount', r.received_amount, 'pending_amount', r.pending_amount,
           'reference', r.description, 'status', r.status, 'remarks', r.remarks)
           order by r.sr_no), '[]'::jsonb),
         coalesce(max(r.total), 0)
    into v_rows, v_total
  from public.rpt_income_rows(p_date_from, p_date_to, p_site_id, null, p_status,
                              p_page, p_page_size, p_for_export) r;

  return jsonb_build_object(
    'meta', jsonb_build_object(
      'report', 'individual_site_income', 'title', 'Individual Site Income Invoice',
      'date_from', p_date_from, 'date_to', p_date_to,
      'site', jsonb_build_object('id', v_site.id, 'site_name', v_site.site_name,
                                 'site_location', v_site.site_location, 'client_name', v_site.client_name),
      'row_status', coalesce(p_status, 'all'),
      'page', coalesce(p_page, 1), 'page_size', p_page_size, 'total_rows', v_total,
      'for_export', coalesce(p_for_export, false)),
    'rows', v_rows,
    'summary', jsonb_build_object(
      'total_income',   (public.fin_income_breakdown(p_site_id, p_date_from, p_date_to) ->> 'total_income')::bigint,
      'total_received', public.fin_received_income(p_site_id, p_date_from, p_date_to),
      'total_pending',  public.fin_pending_income(p_site_id, p_date_from, p_date_to))
  );
end $$;

-- =====================================================================================
-- 8. Grants: service_role only; internal helpers get no grant (matches 007 / 014 / 021)
-- =====================================================================================
revoke all on function public.fin_expense_transaction_count(uuid, uuid, date, date, text) from public, anon, authenticated, service_role;
revoke all on function public.fin_expense_site_count(uuid, uuid, date, date, text)        from public, anon, authenticated, service_role;
revoke all on function public.fin_income_breakdown(uuid, date, date)                      from public, anon, authenticated, service_role;
revoke all on function public.rpt_expense_rows(date, date, uuid, uuid, text, text, text, integer, integer, boolean) from public, anon, authenticated, service_role;
revoke all on function public.rpt_income_rows(date, date, uuid, text, text, integer, integer, boolean)             from public, anon, authenticated, service_role;
revoke all on function public.rpt_check_income_status(text)                               from public, anon, authenticated, service_role;

revoke all on function public.report_overall_site_expense(uuid, date, date, uuid, uuid, text, text, integer, integer, boolean)  from public, anon, authenticated;
revoke all on function public.report_individual_site_expense(uuid, date, date, uuid, uuid, text, integer, integer, boolean)     from public, anon, authenticated;
revoke all on function public.report_employee_expense(uuid, uuid, date, date, uuid, text, integer, integer, boolean)            from public, anon, authenticated;
revoke all on function public.report_overall_site_income(uuid, date, date, uuid, text, text, integer, integer, boolean)         from public, anon, authenticated;
revoke all on function public.report_individual_site_income(uuid, date, date, uuid, text, integer, integer, boolean)            from public, anon, authenticated;

grant execute on function public.report_overall_site_expense(uuid, date, date, uuid, uuid, text, text, integer, integer, boolean)  to service_role;
grant execute on function public.report_individual_site_expense(uuid, date, date, uuid, uuid, text, integer, integer, boolean)     to service_role;
grant execute on function public.report_employee_expense(uuid, uuid, date, date, uuid, text, integer, integer, boolean)            to service_role;
grant execute on function public.report_overall_site_income(uuid, date, date, uuid, text, text, integer, integer, boolean)         to service_role;
grant execute on function public.report_individual_site_income(uuid, date, date, uuid, text, integer, integer, boolean)            to service_role;