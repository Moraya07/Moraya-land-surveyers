-- 013_employee_functions.sql
-- PURPOSE   : The employee RPCs the Worker calls (service_role only):
--               create_employee, update_employee, set_employee_status,
--               promote_to_sub_admin, revoke_sub_admin, set_permissions,
--               get_employee, list_employees.
--             Every function re-checks the caller itself, runs in one transaction and
--             writes an audit row through write_audit() (008).
-- DEPENDS ON: 001, 002 (employees), 003 (sub_admin_permissions + its triggers),
--             004 (audit_logs), 008 (write_audit, moraya_require_actor, moraya_fail,
--             audit_diff_summary, audit action names USER_*, SUBADMIN_*),
--             009 (protect_main_admin: only transfer_main_admin can change the Main Admin),
--             010 (app_settings_clean, reused for trimming and length checks),
--             011 (employees.phone), 012 (aadhaar columns, aadhaar_normalize,
--             set_employee_aadhaar, mask_aadhaar, column grants on employees).
-- ROLLBACK  : drop function public.list_employees(uuid,text,text,text,text,integer,integer);
--             drop function public.get_employee(uuid,uuid);
--             drop function public.set_permissions(uuid,uuid,text[],text,text);
--             drop function public.revoke_sub_admin(uuid,uuid,text,text);
--             drop function public.promote_to_sub_admin(uuid,uuid,text[],text,text);
--             drop function public.set_employee_status(uuid,uuid,text,text,text);
--             drop function public.update_employee(uuid,uuid,integer,jsonb,text,text);
--             drop function public.create_employee(uuid,uuid,text,text,text,text,date,date,text,text,text,text[],text);
--             drop function public.employee_detail_json(uuid,public.user_role,uuid);
--             drop function public.employee_caps(uuid,public.user_role,uuid,public.user_role,public.account_status);
--             drop function public.employee_is_manageable(uuid,public.user_role,uuid,public.user_role);
--             drop function public.employee_raise_conflict(text);
--             drop function public.employee_validate_dates(date,date);
--             drop function public.employee_clean_reason(text,boolean);
--             drop function public.employee_clean_perms(text[]);
--             drop function public.employee_parse_date(jsonb,text);
--             drop function public.employee_today_ist();
--             drop trigger if exists employees_bump_version on public.employees;
--             drop function public.employees_bump_version();
--             drop index if exists audit_logs_login_success_idx;
--             alter table public.employees drop column if exists version;
--             (nothing else is changed; no data is lost except the version counter)
--
-- ERROR CONVENTION (same as 008 to 012): SQLSTATE P0001, MESSAGE = stable code, DETAIL =
--   a short text for the Worker to map to a form field. Details used here:
--     'Required: <field>'  'Too short: <field>'  'Too long: <field>'  'Invalid: <field>'
--     'Not allowed: <field>'  'Future date: <field>'  'Before birth date: date_of_joining'
--     'Already in use: <field>'  (MORAYA_CONFLICT)   'VERSION_CONFLICT'  (MORAYA_CONFLICT)
--   Field names are the snake_case names used in this file.
--
-- WHO MAY DO WHAT (resolved cases)
--   Caller must be an ACTIVE main_admin, or an ACTIVE sub_admin holding employee_management.
--   Target is a worker            : any such caller.
--   Target is another sub_admin   : main_admin only (edit, deactivate, reactivate, all).
--   Target is the main_admin      : nobody can change status, role or permissions (009 also
--                                   blocks it). The main_admin may edit his or her OWN
--                                   details (name, designation, dates, Aadhaar, employee id).
--   create_employee               : role worker by any such caller; role sub_admin by
--                                   main_admin only.
--   promote_to_sub_admin, revoke_sub_admin, set_permissions : main_admin only.
--   set_employee_status           : deactivate and reactivate-from-inactive follow the target
--                                   rules above. REVOKE, and reactivating a REVOKED employee,
--                                   are main_admin only (revoked is the stronger state).
--   Nobody can change their own status (the main_admin is protected, a sub_admin cannot touch
--   a sub_admin).
--
-- HISTORY IS NEVER BROKEN
--   Deactivating or revoking only changes account_status. No row is deleted, no foreign key
--   is touched, sub_admin permission rows are kept (moraya_require_actor already refuses an
--   inactive caller, so kept permissions give no power) and come back on reactivation.
--   Ending the person's sessions / banning the Supabase Auth user is the Worker's job:
--   set_employee_status returns auth_user_id for exactly that.
--
-- OPTIMISTIC LOCKING
--   employees.version (new, integer) goes up by one on EVERY update of the row (trigger
--   below). It is an opaque counter that only increases, not a count of edits.
--   update_employee requires the version the screen was loaded with.

-- =====================================================================================
-- 1. employees.version + trigger + last-login index
-- =====================================================================================
alter table public.employees add column if not exists version integer not null default 1;

-- 012 made the service role's column list explicit, so the new column must be granted.
grant select (version) on public.employees to service_role;

create or replace function public.employees_bump_version() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.version := old.version + 1;
  return new;
end $$;

drop trigger if exists employees_bump_version on public.employees;
create trigger employees_bump_version before update on public.employees
  for each row execute function public.employees_bump_version();

revoke all on function public.employees_bump_version() from public, anon, authenticated;

-- Detail page "last login": newest LOGIN_SUCCESS of one employee without scanning all their rows.
create index if not exists audit_logs_login_success_idx
  on public.audit_logs (actor_employee_id, created_at desc) where action = 'LOGIN_SUCCESS';

-- =====================================================================================
-- 2. Internal helpers (no grant to anyone; only the SECURITY DEFINER functions below call them)
-- =====================================================================================

-- Today in India. Used for date-of-birth / joining-date checks (users are in Asia/Kolkata).
create or replace function public.employee_today_ist() returns date
language sql
stable
set search_path = public, pg_temp
as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

-- jsonb string 'YYYY-MM-DD' (or null) -> date. Anything else is MORAYA_VALIDATION.
create or replace function public.employee_parse_date(p_value jsonb, p_field text) returns date
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_text text;
  v_date date;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then return null; end if;
  if jsonb_typeof(p_value) <> 'string' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: ' || p_field);
  end if;
  v_text := btrim(p_value #>> '{}');
  if v_text = '' then return null; end if;
  if v_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: ' || p_field);
  end if;
  begin
    v_date := v_text::date;
  exception when others then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: ' || p_field);
  end;
  return v_date;
end $$;

-- Permission list -> distinct, sorted, every name checked against the seven known ones.
-- null becomes an empty array.
create or replace function public.employee_clean_perms(p_perms text[]) returns text[]
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_out text[];
  v_bad int;
begin
  if p_perms is null then return '{}'::text[]; end if;
  select count(*) into v_bad
    from unnest(p_perms) as x
   where x is null
      or btrim(x) not in ('employee_management','site_management','verification','income_management',
                          'salary_management','report_view','export');
  if v_bad > 0 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: permissions');
  end if;
  select coalesce(array_agg(distinct btrim(x) order by btrim(x)), '{}'::text[]) into v_out from unnest(p_perms) as x;
  return v_out;
end $$;

-- Reason text. Required: 5 to 500 characters. Optional: empty becomes null, max 500.
create or replace function public.employee_clean_reason(p_reason text, p_required boolean) returns text
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v text := btrim(coalesce(p_reason, ''));
begin
  if v = '' then
    if p_required then perform public.moraya_fail('MORAYA_VALIDATION', 'Required: reason'); end if;
    return null;
  end if;
  if p_required and char_length(v) < 5 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too short: reason');
  end if;
  if char_length(v) > 500 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too long: reason');
  end if;
  return v;
end $$;

-- Date of birth must be in the past, joining date not in the future, joining not before birth.
create or replace function public.employee_validate_dates(p_dob date, p_doj date) returns void
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_today date := public.employee_today_ist();
begin
  if p_dob is not null and p_dob < date '1900-01-01' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: date_of_birth');
  end if;
  if p_dob is not null and p_dob >= v_today then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Future date: date_of_birth');
  end if;
  if p_doj is not null and p_doj > v_today then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Future date: date_of_joining');
  end if;
  if p_dob is not null and p_doj is not null and p_doj < p_dob then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Before birth date: date_of_joining');
  end if;
end $$;

-- Unique violation -> MORAYA_CONFLICT naming the field, never whose record it is.
create or replace function public.employee_raise_conflict(p_constraint text) returns void
language plpgsql
set search_path = public, pg_temp
as $$
begin
  perform public.moraya_fail('MORAYA_CONFLICT',
    case
      when p_constraint in ('employees_employee_id_key', 'employees_employee_id_ci_key') then 'Already in use: employee_id'
      when p_constraint = 'employees_login_email_key'  then 'Already in use: login_email'
      when p_constraint = 'employees_auth_user_id_key' then 'Already in use: auth_user_id'
      else 'Already exists'
    end);
end $$;

-- Can this caller change details / status of this target at all?
--   main_admin target : only the main_admin himself or herself
--   sub_admin target  : main_admin only
--   worker target     : yes (the caller was already checked for employee_management)
create or replace function public.employee_is_manageable(
  p_actor_id uuid, p_actor_role public.user_role, p_target_id uuid, p_target_role public.user_role
) returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$
  select case p_target_role
    when 'main_admin' then p_actor_id = p_target_id
    when 'sub_admin'  then p_actor_role = 'main_admin'
    else true
  end;
$$;

-- What the screen may offer for one target (the UI never decides this itself).
create or replace function public.employee_caps(
  p_actor_id uuid, p_actor_role public.user_role,
  p_target_id uuid, p_target_role public.user_role, p_target_status public.account_status
) returns jsonb
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_main   boolean := p_actor_role = 'main_admin';
  v_manage boolean := public.employee_is_manageable(p_actor_id, p_actor_role, p_target_id, p_target_role);
  v_t_main boolean := p_target_role = 'main_admin';
begin
  return jsonb_build_object(
    'can_edit',                v_manage,
    'can_change_aadhaar',      v_manage,
    'can_reveal_aadhaar',      v_main,
    'can_deactivate',          v_manage and not v_t_main and p_target_status = 'active',
    'can_reactivate',          v_manage and not v_t_main
                               and (p_target_status = 'inactive' or (p_target_status = 'revoked' and v_main)),
    'can_revoke',              v_main and not v_t_main and p_target_status <> 'revoked',
    'can_promote',             v_main and p_target_role = 'worker' and p_target_status = 'active',
    'can_change_role',         v_main and p_target_role = 'sub_admin',
    'can_change_permissions',  v_main and p_target_role = 'sub_admin',
    'can_view_activity',       v_main,
    'is_protected_main_admin', v_t_main
  );
end $$;

-- The full employee object returned by get_employee and every write function.
-- Never contains the encrypted Aadhaar, its hash or the full number.
create or replace function public.employee_detail_json(
  p_actor_id uuid, p_actor_role public.user_role, p_target_id uuid
) returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  r record;
begin
  select e.*,
         c.name as created_by_name,
         coalesce((select array_agg(p.permission order by p.permission)
                     from public.sub_admin_permissions p where p.employee_id = e.id), '{}'::text[]) as perms,
         (select max(a.created_at) from public.audit_logs a
           where a.actor_employee_id = e.id and a.action = 'LOGIN_SUCCESS') as last_login
    into r
    from public.employees e
    left join public.employees c on c.id = e.created_by
   where e.id = p_target_id;

  if not found then return null; end if;

  return jsonb_build_object(
    'id',               r.id,
    'sr_no',            r.sr_no,
    'employee_id',      r.employee_id,
    'name',             r.name,
    'login_email',      r.login_email::text,
    'designation',      r.designation,
    'role',             r.role,
    'account_status',   r.account_status,
    'date_of_joining',  r.date_of_joining,
    'date_of_birth',    r.date_of_birth,
    'aadhaar_masked',   coalesce(public.mask_aadhaar(r.aadhaar_last4), ''),
    'permissions',      to_jsonb(r.perms),
    'last_login_at',    r.last_login,
    'created_at',       r.created_at,
    'created_by_name',  r.created_by_name,
    'updated_at',       r.updated_at,
    'version',          r.version,
    'capabilities',     public.employee_caps(p_actor_id, p_actor_role, r.id, r.role, r.account_status)
  );
end $$;

-- =====================================================================================
-- 3. create_employee
--    The Worker creates the Supabase Auth user FIRST and passes its id. If this function
--    fails, the Worker must delete that Auth user again (this transaction rolls back).
--    Required: employee_id (3-30 of A-Z 0-9 / -, stored uppercase), name (2-100),
--    login_email (must equal the Auth user's email), designation (2-60), date_of_birth
--    (past), date_of_joining (not future, not before birth), aadhaar (12 digits, see 012).
--    p_aadhaar_key is the Worker's AADHAAR_ENC_KEY, passed per call (see 012).
--    p_role 'worker' (default) must have no permissions; 'sub_admin' (main_admin only)
--    needs at least one. Audit: USER_CREATED, plus SUBADMIN_CREATED for a sub_admin.
--    Returns {employee: <detail object>}.
--    Errors: MORAYA_FORBIDDEN, MORAYA_VALIDATION, MORAYA_CONFLICT (employee id, e-mail,
--            Aadhaar or Auth user already used), MORAYA_INVALID_STATE (no Aadhaar key)
-- =====================================================================================
create or replace function public.create_employee(
  p_actor_auth_id    uuid,
  p_new_auth_user_id uuid,
  p_employee_id      text,
  p_name             text,
  p_login_email      text,
  p_designation      text,
  p_date_of_birth    date,
  p_date_of_joining  date,
  p_aadhaar          text,
  p_aadhaar_key      text,
  p_role             text default 'worker',
  p_permissions      text[] default null,
  p_request_id       text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor      public.employees;
  v_role       text;
  v_perms      text[];
  v_code       text;
  v_name       text;
  v_email      text;
  v_desig      text;
  v_auth_email text;
  v_new_id     uuid;
  v_last4      text;
  v_constraint text;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['employee_management']);

  v_role := lower(btrim(coalesce(p_role, '')));
  if v_role not in ('worker', 'sub_admin') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: role');
  end if;
  if v_role = 'sub_admin' and v_actor.role <> 'main_admin' then
    perform public.moraya_fail('MORAYA_FORBIDDEN');
  end if;

  v_perms := public.employee_clean_perms(p_permissions);
  if v_role = 'sub_admin' and cardinality(v_perms) = 0 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Required: permissions');
  end if;
  if v_role = 'worker' and cardinality(v_perms) > 0 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Not allowed: permissions');
  end if;

  if p_new_auth_user_id is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Required: auth_user_id');
  end if;

  v_code := public.app_settings_clean(to_jsonb(p_employee_id), 'employee_id', 30, true, '^[A-Za-z0-9/-]+$', 'upper');
  if char_length(v_code) < 3 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too short: employee_id');
  end if;

  v_name := public.app_settings_clean(to_jsonb(p_name), 'name', 100, true);
  if char_length(v_name) < 2 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too short: name');
  end if;

  v_email := lower(btrim(coalesce(p_login_email, '')));
  if v_email = '' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Required: login_email');
  end if;
  if char_length(v_email) > 254 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too long: login_email');
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: login_email');
  end if;

  v_desig := public.app_settings_clean(to_jsonb(p_designation), 'designation', 60, true);
  if char_length(v_desig) < 2 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too short: designation');
  end if;

  if p_date_of_birth is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Required: date_of_birth');
  end if;
  if p_date_of_joining is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Required: date_of_joining');
  end if;
  perform public.employee_validate_dates(p_date_of_birth, p_date_of_joining);

  -- Fail on a bad Aadhaar or a missing key before anything is written.
  perform public.aadhaar_normalize(p_aadhaar);
  perform public.aadhaar_require_key(p_aadhaar_key);

  -- The Auth user must exist and carry the same e-mail (the 002 trigger enforces the same,
  -- but with a plain message the Worker cannot map).
  select u.email into v_auth_email from auth.users u where u.id = p_new_auth_user_id;
  if not found then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: auth_user_id');
  end if;
  if lower(coalesce(v_auth_email, '')) <> v_email then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: login_email');
  end if;

  begin
    insert into public.employees
      (auth_user_id, employee_id, name, login_email, role, account_status,
       designation, date_of_birth, date_of_joining, created_by)
    values
      (p_new_auth_user_id, v_code, v_name, v_email, v_role::public.user_role, 'active',
       v_desig, p_date_of_birth, p_date_of_joining, v_actor.id)
    returning id into v_new_id;
  exception when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    perform public.employee_raise_conflict(v_constraint);
  end;

  -- Encrypts, stores last 4 + blind index; raises MORAYA_CONFLICT for a duplicate Aadhaar.
  v_last4 := public.set_employee_aadhaar(v_new_id, p_aadhaar, p_aadhaar_key);

  if v_role = 'sub_admin' then
    insert into public.sub_admin_permissions (employee_id, permission)
    select v_new_id, x from unnest(v_perms) as x;
  end if;

  perform public.write_audit(
    v_actor.id, 'USER_CREATED', 'employee', v_new_id::text,
    null,
    jsonb_build_object('employee_code', v_code, 'name', v_name, 'login_email', v_email,
                       'role', v_role, 'designation', v_desig,
                       'date_of_birth', p_date_of_birth, 'date_of_joining', p_date_of_joining,
                       'aadhaar_masked', public.mask_aadhaar(v_last4)),
    null, p_request_id,
    'Created employee ' || v_code || ' (' || v_name || ')'
  );

  if v_role = 'sub_admin' then
    perform public.write_audit(
      v_actor.id, 'SUBADMIN_CREATED', 'employee', v_new_id::text,
      null,
      jsonb_build_object('employee_code', v_code, 'permissions', to_jsonb(v_perms)),
      null, p_request_id,
      'Made ' || v_code || ' (' || v_name || ') a sub admin with ' || array_to_string(v_perms, ', ')
    );
  end if;

  return jsonb_build_object('employee', public.employee_detail_json(v_actor.id, v_actor.role, v_new_id));
end $$;

-- =====================================================================================
-- 4. update_employee
--    p_patch may hold ONLY: name, employee_id, designation, date_of_birth,
--    date_of_joining, aadhaar. Any other key (role, status, permissions, login_email,
--    phone, ...) is MORAYA_VALIDATION 'Not allowed: <key>'. login_email is not here
--    because the Auth e-mail would have to change with it.
--    name / employee_id / aadhaar cannot be null; designation and the two dates may be
--    cleared with null.
--    p_version is the version the screen loaded; a different current version is
--    MORAYA_CONFLICT 'VERSION_CONFLICT'. Nothing changed (same values) -> returns the
--    current object, writes no audit row and does not raise the version.
--    p_aadhaar_key is needed only when the patch holds aadhaar.
--    Audit: USER_UPDATED for the other fields (old and new values of the changed fields
--    only), USER_AADHAAR_CHANGED for Aadhaar (masked last 4 only, never the number).
--    Returns {employee: <detail object>}.
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND, MORAYA_VALIDATION, MORAYA_CONFLICT,
--            MORAYA_INVALID_STATE (no Aadhaar key)
-- =====================================================================================
create or replace function public.update_employee(
  p_actor_auth_id uuid,
  p_employee_id   uuid,
  p_version       integer,
  p_patch         jsonb,
  p_aadhaar_key   text default null,
  p_request_id    text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor        public.employees;
  v_t            public.employees;
  r              record;
  v_name         text;
  v_code         text;
  v_desig        text;
  v_dob          date;
  v_doj          date;
  v_dates_in     boolean := false;
  v_aadhaar_in   boolean := false;
  v_aadhaar_txt  text;
  v_aadhaar_hash bytea;
  v_aadhaar_chg  boolean := false;
  v_old_last4    text;
  v_new_last4    text;
  v_old          jsonb := '{}'::jsonb;
  v_new          jsonb := '{}'::jsonb;
  v_constraint   text;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['employee_management']);

  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: patch');
  end if;
  if p_version is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Required: version');
  end if;
  for r in select k as key from jsonb_object_keys(p_patch) as k loop
    if r.key not in ('name', 'employee_id', 'designation', 'date_of_birth', 'date_of_joining', 'aadhaar') then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Not allowed: ' || left(r.key, 40));
    end if;
  end loop;

  select * into v_t from public.employees e where e.id = p_employee_id for update;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Employee not found');
  end if;
  if not public.employee_is_manageable(v_actor.id, v_actor.role, v_t.id, v_t.role) then
    perform public.moraya_fail('MORAYA_FORBIDDEN');
  end if;
  if v_t.version <> p_version then
    perform public.moraya_fail('MORAYA_CONFLICT', 'VERSION_CONFLICT');
  end if;

  v_name  := v_t.name;
  v_code  := v_t.employee_id;
  v_desig := v_t.designation;
  v_dob   := v_t.date_of_birth;
  v_doj   := v_t.date_of_joining;

  if p_patch ? 'name' then
    v_name := public.app_settings_clean(p_patch -> 'name', 'name', 100, true);
    if char_length(v_name) < 2 then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Too short: name');
    end if;
  end if;

  if p_patch ? 'employee_id' then
    v_code := public.app_settings_clean(p_patch -> 'employee_id', 'employee_id', 30, true, '^[A-Za-z0-9/-]+$', 'upper');
    if char_length(v_code) < 3 then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Too short: employee_id');
    end if;
  end if;

  if p_patch ? 'designation' then
    v_desig := public.app_settings_clean(p_patch -> 'designation', 'designation', 60, false);
    if v_desig is not null and char_length(v_desig) < 2 then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Too short: designation');
    end if;
  end if;

  if p_patch ? 'date_of_birth' then
    v_dob := public.employee_parse_date(p_patch -> 'date_of_birth', 'date_of_birth');
    v_dates_in := true;
  end if;
  if p_patch ? 'date_of_joining' then
    v_doj := public.employee_parse_date(p_patch -> 'date_of_joining', 'date_of_joining');
    v_dates_in := true;
  end if;
  if v_dates_in then
    perform public.employee_validate_dates(v_dob, v_doj);
  end if;

  if p_patch ? 'aadhaar' then
    if jsonb_typeof(p_patch -> 'aadhaar') <> 'string' then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Required: aadhaar');
    end if;
    v_aadhaar_in  := true;
    v_aadhaar_txt := public.aadhaar_normalize(p_patch ->> 'aadhaar');
    perform public.aadhaar_require_key(p_aadhaar_key);
    v_aadhaar_hash := public.aadhaar_blind_index(v_aadhaar_txt, p_aadhaar_key);
    -- Same number as the one on file is not a change (no fake audit row).
    v_aadhaar_chg := v_t.aadhaar_hash is distinct from v_aadhaar_hash;
  end if;

  -- Changed fields only, for the update and the audit row.
  if v_name is distinct from v_t.name then
    v_old := v_old || jsonb_build_object('name', v_t.name);
    v_new := v_new || jsonb_build_object('name', v_name);
  end if;
  if v_code is distinct from v_t.employee_id then
    v_old := v_old || jsonb_build_object('employee_code', v_t.employee_id);
    v_new := v_new || jsonb_build_object('employee_code', v_code);
  end if;
  if v_desig is distinct from v_t.designation then
    v_old := v_old || jsonb_build_object('designation', v_t.designation);
    v_new := v_new || jsonb_build_object('designation', v_desig);
  end if;
  if v_dob is distinct from v_t.date_of_birth then
    v_old := v_old || jsonb_build_object('date_of_birth', v_t.date_of_birth);
    v_new := v_new || jsonb_build_object('date_of_birth', v_dob);
  end if;
  if v_doj is distinct from v_t.date_of_joining then
    v_old := v_old || jsonb_build_object('date_of_joining', v_t.date_of_joining);
    v_new := v_new || jsonb_build_object('date_of_joining', v_doj);
  end if;

  if v_new = '{}'::jsonb and not v_aadhaar_chg then
    return jsonb_build_object('employee', public.employee_detail_json(v_actor.id, v_actor.role, v_t.id));
  end if;

  if v_new <> '{}'::jsonb then
    begin
      update public.employees e set
        name = v_name, employee_id = v_code, designation = v_desig,
        date_of_birth = v_dob, date_of_joining = v_doj
      where e.id = v_t.id;
    exception when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      perform public.employee_raise_conflict(v_constraint);
    end;

    perform public.write_audit(
      v_actor.id, 'USER_UPDATED', 'employee', v_t.id::text,
      v_old, v_new, null, p_request_id,
      public.audit_diff_summary('Changed employee ' || v_code || ':', v_old, v_new)
    );
  end if;

  if v_aadhaar_chg then
    v_old_last4 := v_t.aadhaar_last4;
    v_new_last4 := public.set_employee_aadhaar(v_t.id, v_aadhaar_txt, p_aadhaar_key);
    perform public.write_audit(
      v_actor.id, 'USER_AADHAAR_CHANGED', 'employee', v_t.id::text,
      jsonb_build_object('aadhaar_masked', public.mask_aadhaar(v_old_last4)),
      jsonb_build_object('aadhaar_masked', public.mask_aadhaar(v_new_last4)),
      null, p_request_id,
      'Replaced Aadhaar of ' || v_code || ' (' || v_name || ')'
    );
  end if;

  return jsonb_build_object('employee', public.employee_detail_json(v_actor.id, v_actor.role, v_t.id));
end $$;

-- =====================================================================================
-- 5. set_employee_status
--    p_new_status: 'active' | 'inactive' | 'revoked' (lowercase, as stored).
--    The Worker maps its actions: deactivate -> inactive, reactivate -> active,
--    revoke -> revoked.
--    Allowed moves:  active -> inactive, active -> revoked, inactive -> active,
--                    inactive -> revoked, revoked -> active.
--    Same status again is MORAYA_INVALID_STATE.
--    Reason: required (5-500) for inactive and revoked, optional for active.
--    To REVOKE, or to reactivate a REVOKED employee: main_admin only.
--    The main_admin's status can never change.
--    Audit: USER_DEACTIVATED / USER_REVOKED / USER_REACTIVATED.
--    Returns {employee, auth_user_id, previous_status}. After inactive or revoked the
--    Worker must end that person's sessions (and ban the Auth user); after active, unban.
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND, MORAYA_VALIDATION, MORAYA_INVALID_STATE
-- =====================================================================================
create or replace function public.set_employee_status(
  p_actor_auth_id uuid,
  p_employee_id   uuid,
  p_new_status    text,
  p_reason        text default null,
  p_request_id    text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  public.employees;
  v_t      public.employees;
  v_new    text;
  v_reason text;
  v_action text;
  v_verb   text;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['employee_management']);

  v_new := lower(btrim(coalesce(p_new_status, '')));
  if v_new not in ('active', 'inactive', 'revoked') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: status');
  end if;
  v_reason := public.employee_clean_reason(p_reason, v_new in ('inactive', 'revoked'));

  select * into v_t from public.employees e where e.id = p_employee_id for update;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Employee not found');
  end if;

  if v_t.role = 'main_admin'
     or not public.employee_is_manageable(v_actor.id, v_actor.role, v_t.id, v_t.role) then
    perform public.moraya_fail('MORAYA_FORBIDDEN');
  end if;
  if (v_new = 'revoked' or v_t.account_status = 'revoked') and v_actor.role <> 'main_admin' then
    perform public.moraya_fail('MORAYA_FORBIDDEN');
  end if;
  if v_t.account_status::text = v_new then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'Employee is already ' || v_new);
  end if;

  update public.employees e set account_status = v_new::public.account_status where e.id = v_t.id;

  v_action := case v_new when 'inactive' then 'USER_DEACTIVATED'
                         when 'revoked'  then 'USER_REVOKED'
                         else 'USER_REACTIVATED' end;
  v_verb   := case v_new when 'inactive' then 'Deactivated'
                         when 'revoked'  then 'Revoked access of'
                         else 'Reactivated' end;

  perform public.write_audit(
    v_actor.id, v_action, 'employee', v_t.id::text,
    jsonb_build_object('account_status', v_t.account_status::text),
    jsonb_build_object('account_status', v_new),
    v_reason, p_request_id,
    v_verb || ' ' || v_t.employee_id || ' (' || v_t.name || ')'
  );

  return jsonb_build_object(
    'employee',        public.employee_detail_json(v_actor.id, v_actor.role, v_t.id),
    'auth_user_id',    v_t.auth_user_id,
    'previous_status', v_t.account_status
  );
end $$;

-- =====================================================================================
-- 6. promote_to_sub_admin  (main_admin only)
--    Target must be an ACTIVE worker. At least one permission is required (frontend rule).
--    Reason optional (max 500). Audit: SUBADMIN_CREATED.
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND, MORAYA_VALIDATION, MORAYA_INVALID_STATE
-- =====================================================================================
create or replace function public.promote_to_sub_admin(
  p_actor_auth_id uuid,
  p_employee_id   uuid,
  p_permissions   text[],
  p_reason        text default null,
  p_request_id    text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  public.employees;
  v_t      public.employees;
  v_perms  text[];
  v_reason text;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, true, null);

  v_perms := public.employee_clean_perms(p_permissions);
  if cardinality(v_perms) = 0 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Required: permissions');
  end if;
  v_reason := public.employee_clean_reason(p_reason, false);

  select * into v_t from public.employees e where e.id = p_employee_id for update;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Employee not found');
  end if;
  if v_t.role <> 'worker' then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'Only a worker can be made a sub admin');
  end if;
  if v_t.account_status <> 'active' then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'Employee must be active');
  end if;

  -- Role first: trigger 003 only accepts permission rows for an existing sub_admin.
  update public.employees e set role = 'sub_admin' where e.id = v_t.id;
  insert into public.sub_admin_permissions (employee_id, permission)
  select v_t.id, x from unnest(v_perms) as x;

  perform public.write_audit(
    v_actor.id, 'SUBADMIN_CREATED', 'employee', v_t.id::text,
    jsonb_build_object('role', 'worker', 'permissions', '[]'::jsonb),
    jsonb_build_object('role', 'sub_admin', 'permissions', to_jsonb(v_perms)),
    v_reason, p_request_id,
    'Made ' || v_t.employee_id || ' (' || v_t.name || ') a sub admin with ' || array_to_string(v_perms, ', ')
  );

  return jsonb_build_object('employee', public.employee_detail_json(v_actor.id, v_actor.role, v_t.id));
end $$;

-- =====================================================================================
-- 7. revoke_sub_admin  (main_admin only): sub_admin -> worker
--    Permission rows are deleted by trigger 003 when the role changes. account_status is
--    not touched. Audit: SUBADMIN_REVOKED (old permissions recorded).
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND, MORAYA_VALIDATION, MORAYA_INVALID_STATE
-- =====================================================================================
create or replace function public.revoke_sub_admin(
  p_actor_auth_id uuid,
  p_employee_id   uuid,
  p_reason        text default null,
  p_request_id    text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  public.employees;
  v_t      public.employees;
  v_old    text[];
  v_reason text;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, true, null);
  v_reason := public.employee_clean_reason(p_reason, false);

  select * into v_t from public.employees e where e.id = p_employee_id for update;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Employee not found');
  end if;
  if v_t.role <> 'sub_admin' then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'Employee is not a sub admin');
  end if;

  select coalesce(array_agg(p.permission order by p.permission), '{}'::text[]) into v_old
    from public.sub_admin_permissions p where p.employee_id = v_t.id;

  update public.employees e set role = 'worker' where e.id = v_t.id;

  perform public.write_audit(
    v_actor.id, 'SUBADMIN_REVOKED', 'employee', v_t.id::text,
    jsonb_build_object('role', 'sub_admin', 'permissions', to_jsonb(v_old)),
    jsonb_build_object('role', 'worker', 'permissions', '[]'::jsonb),
    v_reason, p_request_id,
    'Removed sub admin role from ' || v_t.employee_id || ' (' || v_t.name || ')'
  );

  return jsonb_build_object('employee', public.employee_detail_json(v_actor.id, v_actor.role, v_t.id));
end $$;

-- =====================================================================================
-- 8. set_permissions  (main_admin only)
--    Replaces the whole permission set of a sub_admin. At least one permission is
--    required (to take everything away, use revoke_sub_admin). Names are checked against
--    the seven known permissions. Same set again: nothing is written.
--    Audit: SUBADMIN_PERMISSIONS_CHANGED (old and new sets, summary says added/removed).
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND, MORAYA_VALIDATION, MORAYA_INVALID_STATE
-- =====================================================================================
create or replace function public.set_permissions(
  p_actor_auth_id uuid,
  p_employee_id   uuid,
  p_permissions   text[],
  p_reason        text default null,
  p_request_id    text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor   public.employees;
  v_t       public.employees;
  v_new     text[];
  v_old     text[];
  v_added   text[];
  v_removed text[];
  v_reason  text;
  v_summary text;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, true, null);

  v_new := public.employee_clean_perms(p_permissions);
  if cardinality(v_new) = 0 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Required: permissions');
  end if;
  v_reason := public.employee_clean_reason(p_reason, false);

  select * into v_t from public.employees e where e.id = p_employee_id for update;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Employee not found');
  end if;
  if v_t.role <> 'sub_admin' then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'Employee is not a sub admin');
  end if;

  select coalesce(array_agg(p.permission order by p.permission), '{}'::text[]) into v_old
    from public.sub_admin_permissions p where p.employee_id = v_t.id;

  if v_old = v_new then
    return jsonb_build_object('employee', public.employee_detail_json(v_actor.id, v_actor.role, v_t.id));
  end if;

  select coalesce(array_agg(x order by x), '{}'::text[]) into v_added   from unnest(v_new) as x where x <> all (v_old);
  select coalesce(array_agg(x order by x), '{}'::text[]) into v_removed from unnest(v_old) as x where x <> all (v_new);

  delete from public.sub_admin_permissions p
   where p.employee_id = v_t.id and p.permission <> all (v_new);
  insert into public.sub_admin_permissions (employee_id, permission)
  select v_t.id, x from unnest(v_added) as x;

  -- Touch the employee row so its version and updated_at move (screens holding the old
  -- permission list then see a version conflict on their next save).
  update public.employees e set updated_at = now() where e.id = v_t.id;

  v_summary := 'Changed permissions of ' || v_t.employee_id || ' (' || v_t.name || ')';
  if cardinality(v_added) > 0 then
    v_summary := v_summary || '; added: ' || array_to_string(v_added, ', ');
  end if;
  if cardinality(v_removed) > 0 then
    v_summary := v_summary || '; removed: ' || array_to_string(v_removed, ', ');
  end if;

  perform public.write_audit(
    v_actor.id, 'SUBADMIN_PERMISSIONS_CHANGED', 'employee', v_t.id::text,
    jsonb_build_object('permissions', to_jsonb(v_old)),
    jsonb_build_object('permissions', to_jsonb(v_new)),
    v_reason, p_request_id, v_summary
  );

  return jsonb_build_object('employee', public.employee_detail_json(v_actor.id, v_actor.role, v_t.id));
end $$;

-- =====================================================================================
-- 9. get_employee
--    employee_management or main_admin. Returns {employee: <detail object>}.
--    Aadhaar is masked ('XXXX XXXX 1234', or '' when none). Reading is not audited.
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND
-- =====================================================================================
create or replace function public.get_employee(
  p_actor_auth_id uuid,
  p_employee_id   uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor public.employees;
  v_json  jsonb;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['employee_management']);
  v_json  := public.employee_detail_json(v_actor.id, v_actor.role, p_employee_id);
  if v_json is null then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Employee not found');
  end if;
  return jsonb_build_object('employee', v_json);
end $$;

-- =====================================================================================
-- 10. list_employees
--    p_q        search in name or employee id (case-insensitive, max 100 characters;
--               % _ and \ are matched literally)
--    p_status   'active' (default) | 'inactive' | 'revoked' | 'all'
--    p_role     null | 'worker' | 'sub_admin' | 'main_admin'
--    p_sort     '<field>:<asc|desc>'; field one of name, employee_id, sr_no, designation,
--               date_of_joining, role, account_status. Default 'name:asc'. Ties by sr_no.
--    p_page     1 and up. p_page_size: capped to 1..100 (default 20); the used size is returned.
--    Returns {items[], page, page_size, total, totals{active,inactive,revoked},
--             capabilities{can_create, can_assign_role}}
--      items[]: id, sr_no, employee_id, name, login_email, designation, role,
--               account_status, date_of_joining, aadhaar_masked, capabilities{can_edit,
--               can_deactivate, can_reactivate}
--      total = rows matching the filters; totals = counts across ALL employees.
--    employee_management or main_admin. Aadhaar is only ever masked.
--    Errors: MORAYA_FORBIDDEN, MORAYA_VALIDATION
-- =====================================================================================
create or replace function public.list_employees(
  p_actor_auth_id uuid,
  p_q             text    default null,
  p_status        text    default 'active',
  p_role          text    default null,
  p_sort          text    default 'name:asc',
  p_page          integer default 1,
  p_page_size     integer default 20
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor    public.employees;
  v_q        text := btrim(coalesce(p_q, ''));
  v_pat      text;
  v_status   text := lower(btrim(coalesce(p_status, 'active')));
  v_role     text := nullif(lower(btrim(coalesce(p_role, ''))), '');
  v_field    text;
  v_dir      text;
  v_col      text;
  v_page     int;
  v_size     int;
  v_total    bigint;
  v_active   bigint;
  v_inactive bigint;
  v_revoked  bigint;
  v_items    jsonb;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['employee_management']);

  if v_status not in ('active', 'inactive', 'revoked', 'all') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: status');
  end if;
  if v_role is not null and v_role not in ('worker', 'sub_admin', 'main_admin') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: role');
  end if;
  if char_length(v_q) > 100 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too long: q');
  end if;
  if v_q <> '' then
    v_pat := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  v_field := lower(btrim(split_part(coalesce(p_sort, 'name:asc'), ':', 1)));
  v_dir   := lower(btrim(split_part(coalesce(p_sort, 'name:asc'), ':', 2)));
  if v_dir = '' then v_dir := 'asc'; end if;
  if v_dir not in ('asc', 'desc') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: sort');
  end if;
  v_col := case v_field
             when 'name'            then 'e.name'
             when 'employee_id'     then 'e.employee_id'
             when 'sr_no'           then 'e.sr_no'
             when 'designation'     then 'e.designation'
             when 'date_of_joining' then 'e.date_of_joining'
             when 'role'            then 'e.role'
             when 'account_status'  then 'e.account_status'
             else null end;
  if v_col is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: sort');
  end if;

  v_page := greatest(1, least(coalesce(p_page, 1), 100000));
  v_size := greatest(1, least(coalesce(p_page_size, 20), 100));

  -- One pass: filtered total + the three status totals (which ignore the filters).
  select count(*) filter (where (v_status = 'all' or e.account_status::text = v_status)
                            and (v_role is null or e.role::text = v_role)
                            and (v_pat is null or e.name ilike v_pat escape '\' or e.employee_id ilike v_pat escape '\')),
         count(*) filter (where e.account_status = 'active'),
         count(*) filter (where e.account_status = 'inactive'),
         count(*) filter (where e.account_status = 'revoked')
    into v_total, v_active, v_inactive, v_revoked
    from public.employees e;

  -- Only v_col / v_dir (both from the whitelist above) are spliced into the text.
  execute format($sql$
    select coalesce(jsonb_agg(s.item order by s.rn), '[]'::jsonb)
      from (
        select row_number() over (order by %1$s %2$s nulls last, e.sr_no asc) as rn,
               jsonb_build_object(
                 'id',              e.id,
                 'sr_no',           e.sr_no,
                 'employee_id',     e.employee_id,
                 'name',            e.name,
                 'login_email',     e.login_email::text,
                 'designation',     e.designation,
                 'role',            e.role,
                 'account_status',  e.account_status,
                 'date_of_joining', e.date_of_joining,
                 'aadhaar_masked',  coalesce(public.mask_aadhaar(e.aadhaar_last4), ''),
                 'capabilities',    jsonb_build_object(
                     'can_edit',         c.caps -> 'can_edit',
                     'can_deactivate',   c.caps -> 'can_deactivate',
                     'can_reactivate',   c.caps -> 'can_reactivate')
               ) as item
          from public.employees e
         cross join lateral (select public.employee_caps($1, $2, e.id, e.role, e.account_status) as caps) c
         where ($3 = 'all' or e.account_status::text = $3)
           and ($4::text is null or e.role::text = $4)
           and ($5::text is null or e.name ilike $5 escape '\' or e.employee_id ilike $5 escape '\')
         order by %1$s %2$s nulls last, e.sr_no asc
         limit $6 offset $7
      ) s
  $sql$, v_col, v_dir)
  into v_items
  using v_actor.id, v_actor.role, v_status, v_role, v_pat, v_size, (v_page - 1) * v_size;

  return jsonb_build_object(
    'items',     v_items,
    'page',      v_page,
    'page_size', v_size,
    'total',     v_total,
    'totals',    jsonb_build_object('active', v_active, 'inactive', v_inactive, 'revoked', v_revoked),
    'capabilities', jsonb_build_object('can_create', true, 'can_assign_role', v_actor.role = 'main_admin')
  );
end $$;

-- =====================================================================================
-- 11. Grants: service_role only
-- =====================================================================================
revoke all on function public.employee_today_ist()                                          from public, anon, authenticated, service_role;
revoke all on function public.employee_parse_date(jsonb, text)                              from public, anon, authenticated, service_role;
revoke all on function public.employee_clean_perms(text[])                                  from public, anon, authenticated, service_role;
revoke all on function public.employee_clean_reason(text, boolean)                          from public, anon, authenticated, service_role;
revoke all on function public.employee_validate_dates(date, date)                           from public, anon, authenticated, service_role;
revoke all on function public.employee_raise_conflict(text)                                 from public, anon, authenticated, service_role;
revoke all on function public.employee_is_manageable(uuid, public.user_role, uuid, public.user_role)
                                                                                            from public, anon, authenticated, service_role;
revoke all on function public.employee_caps(uuid, public.user_role, uuid, public.user_role, public.account_status)
                                                                                            from public, anon, authenticated, service_role;
revoke all on function public.employee_detail_json(uuid, public.user_role, uuid)            from public, anon, authenticated, service_role;

revoke all on function public.create_employee(uuid, uuid, text, text, text, text, date, date, text, text, text, text[], text)
                                                                                            from public, anon, authenticated;
revoke all on function public.update_employee(uuid, uuid, integer, jsonb, text, text)      from public, anon, authenticated;
revoke all on function public.set_employee_status(uuid, uuid, text, text, text)            from public, anon, authenticated;
revoke all on function public.promote_to_sub_admin(uuid, uuid, text[], text, text)         from public, anon, authenticated;
revoke all on function public.revoke_sub_admin(uuid, uuid, text, text)                     from public, anon, authenticated;
revoke all on function public.set_permissions(uuid, uuid, text[], text, text)              from public, anon, authenticated;
revoke all on function public.get_employee(uuid, uuid)                                     from public, anon, authenticated;
revoke all on function public.list_employees(uuid, text, text, text, text, integer, integer)
                                                                                            from public, anon, authenticated;

grant execute on function public.create_employee(uuid, uuid, text, text, text, text, date, date, text, text, text, text[], text) to service_role;
grant execute on function public.update_employee(uuid, uuid, integer, jsonb, text, text)      to service_role;
grant execute on function public.set_employee_status(uuid, uuid, text, text, text)            to service_role;
grant execute on function public.promote_to_sub_admin(uuid, uuid, text[], text, text)         to service_role;
grant execute on function public.revoke_sub_admin(uuid, uuid, text, text)                     to service_role;
grant execute on function public.set_permissions(uuid, uuid, text[], text, text)              to service_role;
grant execute on function public.get_employee(uuid, uuid)                                     to service_role;
grant execute on function public.list_employees(uuid, text, text, text, text, integer, integer) to service_role;