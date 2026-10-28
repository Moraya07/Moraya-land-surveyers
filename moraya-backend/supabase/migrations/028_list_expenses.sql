-- 028_list_expenses.sql
-- PURPOSE   : The admin "Expenses" list. Adds the internal paging helper expenses_page() (also used
--             by 029) and the RPC list_expenses().
-- DEPENDS ON: 008 (moraya_require_actor, moraya_fail), 014 (sites), 015 (work_entries),
--             016 (expenses, expense_categories), 002 (employees).
-- ROLLBACK  : drop function public.list_expenses(uuid, date, date, uuid, uuid, text, text, text, text, integer, integer);
--             drop function public.expenses_page(uuid, text, date, date, uuid, uuid, text, text, text, text, integer, integer);
--             (No data is touched. 029 uses expenses_page: roll 029 back first.)
--
-- WHO MAY CALL : main_admin, or a sub_admin holding 'verification' or 'report_view'.
--                Workers, inactive and revoked accounts get MORAYA_FORBIDDEN.
-- RESPONSE     : {items[], page, page_size, total, totals{status counts}, amounts{status sums in paise}}
--   items[]: id, work_entry_id, work_entry_code, work_entry_version, expense_date, amount (paise),
--            category, category_label, remarks, status, site{id, site_name, site_location, client_name},
--            employee{id, name, employee_id}, cancelled_at, cancel_reason, created_at
--   total   = rows matching ALL filters (including status)
--   totals  = counts per status for the rows matching every filter EXCEPT status
--   amounts = sum of amount (paise) per status, same rows as totals
--   An expense follows its work entry (016), so "status" is the status of its work entry unless the
--   expense was cancelled on its own.
-- FILTERS      : date range on expense_date (inclusive), employee (the surveyor who owns the expense),
--                site, status ('all' or one verification status), category (a code from
--                expense_categories; inactive categories are allowed here because old rows keep them),
--                q (work entry code, remarks, site name, client name, employee name; max 100;
--                % _ and \ are literal).
-- SORT         : '<field>:<asc|desc>', field one of expense_date, amount, created_at, status, category.
--                Default 'expense_date:desc'. Ties by id desc.
-- PAGING       : page 1..100000, page_size capped to 1..100 (default 20). The page size used is returned.
-- ERRORS       : MORAYA_FORBIDDEN, MORAYA_VALIDATION with details
--                'Invalid: status', 'Invalid: category', 'Invalid: sort', 'Invalid: date_range', 'Too long: q'.
-- NOT AUDITED  : reads are not audited.

-- =====================================================================================
-- 1. expenses_page: internal. p_mode 'admin' (any employee, optional employee filter) or
--    'mine' (only the viewer's own expenses; the employee object is left out).
--    Nobody has EXECUTE on it; the two SECURITY DEFINER wrappers (the owner) call it.
-- =====================================================================================
create or replace function public.expenses_page(
  p_viewer_id   uuid,
  p_mode        text,
  p_date_from   date,
  p_date_to     date,
  p_employee_id uuid,
  p_site_id     uuid,
  p_status      text,
  p_category    text,
  p_q           text,
  p_sort        text,
  p_page        integer,
  p_page_size   integer
) returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_status  text := lower(btrim(coalesce(p_status, 'all')));
  v_cat     text := nullif(lower(btrim(coalesce(p_category, ''))), '');
  v_q       text := btrim(coalesce(p_q, ''));
  v_pat     text;
  v_field   text;
  v_dir     text;
  v_order   text;
  v_emp     uuid;
  v_page    int;
  v_size    int;
  v_from    text;
  v_sql     text;
  v_total   bigint;
  v_totals  jsonb;
  v_amounts jsonb;
  v_items   jsonb;
begin
  if v_status not in ('all', 'draft', 'pending_verification', 'verified', 'changes_requested', 'rejected', 'cancelled') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: status');
  end if;
  if v_cat is not null and not exists (select 1 from public.expense_categories c where c.code = v_cat) then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: category');
  end if;
  if p_date_from is not null and p_date_to is not null and p_date_from > p_date_to then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: date_range');
  end if;
  if char_length(v_q) > 100 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too long: q');
  end if;
  if v_q <> '' then
    v_pat := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  v_field := lower(btrim(split_part(coalesce(p_sort, 'expense_date:desc'), ':', 1)));
  v_dir   := lower(btrim(split_part(coalesce(p_sort, 'expense_date:desc'), ':', 2)));
  if v_dir = '' then v_dir := 'asc'; end if;
  if v_dir not in ('asc', 'desc') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: sort');
  end if;
  -- Only these literal fragments and v_dir (asc or desc) are spliced into the SQL text.
  v_order := case v_field
    when 'expense_date' then 'e.expense_date ' || v_dir
    when 'amount'       then 'e.amount ' || v_dir
    when 'created_at'   then 'e.created_at ' || v_dir
    when 'status'       then 'e.verification_status ' || v_dir
    when 'category'     then 'e.category ' || v_dir
    else null end;
  if v_order is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: sort');
  end if;
  v_order := v_order || ', e.id desc';

  v_page := greatest(1, least(coalesce(p_page, 1), 100000));
  v_size := greatest(1, least(coalesce(p_page_size, 20), 100));

  -- Whose expenses: mine -> always the viewer; admin -> the optional employee filter.
  if p_mode = 'mine' then
    v_emp := p_viewer_id;
  else
    v_emp := p_employee_id;
  end if;

  -- Shared FROM + filters (everything except status).
  -- $1 from, $2 to, $3 employee, $4 site, $5 category, $6 search pattern.
  v_from := $f$
      from public.expenses e
      join public.work_entries w       on w.id = e.work_entry_id
      join public.sites s              on s.id = e.site_id
      join public.employees em         on em.id = e.employee_id
      join public.expense_categories c on c.code = e.category
     where ($1::date is null or e.expense_date >= $1)
       and ($2::date is null or e.expense_date <= $2)
       and ($3::uuid is null or e.employee_id = $3)
       and ($4::uuid is null or e.site_id = $4)
       and ($5::text is null or e.category = $5)
       and ($6::text is null or w.code ilike $6 escape '\'
                             or e.remarks ilike $6 escape '\'
                             or s.site_name ilike $6 escape '\'
                             or s.client_name ilike $6 escape '\'
                             or em.name ilike $6 escape '\')
  $f$;

  -- Counts and sums. $7 status.
  v_sql := 'select count(*) filter (where $7::text = ''all'' or e.verification_status::text = $7::text),
                   jsonb_build_object(
                     ''draft'',                count(*) filter (where e.verification_status = ''draft''),
                     ''pending_verification'', count(*) filter (where e.verification_status = ''pending_verification''),
                     ''verified'',             count(*) filter (where e.verification_status = ''verified''),
                     ''changes_requested'',    count(*) filter (where e.verification_status = ''changes_requested''),
                     ''rejected'',             count(*) filter (where e.verification_status = ''rejected''),
                     ''cancelled'',            count(*) filter (where e.verification_status = ''cancelled'')),
                   jsonb_build_object(
                     ''draft'',                coalesce(sum(e.amount) filter (where e.verification_status = ''draft''), 0)::bigint,
                     ''pending_verification'', coalesce(sum(e.amount) filter (where e.verification_status = ''pending_verification''), 0)::bigint,
                     ''verified'',             coalesce(sum(e.amount) filter (where e.verification_status = ''verified''), 0)::bigint,
                     ''changes_requested'',    coalesce(sum(e.amount) filter (where e.verification_status = ''changes_requested''), 0)::bigint,
                     ''rejected'',             coalesce(sum(e.amount) filter (where e.verification_status = ''rejected''), 0)::bigint,
                     ''cancelled'',            coalesce(sum(e.amount) filter (where e.verification_status = ''cancelled''), 0)::bigint) '
           || v_from;
  execute v_sql
    into v_total, v_totals, v_amounts
    using p_date_from, p_date_to, v_emp, p_site_id, v_cat, v_pat, v_status;

  -- Page. $8 limit, $9 offset, $10 admin mode (adds the employee object).
  v_sql := 'select coalesce(jsonb_agg(
              jsonb_build_object(
                ''id'', p.id, ''work_entry_id'', p.work_entry_id, ''work_entry_code'', p.code,
                ''work_entry_version'', p.version, ''expense_date'', p.expense_date, ''amount'', p.amount,
                ''category'', p.category, ''category_label'', p.category_label, ''remarks'', p.remarks,
                ''status'', p.verification_status,
                ''site'', jsonb_build_object(''id'', p.site_id, ''site_name'', p.site_name,
                                            ''site_location'', p.site_location, ''client_name'', p.client_name),
                ''cancelled_at'', p.cancelled_at, ''cancel_reason'', p.cancel_reason, ''created_at'', p.created_at)
              || case when $10 then jsonb_build_object(''employee'',
                        jsonb_build_object(''id'', p.employee_id, ''name'', p.employee_name,
                                           ''employee_id'', p.employee_code))
                      else ''{}''::jsonb end
              order by p.rn), ''[]''::jsonb)
            from (
              select row_number() over (order by ' || v_order || ') as rn,
                     e.id, e.work_entry_id, w.code, w.version, e.expense_date, e.amount, e.category,
                     c.label as category_label, e.remarks, e.verification_status,
                     e.site_id, s.site_name, s.site_location, s.client_name,
                     e.employee_id, em.name as employee_name, em.employee_id as employee_code,
                     e.cancelled_at, e.cancel_reason, e.created_at '
            || v_from
            || ' and ($7::text = ''all'' or e.verification_status::text = $7::text)
                 order by ' || v_order || '
                 limit $8 offset $9) p';
  execute v_sql
    into v_items
    using p_date_from, p_date_to, v_emp, p_site_id, v_cat, v_pat, v_status,
          v_size, (v_page - 1) * v_size, (p_mode = 'admin');

  return jsonb_build_object(
    'items',     v_items,
    'page',      v_page,
    'page_size', v_size,
    'total',     v_total,
    'totals',    v_totals,
    'amounts',   v_amounts
  );
end $$;

revoke all on function public.expenses_page(uuid, text, date, date, uuid, uuid, text, text, text, text, integer, integer)
  from public, anon, authenticated, service_role;

-- =====================================================================================
-- 2. list_expenses (admin)
-- =====================================================================================
create or replace function public.list_expenses(
  p_actor_auth_id uuid,
  p_date_from     date    default null,
  p_date_to       date    default null,
  p_employee_id   uuid    default null,
  p_site_id       uuid    default null,
  p_status        text    default 'all',
  p_category      text    default null,
  p_q             text    default null,
  p_sort          text    default 'expense_date:desc',
  p_page          integer default 1,
  p_page_size     integer default 20
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor public.employees;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['verification', 'report_view']);
  return public.expenses_page(v_actor.id, 'admin', p_date_from, p_date_to, p_employee_id, p_site_id,
                              p_status, p_category, p_q, p_sort, p_page, p_page_size);
end $$;

revoke all on function public.list_expenses(uuid, date, date, uuid, uuid, text, text, text, text, integer, integer)
  from public, anon, authenticated;
grant execute on function public.list_expenses(uuid, date, date, uuid, uuid, text, text, text, text, integer, integer)
  to service_role;