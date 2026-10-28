-- 026_audit_queries_and_hardening.sql
-- PURPOSE   : 1. Audit log screen: list_audit_logs and get_audit_log (main_admin only).
--             2. Hardening: make sure every financial table blocks DELETE and TRUNCATE (adds any
--                that are missing), add the CHECK constraints that were still missing, and add the
--                few indexes the 020-025 queries need.
-- DEPENDS ON: 004/008 (audit_logs, audit_actions, audit_scrub, moraya_require_actor, moraya_fail),
--             014-025 (the tables checked below).
-- ROLLBACK  : drop function public.get_audit_log(uuid, bigint);
--             drop function public.list_audit_logs(uuid, date, date, uuid, text, text, text, text, text, integer, integer);
--             drop index if exists public.expenses_created_idx;
--             drop index if exists public.audit_logs_actor_created_idx;
--             drop index if exists public.work_entries_surveyor_submitted_idx;
--             drop index if exists public.work_entries_verified_site_date_idx;
--             alter table public.work_entry_history drop constraint if exists work_entry_history_checks;
--             alter table public.salary_history     drop constraint if exists salary_history_checks;
--             alter table public.expense_history    drop constraint if exists expense_history_checks;
--             (the delete-blocking triggers added in section 3 are kept on purpose; to remove one:
--              drop trigger <table>_no_delete / <table>_no_truncate on the table, then
--              drop function public.moraya_block_delete();)
--
-- ASSUMPTIONS (please confirm)
--   F1. Audit logs are readable by the ACTIVE main_admin only (not by sub_admins), as asked. Reading the
--       audit log is not itself audited (it would write a row per page view).
--   F2. The list returns summaries only (plain English). old_value / new_value (already scrubbed when
--       written) are returned only by get_audit_log, and are scrubbed AGAIN on the way out, so a secret
--       that somehow got stored is still hidden. ip and user_agent are returned only by get_audit_log.
--   F3. Date filters are inclusive calendar days in Asia/Kolkata, applied to created_at.
--   F4. Indexes are created without CONCURRENTLY (not allowed inside a migration transaction). On a big
--       live table, create them by hand with CONCURRENTLY first; "if not exists" then skips them.
--   F5. The two NOT VALID constraints on audit_logs (action format, summary length) are validated here
--       when the existing rows allow it; if an old row violates them the migration only prints a
--       NOTICE and leaves them NOT VALID (new rows are always checked). Audit rows are never edited.
--
-- ERROR CODES: MORAYA_FORBIDDEN, MORAYA_VALIDATION, MORAYA_NOT_FOUND

-- =====================================================================================
-- 1. list_audit_logs
--    p_date_from / p_date_to   inclusive days (IST); both optional, but from <= to when both given
--    p_actor_employee_id       who did it
--    p_action                  exact action name, e.g. 'INCOME_CANCELLED' (must exist in audit_actions)
--    p_category                'auth' | 'account' | 'site' | 'income' | ... (audit_actions.category)
--    p_entity_type / p_entity_id  exact match
--    p_q                       search in the summary and reason (max 100; % _ and \ are literal)
--    p_page 1 and up; p_page_size capped 1..100 (default 25). Newest first.
--    Returns {items[], page, page_size, total}
--      items[]: id, created_at, actor{id, name, employee_id}, action, action_label, category,
--               entity_type, entity_id, summary (falls back to the action label), reason, request_id
--    Errors: MORAYA_FORBIDDEN, MORAYA_VALIDATION
-- =====================================================================================
create or replace function public.list_audit_logs(
  p_actor_auth_id     uuid,
  p_date_from         date    default null,
  p_date_to           date    default null,
  p_actor_employee_id uuid    default null,
  p_action            text    default null,
  p_category          text    default null,
  p_entity_type       text    default null,
  p_entity_id         text    default null,
  p_q                 text    default null,
  p_page              integer default 1,
  p_page_size         integer default 25
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_page   integer := greatest(1, least(coalesce(p_page, 1), 100000));
  v_size   integer := greatest(1, least(coalesce(p_page_size, 25), 100));
  v_q      text    := btrim(coalesce(p_q, ''));
  v_pat    text;
  v_from   timestamptz;
  v_to     timestamptz;
  v_total  bigint;
  v_items  jsonb;
begin
  perform public.moraya_require_actor(p_actor_auth_id, true, null);

  if p_date_from is not null and p_date_to is not null and p_date_from > p_date_to then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: date range');
  end if;
  if char_length(v_q) > 100 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too long: q');
  end if;
  if p_action is not null and not exists (select 1 from public.audit_actions a where a.action = p_action) then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: action');
  end if;
  if char_length(coalesce(p_category, '')) > 40 or char_length(coalesce(p_entity_type, '')) > 60
     or char_length(coalesce(p_entity_id, '')) > 100 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too long: filter');
  end if;

  if v_q <> '' then
    v_pat := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;
  if p_date_from is not null then
    v_from := p_date_from::timestamp at time zone 'Asia/Kolkata';
  end if;
  if p_date_to is not null then
    v_to := (p_date_to + 1)::timestamp at time zone 'Asia/Kolkata';
  end if;

  select count(*) into v_total
  from public.audit_logs l
  left join public.audit_actions aa on aa.action = l.action
  where (v_from is null or l.created_at >= v_from)
    and (v_to   is null or l.created_at <  v_to)
    and (p_actor_employee_id is null or l.actor_employee_id = p_actor_employee_id)
    and (p_action      is null or l.action = p_action)
    and (p_category    is null or aa.category = p_category)
    and (p_entity_type is null or l.entity_type = p_entity_type)
    and (p_entity_id   is null or l.entity_id = p_entity_id)
    and (v_pat is null or l.summary ilike v_pat escape '\' or l.reason ilike v_pat escape '\');

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id, 'created_at', x.created_at,
           'actor', case when x.actor_employee_id is null then null
                         else jsonb_build_object('id', x.actor_employee_id, 'name', x.actor_name,
                                                 'employee_id', x.actor_code) end,
           'action', x.action, 'action_label', x.description, 'category', x.category,
           'entity_type', x.entity_type, 'entity_id', x.entity_id,
           'summary', coalesce(x.summary, x.description, x.action),
           'reason', x.reason, 'request_id', x.request_id)
           order by x.created_at desc, x.id desc), '[]'::jsonb)
    into v_items
  from (
    select l.id, l.created_at, l.actor_employee_id, e.name as actor_name, e.employee_id as actor_code,
           l.action, aa.description, aa.category, l.entity_type, l.entity_id, l.summary, l.reason, l.request_id
    from public.audit_logs l
    left join public.audit_actions aa on aa.action = l.action
    left join public.employees e on e.id = l.actor_employee_id
    where (v_from is null or l.created_at >= v_from)
      and (v_to   is null or l.created_at <  v_to)
      and (p_actor_employee_id is null or l.actor_employee_id = p_actor_employee_id)
      and (p_action      is null or l.action = p_action)
      and (p_category    is null or aa.category = p_category)
      and (p_entity_type is null or l.entity_type = p_entity_type)
      and (p_entity_id   is null or l.entity_id = p_entity_id)
      and (v_pat is null or l.summary ilike v_pat escape '\' or l.reason ilike v_pat escape '\')
    order by l.created_at desc, l.id desc
    limit v_size offset (v_page - 1) * v_size
  ) x;

  return jsonb_build_object('items', v_items, 'page', v_page, 'page_size', v_size, 'total', v_total);
end $$;

-- =====================================================================================
-- 2. get_audit_log
--    One entry in full: the list fields plus old_value, new_value (scrubbed again), ip, user_agent.
--    Returns {entry}. Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND
-- =====================================================================================
create or replace function public.get_audit_log(
  p_actor_auth_id uuid,
  p_id            bigint
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb;
begin
  perform public.moraya_require_actor(p_actor_auth_id, true, null);

  select jsonb_build_object(
           'id', l.id, 'created_at', l.created_at,
           'actor', case when l.actor_employee_id is null then null
                         else jsonb_build_object('id', l.actor_employee_id, 'name', e.name,
                                                 'employee_id', e.employee_id) end,
           'action', l.action, 'action_label', aa.description, 'category', aa.category,
           'entity_type', l.entity_type, 'entity_id', l.entity_id,
           'summary', coalesce(l.summary, aa.description, l.action),
           'reason', l.reason, 'request_id', l.request_id,
           'old_value', public.audit_scrub(l.old_value),
           'new_value', public.audit_scrub(l.new_value),
           'ip', host(l.ip), 'user_agent', left(l.user_agent, 300))
    into v
  from public.audit_logs l
  left join public.audit_actions aa on aa.action = l.action
  left join public.employees e on e.id = l.actor_employee_id
  where l.id = p_id;

  if v is null then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Audit entry not found');
  end if;
  return jsonb_build_object('entry', v);
end $$;

revoke all on function public.list_audit_logs(uuid, date, date, uuid, text, text, text, text, text, integer, integer) from public, anon, authenticated;
revoke all on function public.get_audit_log(uuid, bigint)                                                            from public, anon, authenticated;
grant execute on function public.list_audit_logs(uuid, date, date, uuid, text, text, text, text, text, integer, integer) to service_role;
grant execute on function public.get_audit_log(uuid, bigint)                                                            to service_role;

-- =====================================================================================
-- 3. Financial tables: DELETE and TRUNCATE must be blocked
--    Checked tables: work_entries, expenses, income_transactions, salary_records, client_bills
--    (plus the history tables and the audit log). 014-019, 024 already add the triggers; this block
--    verifies that, and adds a generic blocker only where one is missing (so running it on a
--    database where a file was skipped still ends up safe). Each fix prints a NOTICE; a normal run
--    prints none.
-- =====================================================================================
create or replace function public.moraya_block_delete() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception using errcode = 'P0001', message = 'MORAYA_INVALID_STATE',
    detail = 'Financial records cannot be deleted; cancel or correct them instead';
end $$;
revoke all on function public.moraya_block_delete() from public, anon, authenticated, service_role;

do $$
declare
  t text;
  v_tables text[] := array['work_entries', 'expenses', 'income_transactions', 'salary_records',
                           'client_bills', 'work_entry_history', 'expense_history', 'salary_history',
                           'audit_logs'];
begin
  foreach t in array v_tables loop
    if to_regclass('public.' || t) is null then
      continue;   -- table not created yet (earlier file skipped): nothing to protect
    end if;

    -- row-level BEFORE DELETE trigger present?
    if not exists (select 1 from pg_trigger g
                    where g.tgrelid = ('public.' || t)::regclass and not g.tgisinternal
                      and (g.tgtype & 1) = 1      -- row level
                      and (g.tgtype & 2) = 2      -- BEFORE
                      and (g.tgtype & 8) = 8) then -- DELETE
      execute format('create trigger %I before delete on public.%I for each row execute function public.moraya_block_delete()',
                     t || '_no_delete_026', t);
      raise notice 'Added missing DELETE blocker on %', t;
    end if;

    -- statement-level BEFORE TRUNCATE trigger present?
    if not exists (select 1 from pg_trigger g
                    where g.tgrelid = ('public.' || t)::regclass and not g.tgisinternal
                      and (g.tgtype & 1) = 0      -- statement level
                      and (g.tgtype & 2) = 2      -- BEFORE
                      and (g.tgtype & 32) = 32) then -- TRUNCATE
      execute format('create trigger %I before truncate on public.%I for each statement execute function public.moraya_block_delete()',
                     t || '_no_truncate_026', t);
      raise notice 'Added missing TRUNCATE blocker on %', t;
    end if;

    -- no DELETE / TRUNCATE privilege for the API roles (007 pattern); owner/superuser still blocked by the trigger
    execute format('revoke delete, truncate on public.%I from public, anon, authenticated, service_role', t);
  end loop;
end $$;

-- =====================================================================================
-- 4. CHECK constraints that were still missing
--    Review result: the live tables (work_entries, expenses, income_transactions, salary_records,
--    client_bills, sites, app_settings, counters) already have amount, status, date, length and
--    consistency checks (statuses are enums, so no free text status exists). The gaps were the
--    history copies, which only had an event check. They get the same money and date rules as their
--    source tables. Added NOT VALID then validated, so they also prove the existing rows are clean.
-- =====================================================================================
do $$
begin
  if to_regclass('public.expense_history') is not null
     and not exists (select 1 from pg_constraint where conname = 'expense_history_checks') then
    alter table public.expense_history add constraint expense_history_checks check (
      amount > 0 and amount <= 1000000000000 and work_entry_version >= 1) not valid;
    alter table public.expense_history validate constraint expense_history_checks;
  end if;

  if to_regclass('public.salary_history') is not null
     and not exists (select 1 from pg_constraint where conname = 'salary_history_checks') then
    alter table public.salary_history add constraint salary_history_checks check (
      amount > 0 and amount <= 1000000000000 and paid_amount >= 0 and paid_amount <= amount
      and period_end >= period_start and version >= 1) not valid;
    alter table public.salary_history validate constraint salary_history_checks;
  end if;

  if to_regclass('public.work_entry_history') is not null
     and not exists (select 1 from pg_constraint where conname = 'work_entry_history_checks') then
    alter table public.work_entry_history add constraint work_entry_history_checks check (
      version >= 1 and (assistant_id is null or assistant_id <> surveyor_id)) not valid;
    alter table public.work_entry_history validate constraint work_entry_history_checks;
  end if;

  -- 004 left two audit_logs checks NOT VALID; validate them if the old rows allow it (F5).
  if to_regclass('public.audit_logs') is not null then
    begin
      alter table public.audit_logs validate constraint audit_logs_action_format;
      alter table public.audit_logs validate constraint audit_logs_summary_len;
    exception when others then
      raise notice 'audit_logs checks left NOT VALID (old rows do not satisfy them): %', sqlerrm;
    end;
  end if;
end $$;

-- =====================================================================================
-- 5. Indexes for the queries added in 020-026 (one line each: why)
--    Existing indexes already cover the date / site / employee / status filters of 014-019, so
--    only the gaps are added.
-- =====================================================================================
-- 020 facts, reports 021-023, client bill 024: every "verified work" query filters on site + date.
-- Partial (verified only) keeps it small; INCLUDE lets visit / worker counts avoid the table.
create index if not exists work_entries_verified_site_date_idx
  on public.work_entries (site_id, work_date) include (surveyor_id, assistant_id)
  where verification_status = 'verified';

-- 025 worker dashboard: "my recent submissions" = own entries, newest submitted first.
create index if not exists work_entries_surveyor_submitted_idx
  on public.work_entries (surveyor_id, submitted_at desc nulls last)
  where verification_status <> 'draft';

-- 026 audit screen filtered by one person, newest first (the old actor index has no date).
create index if not exists audit_logs_actor_created_idx
  on public.audit_logs (actor_employee_id, created_at desc, id desc);

-- 025 admin dashboard "recent expenses": newest first without scanning the whole table.
create index if not exists expenses_created_idx
  on public.expenses (created_at desc, id);