-- 031_list_employee_activity.sql
-- PURPOSE   : The "Activity" tab of the employee detail page (RPC list_employee_activity), plus the internal
--             helper employee_activity_changes().
-- DEPENDS ON: 004/008 (audit_logs, audit_actions, audit_scrub, moraya_require_actor, moraya_fail),
--             002 (employees), 013 (the audit rows it reads: USER_*, SUBADMIN_*, AADHAAR_REVEALED).
-- ROLLBACK  : drop function public.list_employee_activity(uuid, uuid, integer, integer);
--             drop function public.employee_activity_changes(jsonb, jsonb);
--
-- WHICH ROWS   : audit_logs rows ABOUT the employee: entity_type = 'employee' and entity_id = the employee's
--   id (as text). Rows the employee caused elsewhere (logins, work, income, ...) are NOT included; those
--   belong to the main-admin audit screen (list_audit_logs, 026).
-- WHO MAY CALL : main_admin, or a sub_admin holding 'employee_management'. Everyone else MORAYA_FORBIDDEN.
-- AADHAAR      : AADHAAR_REVEALED rows (who looked at the full number, when, why) are returned ONLY to the
--   main_admin. For a sub_admin those rows are left out completely, and total does not count them.
--   Rows of USER_AADHAAR_CHANGED stay visible to both: they only hold the masked value (XXXX XXXX 1234).
--   No Aadhaar number, key or ciphertext ever sits in audit_logs (audit_scrub removes them on write).
-- WHAT IS RETURNED (and what is not)
--   items[]: id, at, action, action_label, summary, actor_name, reason, changes
--   changes = null, or a list of {field, from, to} built from old_value / new_value after audit_scrub is
--   applied AGAIN. Fields whose value is "[REDACTED]" on either side are dropped. Values are text, cut to
--   200 characters, at most 20 fields per row.
--   NOT returned: old_value, new_value, ip, user_agent, request_id, the actor's id. No secret can leave here.
-- PAGING       : page 1..100000, page_size capped to 1..100 (default 20). Newest first (created_at, id).
-- RESPONSE     : {items[], page, page_size, total}
-- ERRORS       : MORAYA_FORBIDDEN, MORAYA_VALIDATION ('Required: employee_id'), MORAYA_NOT_FOUND ('Employee not found').
-- DIFFERS FROM 013: employee_detail_json reports can_view_activity = main admin only. This function lets
--   employee_management users read the activity too, as decided; the frontend flag should be updated to match.

-- =====================================================================================
-- 1. employee_activity_changes: internal helper (no grants for any API role)
-- =====================================================================================
create or replace function public.employee_activity_changes(p_old jsonb, p_new jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_o   jsonb := public.audit_scrub(p_old);
  v_n   jsonb := public.audit_scrub(p_new);
  v_out jsonb;
begin
  if v_o is null or jsonb_typeof(v_o) <> 'object' then v_o := '{}'::jsonb; end if;
  if v_n is null or jsonb_typeof(v_n) <> 'object' then v_n := '{}'::jsonb; end if;

  select jsonb_agg(jsonb_build_object('field', d.key, 'from', d.o, 'to', d.n) order by d.key)
    into v_out
    from (
      select k.key,
             left((v_o -> k.key) #>> '{}', 200) as o,
             left((v_n -> k.key) #>> '{}', 200) as n
        from (select jsonb_object_keys(v_o) as key
              union
              select jsonb_object_keys(v_n)) k
       where (v_o -> k.key) is distinct from (v_n -> k.key)
         and (v_o -> k.key) is distinct from '"[REDACTED]"'::jsonb
         and (v_n -> k.key) is distinct from '"[REDACTED]"'::jsonb
       order by k.key
       limit 20
    ) d;

  return v_out;   -- null when nothing differs
end $$;

revoke all on function public.employee_activity_changes(jsonb, jsonb)
  from public, anon, authenticated, service_role;

-- =====================================================================================
-- 2. list_employee_activity
-- =====================================================================================
create or replace function public.list_employee_activity(
  p_actor_auth_id uuid,
  p_employee_id   uuid,
  p_page          integer default 1,
  p_page_size     integer default 20
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  public.employees;
  v_target uuid;
  v_hide   boolean;
  v_page   integer := greatest(1, least(coalesce(p_page, 1), 100000));
  v_size   integer := greatest(1, least(coalesce(p_page_size, 20), 100));
  v_total  bigint;
  v_items  jsonb;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['employee_management']);

  if p_employee_id is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Required: employee_id');
  end if;
  select e.id into v_target from public.employees e where e.id = p_employee_id;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Employee not found');
  end if;

  -- Only the main admin may see who revealed the Aadhaar number.
  v_hide := v_actor.role <> 'main_admin';

  select count(*) into v_total
    from public.audit_logs l
   where l.entity_type = 'employee'
     and l.entity_id = v_target::text
     and (not v_hide or l.action <> 'AADHAAR_REVEALED');

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id, 'at', x.created_at, 'action', x.action, 'action_label', x.description,
           'summary', coalesce(x.summary, x.description, x.action),
           'actor_name', x.actor_name, 'reason', x.reason,
           'changes', public.employee_activity_changes(x.old_value, x.new_value))
           order by x.created_at desc, x.id desc), '[]'::jsonb)
    into v_items
    from (
      select l.id, l.created_at, l.action, aa.description, l.summary, l.reason,
             l.old_value, l.new_value, e.name as actor_name
        from public.audit_logs l
        left join public.audit_actions aa on aa.action = l.action
        left join public.employees e on e.id = l.actor_employee_id
       where l.entity_type = 'employee'
         and l.entity_id = v_target::text
         and (not v_hide or l.action <> 'AADHAAR_REVEALED')
       order by l.created_at desc, l.id desc
       limit v_size offset (v_page - 1) * v_size
    ) x;

  return jsonb_build_object('items', v_items, 'page', v_page, 'page_size', v_size, 'total', v_total);
end $$;

revoke all on function public.list_employee_activity(uuid, uuid, integer, integer) from public, anon, authenticated;
grant execute on function public.list_employee_activity(uuid, uuid, integer, integer) to service_role;