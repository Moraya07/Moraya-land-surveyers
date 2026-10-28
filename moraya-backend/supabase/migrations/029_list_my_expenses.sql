-- 029_list_my_expenses.sql
-- PURPOSE   : The worker's own expenses list (RPC list_my_expenses).
-- DEPENDS ON: 008 (moraya_require_actor), 016 (expenses), 028 (expenses_page).
-- ROLLBACK  : drop function public.list_my_expenses(uuid, date, date, uuid, text, text, text, text, integer, integer);
--
-- WHO MAY CALL : any ACTIVE employee (any role). The rows are always the CALLER's own expenses.
--   An expense is owned by the surveyor of its work entry (016 enforces this), so an employee who was
--   only the ASSISTANT on an entry never sees that entry's expense: not its amount, not its row.
--   An admin who calls this sees only the expenses they submitted as a surveyor; the all-employees view
--   is list_expenses (028).
-- RESPONSE     : same as list_expenses (028) except the items have NO employee object.
--   {items[], page, page_size, total, totals{status counts}, amounts{status sums in paise}}
-- FILTERS      : date range, site, status, category, q (same rules as 028). No employee filter.
-- SORT/PAGING  : same whitelist and caps as 028 (page_size capped to 1..100, default 20).
-- ERRORS       : MORAYA_FORBIDDEN, MORAYA_VALIDATION (same details as 028).
create or replace function public.list_my_expenses(
  p_actor_auth_id uuid,
  p_date_from     date    default null,
  p_date_to       date    default null,
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
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, null);
  return public.expenses_page(v_actor.id, 'mine', p_date_from, p_date_to, null, p_site_id,
                              p_status, p_category, p_q, p_sort, p_page, p_page_size);
end $$;

revoke all on function public.list_my_expenses(uuid, date, date, uuid, text, text, text, text, integer, integer)
  from public, anon, authenticated;
grant execute on function public.list_my_expenses(uuid, date, date, uuid, text, text, text, text, integer, integer)
  to service_role;