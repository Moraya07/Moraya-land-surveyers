-- 021_reports_work.sql
-- PURPOSE   : Reports 1-4 of Master Specification section 13, as RPC functions the Worker calls
--               report_overall_work_site      (13.1 Overall Work/Site Invoice)
--               report_personal_employee_work (13.2 Personal Employee Work Invoice)
--               report_overall_employee_work  (13.3 Overall Employee Work Invoice)
--               report_site_invoice           (13.4 Site Invoice)
--             Each returns jsonb { meta, rows, summary }.
--             Files 022 and 023 follow the same shared requirements.
-- DEPENDS ON: 002, 014 (sites), 015 (work_entries), 016 (expenses), 008 (moraya_require_actor,
--             moraya_fail), 020 (fin_* formulas and fact views: ALL totals and all "which rows count"
--             rules come from there; nothing is re-implemented here).
-- ROLLBACK  : drop function public.report_site_invoice(uuid, date, date, uuid, text, text, integer, integer, boolean);
--             drop function public.report_overall_employee_work(uuid, date, date, uuid, uuid, text, text, text, integer, integer, boolean);
--             drop function public.report_personal_employee_work(uuid, uuid, date, date, uuid, text, integer, integer, boolean);
--             drop function public.report_overall_work_site(uuid, date, date, uuid, uuid, text, text, text, integer, integer, boolean);
--             drop function public.rpt_work_rows(date, date, uuid, uuid, text, text, text, integer, integer, boolean);
--             drop function public.rpt_check_request(uuid, date, date, text, boolean, integer, integer);
--
-- SHARED RULES (021, 022, 023)
--   * Who: main_admin, or a sub_admin with report_view. p_for_export = true is the export variant:
--     it needs the export permission instead (or main_admin) and allows a bigger page (max 5000
--     rows instead of 200). Workers and inactive users get MORAYA_FORBIDDEN.
--   * Dates: p_date_from and p_date_to are required, inclusive, from <= to, at most 3660 days apart,
--     else MORAYA_VALIDATION.
--   * Rows are official = VERIFIED work entries. p_status may be 'verified' (default) or
--     'pending_verification' to list the pending rows instead. Anything else is MORAYA_VALIDATION.
--   * summary always carries the official totals AND the pending totals separately, from 020.
--     Rejected, cancelled, draft and changes_requested are never counted.
--   * Aadhaar never appears. Reports are read-only and are not written to the audit log
--     (no REPORT_* audit action exists in 008).
--   * Paging: p_page (1-based) and p_page_size, like list_sites. meta.total_rows is the full count.
--   * Money in rows and summary is bigint paise.
--
-- ASSUMPTIONS (please confirm)
--   A1. "SITE INCOME" in report 13.1: income is recorded per site, not per work entry. A row shows the
--       site's received income dated the same day as the work entry, on the FIRST row of that
--       (site, date) only, 0 on the others, so row sums never double count. summary.received_income
--       (from 020) is the official figure and also includes income on days without work.
--   A2. "EXPENSE" on a row = the verified (or, for pending rows, pending) expense of that work entry.
--   A3. Report 13.2: when the chosen employee was the ASSISTANT on a row, expense is null on that row
--       (the expense belongs to the surveyor). Rows show role = 'surveyor' or 'assistant'.
--   A4. Report 13.3: one row per work entry, "employee" = the surveyor. The employee filter matches
--       the surveyor OR the assistant. "Work entry" column = the WE-YYYY-NNNNN code.
--   A5. Filters: client = case-insensitive exact match on sites.client_name; designation = the
--       surveyor's designation, case-insensitive exact match.
--   A6. Order: work_date, work_time, code (ascending). sr_no is the position in that order.

-- =====================================================================================
-- 1. Shared validation (internal)
--    Returns the actor row; raises MORAYA_FORBIDDEN / MORAYA_VALIDATION.
-- =====================================================================================
create or replace function public.rpt_check_request(
  p_actor_auth_id uuid,
  p_date_from     date,
  p_date_to       date,
  p_status        text,
  p_for_export    boolean,
  p_page          integer,
  p_page_size     integer
) returns public.employees
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor public.employees;
begin
  v_actor := public.moraya_require_actor(
    p_actor_auth_id, false,
    case when coalesce(p_for_export, false) then array['export'] else array['report_view'] end);

  if p_date_from is null or p_date_to is null or p_date_from > p_date_to
     or p_date_to - p_date_from > 3660 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid date range');
  end if;

  if p_status is not null and p_status not in ('verified', 'pending_verification') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid status');
  end if;

  if p_page is not null and p_page < 1 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid page');
  end if;
  if p_page_size is not null and p_page_size < 1 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid page size');
  end if;

  return v_actor;
end $$;

-- =====================================================================================
-- 2. Shared row source (internal). One row per work entry in the range, with its expense.
--    p_employee matches surveyor OR assistant. total = rows before paging.
-- =====================================================================================
create or replace function public.rpt_work_rows(
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
  total                bigint,
  sr_no                bigint,
  work_entry_id        uuid,
  code                 text,
  work_date            date,
  work_time            time,
  surveyor_id          uuid,
  surveyor_name        text,
  surveyor_employee_id text,
  designation          text,
  assistant_id         uuid,
  assistant_name       text,
  assistant_employee_id text,
  site_id              uuid,
  site_location        text,
  site_name            text,
  client_name          text,
  expense              bigint,
  site_income          bigint,
  remarks              text
)
language sql
stable
set search_path = public, pg_temp
as $$
  with params as (
    select
      coalesce(nullif(p_status, ''), 'verified')::public.verification_status as st,
      greatest(1, coalesce(p_page, 1)) as pg,
      greatest(1, least(coalesce(p_page_size, 50),
                        case when coalesce(p_for_export, false) then 5000 else 200 end)) as sz
  ),
  base as (
    select
      w.id as work_entry_id, w.code, w.work_date, w.work_time, w.remarks, w.site_id,
      w.surveyor_id, w.assistant_id,
      s.name as surveyor_name, s.employee_id as surveyor_employee_id, s.designation,
      a.name as assistant_name, a.employee_id as assistant_employee_id,
      st.site_location, st.site_name, st.client_name,
      -- expense of this entry: verified rows show verified, pending rows show pending (020 facts)
      (select coalesce(sum(case when p.st = 'verified' then f.verified_amount else f.pending_amount end), 0)
         from public.fin_expense_facts f where f.work_entry_id = w.id)::bigint as expense,
      row_number() over (partition by w.site_id, w.work_date order by w.work_time, w.code) as visit_rank
    from public.work_entries w
    cross join params p
    join public.employees s  on s.id  = w.surveyor_id
    left join public.employees a on a.id = w.assistant_id
    join public.sites st on st.id = w.site_id
    where w.verification_status = p.st
      and w.work_date between p_date_from and p_date_to
      and (p_site        is null or w.site_id = p_site)
      and (p_employee    is null or w.surveyor_id = p_employee or w.assistant_id = p_employee)
      and (p_client      is null or lower(st.client_name) = lower(btrim(p_client)))
      and (p_designation is null or lower(s.designation)  = lower(btrim(p_designation)))
  ),
  numbered as (
    select b.*, count(*) over () as total,
           row_number() over (order by b.work_date, b.work_time, b.code) as rn
    from base b
  )
  select
    n.total, n.rn, n.work_entry_id, n.code, n.work_date, n.work_time,
    n.surveyor_id, n.surveyor_name, n.surveyor_employee_id, n.designation,
    n.assistant_id, n.assistant_name, n.assistant_employee_id,
    n.site_id, n.site_location, n.site_name, n.client_name,
    n.expense,
    case when n.visit_rank = 1
         then (select coalesce(sum(i.received_amount), 0) from public.fin_income_facts i
                where i.site_id = n.site_id and i.fact_date = n.work_date)::bigint
         else 0::bigint end,
    n.remarks
  from numbered n, params p
  where n.rn >  (p.pg - 1) * p.sz
    and n.rn <= (p.pg - 1) * p.sz + p.sz
  order by n.rn
$$;

-- =====================================================================================
-- 3. Report 1: Overall Work/Site Invoice (13.1)
--    Columns: SR NO, DATE, SURVEYOR NAME, ASSISTANT NAME, SITE LOCATION, SITE NAME,
--             CLIENT NAME, SITE EXPENSES, SITE INCOME, REMARKS.
-- =====================================================================================
create or replace function public.report_overall_work_site(
  p_actor_auth_id uuid,
  p_date_from     date,
  p_date_to       date,
  p_employee_id   uuid    default null,
  p_site_id       uuid    default null,
  p_client        text    default null,
  p_designation   text    default null,
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
           'sr_no',         r.sr_no,
           'date',          r.work_date,
           'surveyor_name', r.surveyor_name,
           'assistant_name', r.assistant_name,
           'site_location', r.site_location,
           'site_name',     r.site_name,
           'client_name',   r.client_name,
           'site_expenses', r.expense,
           'site_income',   r.site_income,
           'remarks',       r.remarks) order by r.sr_no), '[]'::jsonb),
         coalesce(max(r.total), 0)
    into v_rows, v_total
  from public.rpt_work_rows(p_date_from, p_date_to, p_site_id, p_employee_id, p_client,
                            p_designation, p_status, p_page, p_page_size, p_for_export) r;

  return jsonb_build_object(
    'meta', jsonb_build_object(
      'report', 'overall_work_site', 'title', 'Overall Work/Site Invoice',
      'date_from', p_date_from, 'date_to', p_date_to,
      'filters', jsonb_build_object('employee_id', p_employee_id, 'site_id', p_site_id,
                                    'client', p_client, 'designation', p_designation),
      'row_status', coalesce(p_status, 'verified'),
      'page', coalesce(p_page, 1), 'page_size', p_page_size, 'total_rows', v_total,
      'for_export', coalesce(p_for_export, false)),
    'rows', v_rows,
    'summary', public.fin_summary(p_site_id, p_employee_id, p_date_from, p_date_to)
               || jsonb_build_object(
                    'pending_work_entries',
                    (select count(*) from public.work_entries w
                      where w.verification_status = 'pending_verification'
                        and w.work_date between p_date_from and p_date_to
                        and (p_site_id is null or w.site_id = p_site_id)
                        and (p_employee_id is null or w.surveyor_id = p_employee_id
                                                    or w.assistant_id = p_employee_id)))
  );
end $$;

-- =====================================================================================
-- 4. Report 2: Personal Employee Work Invoice (13.2)
--    Employee header + Date, Time, Site, Client, Assistant, Expense, Remarks.
-- =====================================================================================
create or replace function public.report_personal_employee_work(
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
           'sr_no',     r.sr_no,
           'date',      r.work_date,
           'time',      to_char(r.work_time, 'HH24:MI'),
           'site_name', r.site_name,
           'site_location', r.site_location,
           'client_name', r.client_name,
           'assistant_name', r.assistant_name,
           'role',      case when r.surveyor_id = p_employee_id then 'surveyor' else 'assistant' end,
           'expense',   case when r.surveyor_id = p_employee_id then r.expense else null end,
           'remarks',   r.remarks) order by r.sr_no), '[]'::jsonb),
         coalesce(max(r.total), 0)
    into v_rows, v_total
  from public.rpt_work_rows(p_date_from, p_date_to, p_site_id, p_employee_id, null,
                            null, p_status, p_page, p_page_size, p_for_export) r;

  return jsonb_build_object(
    'meta', jsonb_build_object(
      'report', 'personal_employee_work', 'title', 'Personal Employee Work Invoice',
      'date_from', p_date_from, 'date_to', p_date_to,
      'employee', jsonb_build_object('id', v_emp.id, 'employee_id', v_emp.employee_id,
                                     'name', v_emp.name, 'designation', v_emp.designation),
      'filters', jsonb_build_object('site_id', p_site_id),
      'row_status', coalesce(p_status, 'verified'),
      'page', coalesce(p_page, 1), 'page_size', p_page_size, 'total_rows', v_total,
      'for_export', coalesce(p_for_export, false)),
    'rows', v_rows,
    'summary', jsonb_build_object(
      'work_entry_count',  public.fin_work_entry_count(p_site_id, p_employee_id, p_date_from, p_date_to),
      'verified_expenses', public.fin_verified_expenses(p_site_id, p_employee_id, p_date_from, p_date_to),
      'pending_expenses',  public.fin_pending_expenses(p_site_id, p_employee_id, p_date_from, p_date_to),
      'pending_work_entries',
        (select count(*) from public.work_entries w
          where w.verification_status = 'pending_verification'
            and w.work_date between p_date_from and p_date_to
            and (p_site_id is null or w.site_id = p_site_id)
            and (w.surveyor_id = p_employee_id or w.assistant_id = p_employee_id)))
  );
end $$;

-- =====================================================================================
-- 5. Report 3: Overall Employee Work Invoice (13.3)
--    Employee, Employee ID, Date, Site, Client, Assistant, Work entry, Expense, Remarks.
-- =====================================================================================
create or replace function public.report_overall_employee_work(
  p_actor_auth_id uuid,
  p_date_from     date,
  p_date_to       date,
  p_employee_id   uuid    default null,
  p_site_id       uuid    default null,
  p_client        text    default null,
  p_designation   text    default null,
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
           'sr_no',          r.sr_no,
           'employee_name',  r.surveyor_name,
           'employee_id',    r.surveyor_employee_id,
           'date',           r.work_date,
           'site_name',      r.site_name,
           'client_name',    r.client_name,
           'assistant_name', r.assistant_name,
           'work_entry',     r.code,
           'expense',        r.expense,
           'remarks',        r.remarks) order by r.sr_no), '[]'::jsonb),
         coalesce(max(r.total), 0)
    into v_rows, v_total
  from public.rpt_work_rows(p_date_from, p_date_to, p_site_id, p_employee_id, p_client,
                            p_designation, p_status, p_page, p_page_size, p_for_export) r;

  return jsonb_build_object(
    'meta', jsonb_build_object(
      'report', 'overall_employee_work', 'title', 'Overall Employee Work Invoice',
      'date_from', p_date_from, 'date_to', p_date_to,
      'filters', jsonb_build_object('employee_id', p_employee_id, 'site_id', p_site_id,
                                    'client', p_client, 'designation', p_designation),
      'row_status', coalesce(p_status, 'verified'),
      'page', coalesce(p_page, 1), 'page_size', p_page_size, 'total_rows', v_total,
      'for_export', coalesce(p_for_export, false)),
    'rows', v_rows,
    'summary', jsonb_build_object(
      'work_entry_count',    public.fin_work_entry_count(p_site_id, p_employee_id, p_date_from, p_date_to),
      'unique_worker_count', public.fin_unique_worker_count(p_site_id, p_date_from, p_date_to),
      'verified_expenses',   public.fin_verified_expenses(p_site_id, p_employee_id, p_date_from, p_date_to),
      'pending_expenses',    public.fin_pending_expenses(p_site_id, p_employee_id, p_date_from, p_date_to),
      'pending_work_entries',
        (select count(*) from public.work_entries w
          where w.verification_status = 'pending_verification'
            and w.work_date between p_date_from and p_date_to
            and (p_site_id is null or w.site_id = p_site_id)
            and (p_employee_id is null or w.surveyor_id = p_employee_id
                                        or w.assistant_id = p_employee_id)))
  );
end $$;

-- =====================================================================================
-- 6. Report 4: Site Invoice (13.4)
--    Site header (site, location, client) + Date, Time, Surveyor, Assistant, Expense, Remarks.
--    Summary: total work entries, unique workers (both from 020), plus expenses and visits.
-- =====================================================================================
create or replace function public.report_site_invoice(
  p_actor_auth_id uuid,
  p_date_from     date,
  p_date_to       date,
  p_site_id       uuid,
  p_designation   text    default null,
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
           'sr_no',          r.sr_no,
           'date',           r.work_date,
           'time',           to_char(r.work_time, 'HH24:MI'),
           'surveyor_name',  r.surveyor_name,
           'assistant_name', r.assistant_name,
           'expense',        r.expense,
           'remarks',        r.remarks) order by r.sr_no), '[]'::jsonb),
         coalesce(max(r.total), 0)
    into v_rows, v_total
  from public.rpt_work_rows(p_date_from, p_date_to, p_site_id, null, null,
                            p_designation, p_status, p_page, p_page_size, p_for_export) r;

  return jsonb_build_object(
    'meta', jsonb_build_object(
      'report', 'site_invoice', 'title', 'Site Invoice',
      'date_from', p_date_from, 'date_to', p_date_to,
      'site', jsonb_build_object('id', v_site.id, 'site_name', v_site.site_name,
                                 'site_location', v_site.site_location,
                                 'client_name', v_site.client_name),
      'filters', jsonb_build_object('designation', p_designation),
      'row_status', coalesce(p_status, 'verified'),
      'page', coalesce(p_page, 1), 'page_size', p_page_size, 'total_rows', v_total,
      'for_export', coalesce(p_for_export, false)),
    'rows', v_rows,
    'summary', jsonb_build_object(
      'total_work_entries', public.fin_work_entry_count(p_site_id, null, p_date_from, p_date_to),
      'unique_workers',     public.fin_unique_worker_count(p_site_id, p_date_from, p_date_to),
      'visit_count',        public.fin_visit_count(p_site_id, p_date_from, p_date_to),
      'verified_expenses',  public.fin_verified_expenses(p_site_id, null, p_date_from, p_date_to),
      'pending_expenses',   public.fin_pending_expenses(p_site_id, null, p_date_from, p_date_to),
      'pending_work_entries',
        (select count(*) from public.work_entries w
          where w.verification_status = 'pending_verification'
            and w.work_date between p_date_from and p_date_to
            and w.site_id = p_site_id))
  );
end $$;

-- =====================================================================================
-- 7. Grants: service_role only (matches 007 / 014). Internal helpers get no grant at all.
-- =====================================================================================
revoke all on function public.rpt_check_request(uuid, date, date, text, boolean, integer, integer)
  from public, anon, authenticated, service_role;
revoke all on function public.rpt_work_rows(date, date, uuid, uuid, text, text, text, integer, integer, boolean)
  from public, anon, authenticated, service_role;

revoke all on function public.report_overall_work_site(uuid, date, date, uuid, uuid, text, text, text, integer, integer, boolean)
  from public, anon, authenticated;
revoke all on function public.report_personal_employee_work(uuid, uuid, date, date, uuid, text, integer, integer, boolean)
  from public, anon, authenticated;
revoke all on function public.report_overall_employee_work(uuid, date, date, uuid, uuid, text, text, text, integer, integer, boolean)
  from public, anon, authenticated;
revoke all on function public.report_site_invoice(uuid, date, date, uuid, text, text, integer, integer, boolean)
  from public, anon, authenticated;

grant execute on function public.report_overall_work_site(uuid, date, date, uuid, uuid, text, text, text, integer, integer, boolean) to service_role;
grant execute on function public.report_personal_employee_work(uuid, uuid, date, date, uuid, text, integer, integer, boolean)      to service_role;
grant execute on function public.report_overall_employee_work(uuid, date, date, uuid, uuid, text, text, text, integer, integer, boolean) to service_role;
grant execute on function public.report_site_invoice(uuid, date, date, uuid, text, text, integer, integer, boolean)               to service_role;