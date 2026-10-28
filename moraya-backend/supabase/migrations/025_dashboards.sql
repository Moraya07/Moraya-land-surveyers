-- 025_dashboards.sql
-- PURPOSE   : One call per dashboard (Frontend Rules sections 7 and 20):
--               get_admin_dashboard(actor, date_from, date_to, recent)
--               get_worker_dashboard(actor, recent)
--             Plus the internal helper dash_allowed().
-- DEPENDS ON: 002, 003 (sub_admin_permissions), 008 (moraya_require_actor, moraya_fail),
--             010 (app_settings.workers_can_see_salary), 014 (sites), 015 (work_entries),
--             016 (expenses), 020 (fin_* formulas and fact views: EVERY money figure and every
--             work/expense count comes from there).
-- ROLLBACK  : drop function public.get_worker_dashboard(uuid, integer);
--             drop function public.get_admin_dashboard(uuid, date, date, integer);
--             drop function public.dash_allowed(public.employees, text[]);
--
-- PERFORMANCE: each dashboard is one function call, no loops and no per-row function calls.
--   The short lists are one query each with a LIMIT (p_recent, 1..20, default 5), so result size is
--   small and fixed. Money figures are the 020 scalar functions (one aggregate each).
--
-- WHO MAY CALL
--   get_admin_dashboard : an ACTIVE main_admin or sub_admin. Workers get MORAYA_FORBIDDEN.
--     Each SECTION is returned only when the caller may see that data; otherwise the key is null:
--       employees / sites          : employee_management / site_management
--       income figures             : income_management or report_view
--       expense figures, pending verification count and lists (work, expenses): verification or report_view
--       salary figures             : salary_management or report_view
--       balances                   : report_view (they combine income, expenses and salary)
--     main_admin sees everything.
--   get_worker_dashboard : any ACTIVE user (normally a worker). Shows only the caller's own data.
--
-- PERIOD (admin): date_from / date_to apply to the MONEY figures and the work/expense lists only
--   (counts like active employees, active sites and pending verification are "right now").
--   If both are omitted the period is the current calendar month in Asia/Kolkata. Giving only one is
--   MORAYA_VALIDATION. The period used is returned in meta.
--   Worker figures are all-time.
--
-- ASSUMPTIONS (please confirm)
--   E1. "Active Employees" = every active account (workers and admins).
--   E2. Admin money figures default to the current month (see above); pass explicit dates for any other
--       period, e.g. a whole financial year.
--   E3. Admin lists: pending_verification = oldest submitted first (what to review next);
--       recent_work = latest non-draft work entries by work date/time; recent_expenses = latest
--       verified or pending expenses by entry time.
--       The workflow also mentions recent income, pending salaries and employee activity: left out of this
--       file to keep the dashboard small (Frontend Rules 20); they are one more list each if wanted.
--   E4. Worker "My Work" = verified entries where the caller is surveyor OR assistant (020 definition);
--       "My Sites" = distinct sites on those entries. Pending submissions, changes requested and
--       recent submissions are the caller's own entries as SURVEYOR. Expense amounts are the caller's
--       own and never shown for entries where the caller was only the assistant.
--   E5. Worker salary: only when workers_can_see_salary is true; otherwise salary is null and
--       salary_visible is false (the dashboard does not fail).
--   E6. Reading is not audited.
--
-- ERROR CODES: MORAYA_FORBIDDEN, MORAYA_VALIDATION

-- =====================================================================================
-- 1. dash_allowed (internal): main_admin always; a sub_admin if they hold ANY listed permission.
-- =====================================================================================
create or replace function public.dash_allowed(p_actor public.employees, p_perms text[])
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select p_actor.role = 'main_admin'
      or (p_actor.role = 'sub_admin'
          and exists (select 1 from public.sub_admin_permissions sp
                       where sp.employee_id = p_actor.id and sp.permission = any (p_perms)))
$$;
revoke all on function public.dash_allowed(public.employees, text[]) from public, anon, authenticated, service_role;

-- =====================================================================================
-- 2. get_admin_dashboard
--    Returns {
--      meta{date_from, date_to, generated_at},
--      counts{active_employees, active_sites, pending_verification},     (each null if not allowed)
--      income{received_income, pending_income},
--      expenses{verified_expenses, pending_expenses},
--      salary{paid_salary, pending_salary},
--      balances{operating_balance, after_salary_balance, salary_scope},
--      recent_work[], pending_verification[], recent_expenses[] }          (each null if not allowed)
--    Money in paise.
-- =====================================================================================
create or replace function public.get_admin_dashboard(
  p_actor_auth_id uuid,
  p_date_from     date    default null,
  p_date_to       date    default null,
  p_recent        integer default 5
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  public.employees;
  v_today  date := (now() at time zone 'Asia/Kolkata')::date;
  v_from   date := p_date_from;
  v_to     date := p_date_to;
  v_n      integer := greatest(1, least(coalesce(p_recent, 5), 20));
  v_sum    jsonb;
  v_can_emp  boolean;  v_can_site boolean;  v_can_ver boolean;
  v_can_inc  boolean;  v_can_sal  boolean;  v_can_rep boolean;
  v_counts   jsonb := '{}'::jsonb;
  v_pending  jsonb;
  v_recent   jsonb;
  v_exp      jsonb;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, null);
  if v_actor.role not in ('main_admin', 'sub_admin') then
    perform public.moraya_fail('MORAYA_FORBIDDEN');
  end if;

  if (v_from is null) <> (v_to is null) or (v_from is not null and v_from > v_to) then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: date range');
  end if;
  if v_from is null then
    v_from := date_trunc('month', v_today)::date;
    v_to   := (date_trunc('month', v_today) + interval '1 month - 1 day')::date;
  end if;
  if v_to - v_from > 3660 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: date range');
  end if;

  v_can_emp  := public.dash_allowed(v_actor, array['employee_management']);
  v_can_site := public.dash_allowed(v_actor, array['site_management']);
  v_can_ver  := public.dash_allowed(v_actor, array['verification', 'report_view']);
  v_can_inc  := public.dash_allowed(v_actor, array['income_management', 'report_view']);
  v_can_sal  := public.dash_allowed(v_actor, array['salary_management', 'report_view']);
  v_can_rep  := public.dash_allowed(v_actor, array['report_view']);

  v_sum := public.fin_summary(null, null, v_from, v_to);

  -- Pending verification: oldest first (what to review next).
  if v_can_ver then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', q.id, 'code', q.code, 'work_date', q.work_date, 'work_time', to_char(q.work_time, 'HH24:MI'),
             'site_name', q.site_name, 'surveyor_name', q.surveyor_name, 'assistant_name', q.assistant_name,
             'expense', q.expense, 'submitted_at', q.submitted_at) order by q.submitted_at, q.code), '[]'::jsonb)
      into v_pending
    from (
      select w.id, w.code, w.work_date, w.work_time, s.site_name, sv.name as surveyor_name,
             a.name as assistant_name, w.submitted_at,
             coalesce((select sum(f.pending_amount) from public.fin_expense_facts f where f.work_entry_id = w.id), 0)::bigint as expense
      from public.work_entries w
      join public.sites s on s.id = w.site_id
      join public.employees sv on sv.id = w.surveyor_id
      left join public.employees a on a.id = w.assistant_id
      where w.verification_status = 'pending_verification'
      order by w.submitted_at, w.code
      limit v_n
    ) q;

    select coalesce(jsonb_agg(jsonb_build_object(
             'id', q.id, 'code', q.code, 'work_date', q.work_date, 'work_time', to_char(q.work_time, 'HH24:MI'),
             'site_name', q.site_name, 'surveyor_name', q.surveyor_name, 'assistant_name', q.assistant_name,
             'status', q.status, 'expense', q.expense)
             order by q.work_date desc, q.work_time desc, q.code desc), '[]'::jsonb)
      into v_recent
    from (
      select w.id, w.code, w.work_date, w.work_time, s.site_name, sv.name as surveyor_name,
             a.name as assistant_name, w.verification_status::text as status,
             coalesce((select sum(f.verified_amount + f.pending_amount) from public.fin_expense_facts f
                        where f.work_entry_id = w.id), 0)::bigint as expense
      from public.work_entries w
      join public.sites s on s.id = w.site_id
      join public.employees sv on sv.id = w.surveyor_id
      left join public.employees a on a.id = w.assistant_id
      where w.verification_status <> 'draft'
        and w.work_date between v_from and v_to
      order by w.work_date desc, w.work_time desc, w.code desc
      limit v_n
    ) q;

    select coalesce(jsonb_agg(jsonb_build_object(
             'id', q.expense_id, 'date', q.fact_date, 'employee_name', q.employee_name,
             'site_name', q.site_name, 'amount', q.amount, 'status', q.status)
             order by q.created_at desc, q.expense_id), '[]'::jsonb)
      into v_exp
    from (
      select f.expense_id, f.fact_date, e.name as employee_name, s.site_name, x.created_at,
             (f.verified_amount + f.pending_amount) as amount,
             case when f.verified_amount > 0 then 'verified' else 'pending_verification' end as status
      from public.fin_expense_facts f
      join public.expenses x  on x.id = f.expense_id
      join public.employees e on e.id = f.employee_id
      join public.sites s     on s.id = f.site_id
      where f.fact_date between v_from and v_to
      order by x.created_at desc, f.expense_id
      limit v_n
    ) q;
  end if;

  return jsonb_build_object(
    'meta', jsonb_build_object('date_from', v_from, 'date_to', v_to, 'generated_at', now()),
    'counts', jsonb_build_object(
        'active_employees', case when v_can_emp
            then (select count(*) from public.employees e where e.account_status = 'active') end,
        'active_sites', case when v_can_site
            then (select count(*) from public.sites s where s.status = 'active') end,
        'pending_verification', case when v_can_ver
            then (select count(*) from public.work_entries w where w.verification_status = 'pending_verification') end),
    'income', case when v_can_inc then jsonb_build_object(
        'received_income', v_sum -> 'received_income', 'pending_income', v_sum -> 'pending_income') end,
    'expenses', case when v_can_ver then jsonb_build_object(
        'verified_expenses', v_sum -> 'verified_expenses', 'pending_expenses', v_sum -> 'pending_expenses') end,
    'salary', case when v_can_sal then jsonb_build_object(
        'paid_salary', v_sum -> 'paid_salary', 'pending_salary', v_sum -> 'pending_salary') end,
    'balances', case when v_can_rep then jsonb_build_object(
        'operating_balance', v_sum -> 'operating_balance',
        'after_salary_balance', v_sum -> 'after_salary_balance',
        'salary_scope', 'all') end,
    'recent_work',          case when v_can_ver then v_recent end,
    'pending_verification', case when v_can_ver then v_pending end,
    'recent_expenses',      case when v_can_ver then v_exp end
  );
end $$;

-- =====================================================================================
-- 3. get_worker_dashboard
--    Returns {
--      meta{generated_at},
--      my_work_count, my_sites_count,
--      pending_submissions, changes_requested,
--      my_expenses{verified, pending},
--      recent_submissions[]{id, code, work_date, work_time, site_name, assistant_name, status,
--                           review_reason (changes_requested / rejected only), expense},
--      salary_visible, salary{paid_salary, pending_salary} | null }
-- =====================================================================================
create or replace function public.get_worker_dashboard(
  p_actor_auth_id uuid,
  p_recent        integer default 5
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  public.employees;
  v_n      integer := greatest(1, least(coalesce(p_recent, 5), 20));
  v_flag   boolean;
  v_recent jsonb;
  v_pend   bigint;
  v_chg    bigint;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, null);

  select a.workers_can_see_salary into v_flag from public.app_settings a where a.id = 1;

  select count(*) filter (where w.verification_status = 'pending_verification'),
         count(*) filter (where w.verification_status = 'changes_requested')
    into v_pend, v_chg
  from public.work_entries w
  where w.surveyor_id = v_actor.id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', q.id, 'code', q.code, 'work_date', q.work_date, 'work_time', to_char(q.work_time, 'HH24:MI'),
           'site_name', q.site_name, 'assistant_name', q.assistant_name, 'status', q.status,
           'review_reason', q.review_reason, 'expense', q.expense)
           order by q.submitted_at desc, q.code desc), '[]'::jsonb)
    into v_recent
  from (
    select w.id, w.code, w.work_date, w.work_time, s.site_name, a.name as assistant_name,
           w.verification_status::text as status, w.submitted_at,
           case when w.verification_status in ('changes_requested', 'rejected') then w.review_reason end as review_reason,
           coalesce((select sum(f.verified_amount + f.pending_amount) from public.fin_expense_facts f
                      where f.work_entry_id = w.id), 0)::bigint as expense
    from public.work_entries w
    join public.sites s on s.id = w.site_id
    left join public.employees a on a.id = w.assistant_id
    where w.surveyor_id = v_actor.id
      and w.verification_status <> 'draft'
    order by w.submitted_at desc nulls last, w.code desc
    limit v_n
  ) q;

  return jsonb_build_object(
    'meta', jsonb_build_object('generated_at', now()),
    'my_work_count',       public.fin_work_entry_count(null, v_actor.id, null, null),
    'my_sites_count',      public.fin_employee_site_count(v_actor.id, null, null),
    'pending_submissions', v_pend,
    'changes_requested',   v_chg,
    'my_expenses', jsonb_build_object(
        'verified', public.fin_verified_expenses(null, v_actor.id, null, null),
        'pending',  public.fin_pending_expenses(null, v_actor.id, null, null)),
    'recent_submissions',  v_recent,
    'salary_visible',      coalesce(v_flag, false),
    'salary', case when v_flag is true then jsonb_build_object(
        'paid_salary',    public.fin_paid_salary(v_actor.id, null, null),
        'pending_salary', public.fin_pending_salary(v_actor.id, null, null)) end
  );
end $$;

-- =====================================================================================
-- 4. Grants: service_role only (matches 007 / 014)
-- =====================================================================================
revoke all on function public.get_admin_dashboard(uuid, date, date, integer)  from public, anon, authenticated;
revoke all on function public.get_worker_dashboard(uuid, integer)             from public, anon, authenticated;
grant execute on function public.get_admin_dashboard(uuid, date, date, integer) to service_role;
grant execute on function public.get_worker_dashboard(uuid, integer)            to service_role;