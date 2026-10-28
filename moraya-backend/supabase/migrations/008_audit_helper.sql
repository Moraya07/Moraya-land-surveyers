-- 008_audit_helper.sql
-- PURPOSE   : One reusable write_audit() that every later RPC calls inside its own
--             transaction, plus small shared helpers (error raiser, actor check),
--             an audit action catalogue, a secret scrubber, and hardening of 001-007.
-- DEPENDS ON: 001 (user_role, account_status), 002 (employees), 003 (permissions),
--             004 (audit_logs + immutability triggers), 007 (grants pattern).
-- ROLLBACK  : drop function public.write_audit(uuid,text,text,text,jsonb,jsonb,text,text,text);
--             drop function public.audit_scrub(jsonb,int);
--             drop function public.audit_diff_summary(text,jsonb,jsonb);
--             drop function public.audit_rupees(bigint);
--             drop function public.moraya_require_actor(uuid,boolean,text[]);
--             drop function public.moraya_fail(text,text);
--             drop table public.audit_actions;
--             drop index if exists audit_logs_entity_idx, audit_logs_action_idx;
--             alter table public.audit_logs drop constraint if exists audit_logs_summary_len,
--                                           drop constraint if exists audit_logs_action_format;
--             alter table public.audit_logs drop column if exists summary;
--             (The hardening section at the end is not rolled back; it only tightens access.)
-- NOTE      : Error convention for every later file: raise exception with
--             SQLSTATE P0001 and MESSAGE = a stable code such as MORAYA_FORBIDDEN.
--             Codes: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND, MORAYA_INVALID_STATE,
--                    MORAYA_VALIDATION, MORAYA_CONFLICT.

-- =====================================================================================
-- 1. audit_logs: human-readable summary + indexes + format checks
-- =====================================================================================
alter table public.audit_logs add column if not exists summary text;

do $$ begin
  alter table public.audit_logs
    add constraint audit_logs_summary_len check (summary is null or char_length(summary) <= 500) not valid;
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.audit_logs
    add constraint audit_logs_action_format check (action ~ '^[A-Z][A-Z0-9_]*$') not valid;
exception when duplicate_object then null; end $$;

-- Activity tab for one entity (employee page, site page, work entry page).
create index if not exists audit_logs_entity_idx
  on public.audit_logs (entity_type, entity_id, created_at desc);
-- Audit log screen filtered by action.
create index if not exists audit_logs_action_idx
  on public.audit_logs (action, created_at desc);

-- =====================================================================================
-- 2. Action catalogue (documentation + typo protection)
--    write_audit() rejects any action not listed here. Later files add their own rows
--    with: insert into public.audit_actions ... on conflict (action) do nothing;
--    Employee action names follow what the frontend already knows (USER_*, SUBADMIN_*,
--    AADHAAR_REVEALED), not the EMPLOYEE_* example in the prompt.
-- =====================================================================================
create table if not exists public.audit_actions (
  action      text primary key check (action ~ '^[A-Z][A-Z0-9_]*$'),
  category    text not null,
  description text not null,
  created_at  timestamptz not null default now()
);

insert into public.audit_actions (action, category, description) values
  -- already written by the Worker (001-007 era)
  ('LOGIN_SUCCESS',                'auth',     'User signed in'),
  ('LOGIN_FAILED',                 'auth',     'Sign-in failed or blocked account'),
  ('LOGIN_BLOCKED',                'auth',     'Too many sign-in attempts'),
  ('LOGOUT',                       'auth',     'User signed out'),
  ('PASSWORD_RESET_REQUESTED',     'auth',     'Password reset email requested'),
  ('PASSWORD_RESET_BLOCKED',       'auth',     'Too many password reset requests'),
  ('ACCESS_DENIED',                'auth',     'A request was refused by role or permission'),
  -- own account
  ('PASSWORD_CHANGED',             'account',  'User changed their own password'),
  ('PROFILE_UPDATED',              'account',  'User edited their own profile'),
  -- employees (names match the frontend)
  ('USER_CREATED',                 'employee', 'Employee created'),
  ('USER_UPDATED',                 'employee', 'Employee details changed'),
  ('USER_AADHAAR_CHANGED',         'employee', 'Employee Aadhaar replaced'),
  ('USER_DEACTIVATED',             'employee', 'Employee deactivated'),
  ('USER_REACTIVATED',             'employee', 'Employee reactivated'),
  ('USER_REVOKED',                 'employee', 'Employee access revoked'),
  ('SUBADMIN_CREATED',             'employee', 'Employee made a sub admin'),
  ('SUBADMIN_PERMISSIONS_CHANGED', 'employee', 'Sub admin permissions changed'),
  ('SUBADMIN_REVOKED',             'employee', 'Sub admin role removed'),
  ('AADHAAR_REVEALED',             'employee', 'Full Aadhaar shown to Main Admin'),
  ('MAIN_ADMIN_TRANSFERRED',       'employee', 'Main Admin role handed to another employee'),
  -- settings
  ('SETTINGS_UPDATED',             'settings', 'Company or app settings changed'),
  -- sites
  ('SITE_CREATED',                 'site',     'Site created'),
  ('SITE_UPDATED',                 'site',     'Site details changed'),
  ('SITE_STATUS_CHANGED',          'site',     'Site status changed'),
  -- work entries
  ('WORK_SUBMITTED',               'work',     'Work entry submitted'),
  ('WORK_RESUBMITTED',             'work',     'Work entry resubmitted after changes'),
  ('WORK_APPROVED',                'work',     'Work entry verified'),
  ('WORK_CHANGES_REQUESTED',       'work',     'Changes requested on a work entry'),
  ('WORK_REJECTED',                'work',     'Work entry rejected'),
  ('WORK_CANCELLED',               'work',     'Work entry cancelled'),
  -- income
  ('INCOME_CREATED',               'income',   'Income transaction created'),
  ('INCOME_UPDATED',               'income',   'Income transaction changed'),
  ('INCOME_CANCELLED',             'income',   'Income transaction cancelled'),
  -- salary
  ('SALARY_CREATED',               'salary',   'Salary record created'),
  ('SALARY_UPDATED',               'salary',   'Salary record changed'),
  ('SALARY_STATUS_CHANGED',        'salary',   'Salary status or paid amount changed'),
  -- client bills
  ('CLIENT_BILL_GENERATED',        'bill',     'Client bill generated (draft)'),
  ('CLIENT_BILL_FINALIZED',        'bill',     'Client bill finalized'),
  ('CLIENT_BILL_CANCELLED',        'bill',     'Client bill cancelled')
on conflict (action) do nothing;

-- =====================================================================================
-- 3. Small helpers
-- =====================================================================================

-- Raises the stable error the Worker maps: SQLSTATE P0001, message = code.
create or replace function public.moraya_fail(p_code text, p_detail text default null)
returns void
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception using errcode = 'P0001', message = p_code, detail = p_detail;
end $$;

-- paise -> text for summaries: 25000 -> '₹250', 25050 -> '₹250.50'
create or replace function public.audit_rupees(p_paise bigint)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case when p_paise is null then '-' else
    (case when p_paise < 0 then '-' else '' end) || '₹' || (abs(p_paise) / 100)::text ||
    case when abs(p_paise) % 100 <> 0 then '.' || lpad((abs(p_paise) % 100)::text, 2, '0') else '' end
  end;
$$;

-- Recursively removes secrets before anything is stored in old_value / new_value.
--  * keys containing password, secret, token, apikey, authorization, jwt, cookie,
--    encryptionkey, privatekey, signingkey, or ending in "key"  -> "[REDACTED]"
--  * keys containing aadhaar/aadhar -> "[REDACTED]" unless the key also contains
--    "last4" or "masked"
--  * keys containing accountnumber -> masked to the last 4 characters
-- Keys are compared lowercase with every non-letter/digit removed.
create or replace function public.audit_scrub(p_value jsonb, p_depth int default 0)
returns jsonb
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  r      record;
  v_out  jsonb;
  v_norm text;
  v_txt  text;
begin
  if p_value is null then return null; end if;
  if p_depth > 8 then return to_jsonb('[TRUNCATED]'::text); end if;

  if jsonb_typeof(p_value) = 'object' then
    v_out := '{}'::jsonb;
    for r in select key, value from jsonb_each(p_value) loop
      v_norm := lower(regexp_replace(r.key, '[^A-Za-z0-9]', '', 'g'));
      if v_norm ~ '(password|passwd|secret|token|apikey|authorization|jwt|cookie|encryptionkey|privatekey|signingkey)'
         or v_norm ~ 'key$' then
        v_out := v_out || jsonb_build_object(r.key, '[REDACTED]');
      elsif v_norm ~ '(aadhaar|aadhar)' and v_norm !~ '(last4|masked)' then
        v_out := v_out || jsonb_build_object(r.key, '[REDACTED]');
      elsif v_norm like '%accountnumber%' then
        v_txt := case when jsonb_typeof(r.value) = 'string' then r.value #>> '{}' else null end;
        v_out := v_out || jsonb_build_object(r.key,
                   case when v_txt is null then null
                        when char_length(v_txt) <= 4 then repeat('X', char_length(v_txt))
                        else repeat('X', char_length(v_txt) - 4) || right(v_txt, 4) end);
      else
        v_out := v_out || jsonb_build_object(r.key, public.audit_scrub(r.value, p_depth + 1));
      end if;
    end loop;
    return v_out;
  elsif jsonb_typeof(p_value) = 'array' then
    select coalesce(jsonb_agg(public.audit_scrub(e, p_depth + 1)), '[]'::jsonb)
      into v_out from jsonb_array_elements(p_value) as e;
    return v_out;
  end if;
  return p_value;
end $$;

-- "Changed income: 20000 -> 25000; remarks: a -> b" from two jsonb objects.
-- Only keys whose value differs are listed. Pass already-scrubbed or safe values.
-- For money fields give the caller's own summary text (use audit_rupees) instead.
create or replace function public.audit_diff_summary(p_prefix text, p_old jsonb, p_new jsonb)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  r      record;
  v_parts text[] := '{}';
  v_text text;
begin
  for r in
    select k.key,
           p_old -> k.key as o,
           p_new -> k.key as n
    from (select jsonb_object_keys(coalesce(p_old, '{}'::jsonb)) as key
          union
          select jsonb_object_keys(coalesce(p_new, '{}'::jsonb))) k
    where (p_old -> k.key) is distinct from (p_new -> k.key)
    order by k.key
  loop
    v_parts := v_parts || format('%s: %s -> %s',
      replace(r.key, '_', ' '),
      coalesce(r.o #>> '{}', '-'),
      coalesce(r.n #>> '{}', '-'));
  end loop;

  if cardinality(v_parts) = 0 then
    v_text := coalesce(p_prefix, 'No change');
  else
    v_text := coalesce(p_prefix, 'Changed') || ' ' || array_to_string(v_parts, '; ');
  end if;
  return left(v_text, 500);
end $$;

-- =====================================================================================
-- 4. write_audit: the one-line audit call
--    select public.write_audit(v_actor.id, 'SITE_UPDATED', 'site', v_site.id::text,
--                              v_old, v_new, p_reason, p_request_id);
--    Runs inside the caller's transaction: if the business change rolls back, so does
--    the audit row. Returns the new audit_logs.id.
--    p_actor may be null only for system events.
--    p_summary null -> a default is built from the action (for example "Work approved").
-- =====================================================================================
create or replace function public.write_audit(
  p_actor       uuid,
  p_action      text,
  p_entity_type text,
  p_entity_id   text,
  p_old_value   jsonb,
  p_new_value   jsonb,
  p_reason      text,
  p_request_id  text,
  p_summary     text default null
) returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_old     jsonb;
  v_new     jsonb;
  v_summary text;
  v_id      bigint;
begin
  if p_action is null or not exists (select 1 from public.audit_actions a where a.action = p_action) then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Unknown audit action');
  end if;

  if p_old_value is not null and jsonb_typeof(p_old_value) <> 'object' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'old_value must be a JSON object');
  end if;
  if p_new_value is not null and jsonb_typeof(p_new_value) <> 'object' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'new_value must be a JSON object');
  end if;
  if length(coalesce(p_old_value::text, '')) > 100000 or length(coalesce(p_new_value::text, '')) > 100000 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Audit values are too large');
  end if;

  v_old := public.audit_scrub(p_old_value);
  v_new := public.audit_scrub(p_new_value);

  v_summary := nullif(btrim(coalesce(p_summary, '')), '');
  if v_summary is null then
    v_summary := initcap(replace(lower(p_action), '_', ' '));
    v_summary := upper(left(v_summary, 1)) || lower(substr(v_summary, 2));
    if p_entity_type is not null and p_entity_id is not null then
      v_summary := v_summary || ' (' || p_entity_type || ' ' || p_entity_id || ')';
    end if;
  end if;
  v_summary := left(v_summary, 500);

  insert into public.audit_logs
    (actor_employee_id, action, entity_type, entity_id, old_value, new_value, reason, request_id, summary)
  values
    (p_actor, p_action, p_entity_type, p_entity_id, v_old, v_new,
     nullif(left(coalesce(p_reason, ''), 1000), ''), p_request_id, v_summary)
  returning id into v_id;

  return v_id;
end $$;

-- =====================================================================================
-- 5. moraya_require_actor: the shared "who is calling" check
--    Every RPC starts with:
--      v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['site_management']);
--    Rules (all failures raise MORAYA_FORBIDDEN, never a hint about which rule failed):
--      * no employee row for this auth user, or account_status <> 'active'
--      * p_main_admin_only and the role is not main_admin
--      * p_any_permission given: main_admin always passes; a sub_admin passes if they
--        hold AT LEAST ONE listed permission; workers always fail
--    A permission name that is not one of the seven known names is a coding error and
--    raises MORAYA_VALIDATION.
-- =====================================================================================
create or replace function public.moraya_require_actor(
  p_auth_user_id   uuid,
  p_main_admin_only boolean default false,
  p_any_permission text[] default null
) returns public.employees
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor public.employees;
  v_perm  text;
begin
  if p_any_permission is not null then
    foreach v_perm in array p_any_permission loop
      if v_perm not in ('employee_management','site_management','verification','income_management',
                        'salary_management','report_view','export') then
        perform public.moraya_fail('MORAYA_VALIDATION', 'Unknown permission name');
      end if;
    end loop;
  end if;

  select * into v_actor from public.employees e where e.auth_user_id = p_auth_user_id;

  if not found or v_actor.account_status <> 'active' then
    perform public.moraya_fail('MORAYA_FORBIDDEN');
  end if;

  if p_main_admin_only and v_actor.role <> 'main_admin' then
    perform public.moraya_fail('MORAYA_FORBIDDEN');
  end if;

  if p_any_permission is not null and v_actor.role <> 'main_admin' then
    if v_actor.role <> 'sub_admin'
       or not exists (select 1 from public.sub_admin_permissions sp
                      where sp.employee_id = v_actor.id and sp.permission = any (p_any_permission)) then
      perform public.moraya_fail('MORAYA_FORBIDDEN');
    end if;
  end if;

  return v_actor;
end $$;

-- =====================================================================================
-- 6. Grants for the new objects: service_role only
-- =====================================================================================
alter table public.audit_actions enable row level security;
revoke all on public.audit_actions from public, anon, authenticated;
revoke all on public.audit_actions from service_role;
grant select on public.audit_actions to service_role;

revoke all on function public.moraya_fail(text, text)                           from public, anon, authenticated;
revoke all on function public.audit_rupees(bigint)                              from public, anon, authenticated;
revoke all on function public.audit_scrub(jsonb, int)                           from public, anon, authenticated;
revoke all on function public.audit_diff_summary(text, jsonb, jsonb)            from public, anon, authenticated;
revoke all on function public.write_audit(uuid, text, text, text, jsonb, jsonb, text, text, text)
                                                                                from public, anon, authenticated;
revoke all on function public.moraya_require_actor(uuid, boolean, text[])       from public, anon, authenticated;

grant execute on function public.moraya_fail(text, text)                        to service_role;
grant execute on function public.audit_rupees(bigint)                           to service_role;
grant execute on function public.audit_scrub(jsonb, int)                        to service_role;
grant execute on function public.audit_diff_summary(text, jsonb, jsonb)         to service_role;
grant execute on function public.write_audit(uuid, text, text, text, jsonb, jsonb, text, text, text)
                                                                                to service_role;
grant execute on function public.moraya_require_actor(uuid, boolean, text[])    to service_role;

-- =====================================================================================
-- 7. Hardening of 001-007 (from the review). Tightens access only; changes no data.
-- =====================================================================================

-- 7a. New tables and functions are closed by default from now on (Supabase otherwise
--     grants anon/authenticated on everything created in public). Applies to objects
--     created later by the role running this migration.
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from anon, authenticated;
alter default privileges revoke execute on functions from public;

-- 7b. pg_temp last in the search_path of the existing SECURITY DEFINER functions.
alter function public.auth_throttle_hit(text[], int[], int, text, inet, text, text, text)
  set search_path = public, pg_temp;
alter function public.get_auth_profile(uuid)
  set search_path = public, pg_temp;
alter function public.login_profile_and_audit(uuid, inet, text, text, text, text)
  set search_path = public, pg_temp;
alter function public.employees_check_auth_email()
  set search_path = public, auth, pg_temp;

-- 7c. Trigger functions must not be callable by clients. (CREATE TRIGGER needed EXECUTE
--     only at creation time, so existing triggers keep working.)
revoke all on function public.set_updated_at()                              from public, anon, authenticated;
revoke all on function public.protect_main_admin()                          from public, anon, authenticated;
revoke all on function public.audit_logs_immutable()                        from public, anon, authenticated;
revoke all on function public.employees_check_auth_email()                  from public, anon, authenticated;
revoke all on function public.sub_admin_permissions_check_role()            from public, anon, authenticated;
revoke all on function public.employees_drop_permissions_on_role_change()   from public, anon, authenticated;

-- 7d. Clients never read tables directly (the frontend only talks to the Worker, and
--     every read goes through an RPC). Without this, the own-row policy on employees
--     would later expose the encrypted Aadhaar columns added in 012.
revoke all on public.employees, public.sub_admin_permissions from anon, authenticated;

-- 7e. Employees are deactivated, never deleted, and nothing may truncate them.
--     SECURITY DEFINER functions run as the owner, so they are not affected.
revoke delete, truncate on public.employees from service_role;
revoke truncate on public.sub_admin_permissions from service_role;