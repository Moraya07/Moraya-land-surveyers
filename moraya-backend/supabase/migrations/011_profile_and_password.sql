-- 011_profile_and_password.sql
-- PURPOSE   : Backend for the "Profile" and "Change Password" pages (any signed-in user,
--             any role):
--               get_own_profile      safe read of the caller's own record
--               update_own_profile   edit the small self-editable set (phone only)
--               log_password_change  audit entry after a successful password change
-- DEPENDS ON: 001, 002 (employees), 003 (sub_admin_permissions), 005 (auth_login_attempts),
--             008 (write_audit, moraya_require_actor, moraya_fail, PROFILE_UPDATED and
--             PASSWORD_CHANGED already in the audit catalogue),
--             010 (app_settings_clean, reused for trimming and format checks).
--             012 is NOT required: Aadhaar is read defensively (see get_own_profile).
-- ROLLBACK  : drop function public.log_password_change(uuid,text);
--             drop function public.update_own_profile(uuid,jsonb,text);
--             drop function public.get_own_profile(uuid);
--             drop function public.own_profile_as_json(uuid);
--             drop function public.profile_mask_phone(text);
--             alter table public.employees drop constraint if exists employees_phone_format;
--             alter table public.employees drop column if exists phone;   -- loses stored phones
--             delete from public.audit_actions
--              where action in ('PASSWORD_CHANGE_FAILED','PASSWORD_CHANGE_BLOCKED');
--
-- SELF-EDITABLE FIELDS (assumption for you to approve): ONLY "phone".
--   Everything else on the employee row (name, role, status, employee id, login email,
--   permissions, designation, date of birth, date of joining, Aadhaar) is changed only
--   by employee-management functions (013) or the Main Admin. Any other key in the patch
--   is rejected with MORAYA_VALIDATION, so a tampered request cannot widen the set.
--
-- PASSWORD CHANGE FLOW (the password itself lives in Supabase Auth, never in SQL):
--   1. Worker throttles first:  auth_throttle_hit(['chgpw:<employee uuid>'], [5], 900,
--      'PASSWORD_CHANGE_BLOCKED', ...)   -> 5 tries per 15 minutes per account.
--   2. Worker verifies the CURRENT password with passwordGrant (same call login uses).
--      Without the throttle in step 1, a stolen session cookie could be used to guess
--      the current password with no limit, because this check is not covered by the
--      login throttle (its keys are IP+email and IP, and a wrong guess here is made
--      from a signed-in session).
--   3. Worker sets the new password through the Supabase Auth admin API, then signs out
--      the user's other sessions.
--   4. Worker calls log_password_change(). It writes PASSWORD_CHANGED and deletes the
--      'chgpw:<employee uuid>' counter in the same round trip (same idea as the reset
--      done inside login_profile_and_audit), so a successful change never leaves the
--      user close to the limit.
--   A wrong current password is written by the Worker with writeAudit as
--   PASSWORD_CHANGE_FAILED (no password, no hint of the guess). The login throttle
--   counters (key = IP+email, IP) are never touched here: changing a password is not a
--   login and must not unlock or lock the login screen.

-- =====================================================================================
-- 1. Column: employees.phone (optional, self-editable)
-- =====================================================================================
alter table public.employees add column if not exists phone text;

do $$ begin
  alter table public.employees
    add constraint employees_phone_format check (phone is null or phone ~ '^\+?[0-9]{7,15}$');
exception when duplicate_object then null; end $$;

-- =====================================================================================
-- 2. Audit catalogue: two more password events
--    PASSWORD_CHANGE_BLOCKED is written by auth_throttle_hit, PASSWORD_CHANGE_FAILED by
--    the Worker (audit.ts). Neither goes through write_audit, so they are listed here
--    for documentation and so the audit screen can offer them as filters.
-- =====================================================================================
insert into public.audit_actions (action, category, description) values
  ('PASSWORD_CHANGE_FAILED',  'account', 'Password change refused: current password was wrong'),
  ('PASSWORD_CHANGE_BLOCKED', 'account', 'Too many password change attempts')
on conflict (action) do nothing;

-- =====================================================================================
-- 3. Internal helpers (service_role only)
-- =====================================================================================

-- 9876543210 -> XXXXXX3210. Used so audit rows never hold a full phone number.
create or replace function public.profile_mask_phone(p_phone text) returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case
    when p_phone is null then null
    when char_length(p_phone) <= 4 then repeat('X', char_length(p_phone))
    else repeat('X', char_length(p_phone) - 4) || right(p_phone, 4)
  end;
$$;

-- The safe profile shape. Deliberately NOT built with to_jsonb(row): a new column added
-- later must never appear here by accident.
-- Aadhaar: shows 'XXXX XXXX 1234' from employees.aadhaar_last4 (added in 012). The
-- column is read through to_jsonb(e) so this function works both before and after 012;
-- before 012 (or when the value is not exactly 4 digits) aadhaar_masked is null.
-- The encrypted Aadhaar and the full number are never touched here.
create or replace function public.own_profile_as_json(p_employee_id uuid) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb;
begin
  select jsonb_build_object(
           'employee_id',     e.employee_id,
           'name',            e.name,
           'login_email',     e.login_email::text,
           'role',            e.role,
           'account_status',  e.account_status,
           'designation',     e.designation,
           'date_of_birth',   e.date_of_birth,
           'date_of_joining', e.date_of_joining,
           'phone',           e.phone,
           'aadhaar_masked',  case when (to_jsonb(e) ->> 'aadhaar_last4') ~ '^[0-9]{4}$'
                                   then 'XXXX XXXX ' || (to_jsonb(e) ->> 'aadhaar_last4') end,
           'permissions',     to_jsonb(coalesce(
                                (select array_agg(p.permission order by p.permission)
                                   from public.sub_admin_permissions p
                                  where p.employee_id = e.id), '{}'::text[]))
         )
    into v
    from public.employees e
   where e.id = p_employee_id;

  if v is null then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Employee not found');
  end if;
  return v;
end $$;

-- =====================================================================================
-- 4. get_own_profile : any active user, own record only
--    The caller is always the person in p_actor_auth_id; there is no way to ask for
--    someone else's profile here.
--    Returns {employee_id, name, login_email, role, account_status, designation,
--             date_of_birth, date_of_joining, phone, aadhaar_masked, permissions[]}.
--    The main_admin's permissions array is empty (the role implies everything).
--    Errors: MORAYA_FORBIDDEN (no employee row, or not active), MORAYA_NOT_FOUND
-- =====================================================================================
create or replace function public.get_own_profile(p_actor_auth_id uuid) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor public.employees;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, null);
  return public.own_profile_as_json(v_actor.id);
end $$;

-- =====================================================================================
-- 5. update_own_profile : any active user, own record only
--    p_patch accepts only: phone.
--      phone  text; spaces, hyphens and brackets are removed; digits with an optional
--             leading + , 7 to 15 digits; null or blank clears it.
--    Any other key, including role, account_status, employee_id, name, login_email,
--    permissions, designation, date_of_birth, date_of_joining and anything about
--    Aadhaar, raises MORAYA_VALIDATION ("Not editable: <key>").
--    The row is locked, so two quick saves cannot interleave. If nothing actually
--    changes, nothing is written or audited.
--    Audit PROFILE_UPDATED stores the phone MASKED (last 4 digits) in old and new value.
--    Returns {changed: bool, profile: {...same shape as get_own_profile}}.
--    Errors: MORAYA_FORBIDDEN, MORAYA_VALIDATION, MORAYA_NOT_FOUND
-- =====================================================================================
create or replace function public.update_own_profile(
  p_actor_auth_id uuid,
  p_patch         jsonb,
  p_request_id    text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor    public.employees;
  v_row      public.employees;
  v_new      text;
  r          record;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, null);

  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Send an object with at least one field');
  end if;

  -- Validate every key before touching the row.
  for r in select key, value from jsonb_each(p_patch) loop
    if r.key = 'phone' then
      v_new := public.app_settings_clean(
                 r.value, 'phone', 20, false, '^\+?[0-9]{7,15}$', null, '[ ()-]');
    else
      perform public.moraya_fail('MORAYA_VALIDATION', 'Not editable: ' || left(r.key, 50));
    end if;
  end loop;

  select * into v_row from public.employees e where e.id = v_actor.id for update;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Employee not found');
  end if;

  if v_row.phone is not distinct from v_new then
    return jsonb_build_object('changed', false, 'profile', public.own_profile_as_json(v_row.id));
  end if;

  update public.employees e set phone = v_new where e.id = v_row.id;

  perform public.write_audit(
    v_row.id, 'PROFILE_UPDATED', 'employee', v_row.id::text,
    jsonb_build_object('phone_masked', public.profile_mask_phone(v_row.phone)),
    jsonb_build_object('phone_masked', public.profile_mask_phone(v_new)),
    null, p_request_id,
    'Updated own profile: phone ' || coalesce(public.profile_mask_phone(v_row.phone), '-')
      || ' -> ' || coalesce(public.profile_mask_phone(v_new), '-')
  );

  return jsonb_build_object('changed', true, 'profile', public.own_profile_as_json(v_row.id));
end $$;

-- =====================================================================================
-- 6. log_password_change : any active user, own account
--    Call AFTER Supabase Auth accepted the new password. Writes PASSWORD_CHANGED
--    (no password, no hash, no token anywhere) and deletes the account's
--    'chgpw:<employee uuid>' throttle counter in the same transaction.
--    Returns {logged: true}.
--    Errors: MORAYA_FORBIDDEN. If the account was deactivated between the change and this
--    call, the Worker should log a warning and still report the change as done: the
--    password has already changed in Supabase Auth.
-- =====================================================================================
create or replace function public.log_password_change(
  p_actor_auth_id uuid,
  p_request_id    text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor public.employees;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, null);

  delete from public.auth_login_attempts where key = 'chgpw:' || v_actor.id::text;

  perform public.write_audit(
    v_actor.id, 'PASSWORD_CHANGED', 'employee', v_actor.id::text,
    null, null, null, p_request_id, 'Changed own password');

  return jsonb_build_object('logged', true);
end $$;

-- =====================================================================================
-- 7. Function grants: service_role only
-- =====================================================================================
revoke all on function public.profile_mask_phone(text)                  from public, anon, authenticated;
revoke all on function public.own_profile_as_json(uuid)                 from public, anon, authenticated;
revoke all on function public.get_own_profile(uuid)                     from public, anon, authenticated;
revoke all on function public.update_own_profile(uuid, jsonb, text)     from public, anon, authenticated;
revoke all on function public.log_password_change(uuid, text)           from public, anon, authenticated;

grant execute on function public.profile_mask_phone(text)               to service_role;
grant execute on function public.own_profile_as_json(uuid)              to service_role;
grant execute on function public.get_own_profile(uuid)                  to service_role;
grant execute on function public.update_own_profile(uuid, jsonb, text)  to service_role;
grant execute on function public.log_password_change(uuid, text)        to service_role;