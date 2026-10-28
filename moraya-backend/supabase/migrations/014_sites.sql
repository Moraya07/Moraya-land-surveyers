-- 014_sites.sql
-- PURPOSE   : Site onboarding. The sites table plus the RPCs the Worker calls (service_role only):
--               create_site, update_site, set_site_status, get_site, list_sites,
--               list_active_sites_for_worker.
--             This file is the "golden example" for the later modules: same shape for every
--             function (check caller, validate, lock, change, audit, return jsonb).
-- DEPENDS ON: 001 (set_updated_at, account_status style enums), 002 (employees),
--             003 (sub_admin_permissions), 004/008 (audit_logs, write_audit, moraya_require_actor,
--             moraya_fail, audit_diff_summary, audit_rupees, audit actions SITE_CREATED,
--             SITE_UPDATED, SITE_STATUS_CHANGED), 010 (app_settings_clean),
--             013 (employee_today_ist, the version-counter idea).
-- ROLLBACK  : drop function public.list_active_sites_for_worker(uuid,text,integer);
--             drop function public.list_sites(uuid,text,text,text,text,integer,integer);
--             drop function public.get_site(uuid,uuid);
--             drop function public.set_site_status(uuid,uuid,text,text,text);
--             drop function public.update_site(uuid,uuid,integer,jsonb,text,text);
--             drop function public.create_site(uuid,text,text,text,date,bigint,text);
--             drop function public.site_json(uuid,boolean);
--             drop function public.site_parse_rate(jsonb);
--             drop function public.site_check_rate(bigint);
--             drop function public.site_can_write(uuid,public.user_role);
--             drop table public.sites;          -- DESTROYS all sites (later tables reference it)
--             drop function public.sites_block_delete();
--             drop function public.sites_bump_version();
--             drop type public.site_status;
--
-- WHAT A SITE IS (spec section 4): sr_no, date, location, name, client name, status, and an
--   optional rate per visit (paise, used later by the client bill). NO surveyor or assistant
--   columns: those belong to work entries.
--
-- STATUSES (lowercase in the database; "Active", "Completed", "Inactive" are display labels):
--   active     workers can pick it for new work entries
--   completed  finished; history stays; not offered to workers
--   inactive   switched off; history stays; not offered to workers
--   Any status can move to any other different status (a completed site can be reopened).
--   Moving a site never touches its work entries, expenses or income.
--
-- WHO MAY DO WHAT
--   create / update / change status : main_admin, or sub_admin with site_management
--   get_site / list_sites           : the same, or sub_admin with report_view
--   list_active_sites_for_worker    : any ACTIVE employee (any role); active sites only,
--                                     minimal fields, never the rate
--   Rate per visit is visible to everyone who can call get_site / list_sites.
--
-- RULES
--   * site_name 2-150, site_location 2-200, client_name 2-150 characters, stored trimmed.
--   * The same name + client + location (ignoring case) cannot exist twice (accidental
--     double entry). A genuinely different site needs a different name or location.
--   * site_date: not in the future (Asia/Kolkata), not before 2000-01-01. Left out on
--     create it means today in India.
--   * rate_per_visit: whole paise, 0 to 1,000,000,000,000, or null (no rate yet).
--   * Sites are never deleted (blocked by trigger and by grants). Use status 'inactive'.
--   * sites.version is a counter that rises on every update; update_site needs the version
--     the screen was loaded with (MORAYA_CONFLICT 'VERSION_CONFLICT' otherwise).
--
-- ERROR DETAILS (same style as 013): 'Required: <field>', 'Too short: <field>',
--   'Too long: <field>', 'Invalid: <field>', 'Not allowed: <field>', 'Future date: site_date',
--   'Already exists: site' (MORAYA_CONFLICT), 'VERSION_CONFLICT' (MORAYA_CONFLICT).

-- =====================================================================================
-- 1. Status enum
-- =====================================================================================
do $$ begin
  create type public.site_status as enum ('active', 'completed', 'inactive');
exception when duplicate_object then null; end $$;

-- =====================================================================================
-- 2. sites
-- =====================================================================================
create table if not exists public.sites (
  id              uuid primary key default gen_random_uuid(),
  sr_no           bigint generated always as identity,
  site_date       date not null default ((now() at time zone 'Asia/Kolkata')::date),
  site_location   text not null,
  site_name       text not null,
  client_name     text not null,
  status          public.site_status not null default 'active',
  rate_per_visit  bigint,
  version         integer not null default 1,
  created_by      uuid not null references public.employees(id),
  updated_by      uuid references public.employees(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint sites_name_len        check (char_length(site_name) between 2 and 150 and site_name = btrim(site_name)),
  constraint sites_location_len    check (char_length(site_location) between 2 and 200 and site_location = btrim(site_location)),
  constraint sites_client_len      check (char_length(client_name) between 2 and 150 and client_name = btrim(client_name)),
  constraint sites_date_floor      check (site_date >= date '2000-01-01'),
  constraint sites_rate_range      check (rate_per_visit is null or (rate_per_visit >= 0 and rate_per_visit <= 1000000000000))
);

-- Serial number shown to people: unique, never reused.
create unique index if not exists sites_sr_no_key on public.sites (sr_no);
-- Accidental double entry (see RULES).
create unique index if not exists sites_identity_key
  on public.sites (lower(site_name), lower(client_name), lower(site_location));
-- Lists: status filter + newest first (the default list).
create index if not exists sites_status_date_idx on public.sites (status, site_date desc, sr_no desc);
-- Client filter on lists and, later, reports.
create index if not exists sites_client_idx on public.sites (lower(client_name));

drop trigger if exists sites_set_updated_at on public.sites;
create trigger sites_set_updated_at before update on public.sites
  for each row execute function public.set_updated_at();

create or replace function public.sites_bump_version() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.version := old.version + 1;
  return new;
end $$;

drop trigger if exists sites_bump_version on public.sites;
create trigger sites_bump_version before update on public.sites
  for each row execute function public.sites_bump_version();

-- Sites are history: never deleted, never truncated.
create or replace function public.sites_block_delete() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception using errcode = 'P0001', message = 'MORAYA_INVALID_STATE',
    detail = 'Sites cannot be deleted; set the status to inactive instead';
end $$;

drop trigger if exists sites_no_delete on public.sites;
create trigger sites_no_delete before delete on public.sites
  for each row execute function public.sites_block_delete();

drop trigger if exists sites_no_truncate on public.sites;
create trigger sites_no_truncate before truncate on public.sites
  for each statement execute function public.sites_block_delete();

-- =====================================================================================
-- 3. RLS and grants (clients never read tables; the Worker reads through RPCs)
-- =====================================================================================
alter table public.sites enable row level security;
-- No policies for anon / authenticated: default deny.

revoke all on public.sites from public, anon, authenticated, service_role;
grant select on public.sites to service_role;   -- writes only through the functions below

revoke all on function public.sites_bump_version() from public, anon, authenticated;
revoke all on function public.sites_block_delete() from public, anon, authenticated;

-- =====================================================================================
-- 4. Internal helpers (no grant to anyone; only the functions below call them)
-- =====================================================================================

-- main_admin, or a sub_admin holding site_management.
create or replace function public.site_can_write(p_actor_id uuid, p_actor_role public.user_role) returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select p_actor_role = 'main_admin'
      or (p_actor_role = 'sub_admin' and exists (
            select 1 from public.sub_admin_permissions sp
             where sp.employee_id = p_actor_id and sp.permission = 'site_management'));
$$;

-- Rate in paise: null or 0 .. 1,000,000,000,000.
create or replace function public.site_check_rate(p_rate bigint) returns bigint
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if p_rate is not null and (p_rate < 0 or p_rate > 1000000000000) then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: rate_per_visit');
  end if;
  return p_rate;
end $$;

-- jsonb value from a patch -> rate. Must be a JSON whole number (or null).
create or replace function public.site_parse_rate(p_value jsonb) returns bigint
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_num numeric;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then return null; end if;
  if jsonb_typeof(p_value) <> 'number' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: rate_per_visit');
  end if;
  v_num := (p_value #>> '{}')::numeric;
  if v_num <> trunc(v_num) or v_num < 0 or v_num > 1000000000000 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: rate_per_visit');
  end if;
  return v_num::bigint;
end $$;

-- The site object returned by every write function and by get_site.
create or replace function public.site_json(p_site_id uuid, p_can_edit boolean) returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  r record;
begin
  select s.*, c.name as created_by_name
    into r
    from public.sites s
    left join public.employees c on c.id = s.created_by
   where s.id = p_site_id;
  if not found then return null; end if;

  return jsonb_build_object(
    'id',              r.id,
    'sr_no',           r.sr_no,
    'site_date',       r.site_date,
    'site_location',   r.site_location,
    'site_name',       r.site_name,
    'client_name',     r.client_name,
    'status',          r.status,
    'rate_per_visit',  r.rate_per_visit,
    'created_by_name', r.created_by_name,
    'created_at',      r.created_at,
    'updated_at',      r.updated_at,
    'version',         r.version,
    'capabilities',    jsonb_build_object('can_edit', p_can_edit, 'can_change_status', p_can_edit)
  );
end $$;

revoke all on function public.site_can_write(uuid, public.user_role)  from public, anon, authenticated, service_role;
revoke all on function public.site_check_rate(bigint)                 from public, anon, authenticated, service_role;
revoke all on function public.site_parse_rate(jsonb)                  from public, anon, authenticated, service_role;
revoke all on function public.site_json(uuid, boolean)                from public, anon, authenticated, service_role;

-- =====================================================================================
-- 5. create_site
--    Required: p_site_name, p_client_name, p_site_location. Optional: p_site_date (default
--    today in India), p_rate_per_visit (paise). New sites start 'active'.
--    Audit: SITE_CREATED. Returns {site}.
--    Errors: MORAYA_FORBIDDEN, MORAYA_VALIDATION, MORAYA_CONFLICT ('Already exists: site')
-- =====================================================================================
create or replace function public.create_site(
  p_actor_auth_id  uuid,
  p_site_name      text,
  p_client_name    text,
  p_site_location  text,
  p_site_date      date   default null,
  p_rate_per_visit bigint default null,
  p_request_id     text   default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  public.employees;
  v_name   text;
  v_client text;
  v_loc    text;
  v_date   date;
  v_rate   bigint;
  v_id     uuid;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['site_management']);

  v_name := public.app_settings_clean(to_jsonb(p_site_name), 'site_name', 150, true);
  if char_length(v_name) < 2 then perform public.moraya_fail('MORAYA_VALIDATION', 'Too short: site_name'); end if;
  v_client := public.app_settings_clean(to_jsonb(p_client_name), 'client_name', 150, true);
  if char_length(v_client) < 2 then perform public.moraya_fail('MORAYA_VALIDATION', 'Too short: client_name'); end if;
  v_loc := public.app_settings_clean(to_jsonb(p_site_location), 'site_location', 200, true);
  if char_length(v_loc) < 2 then perform public.moraya_fail('MORAYA_VALIDATION', 'Too short: site_location'); end if;

  v_date := coalesce(p_site_date, public.employee_today_ist());
  if v_date > public.employee_today_ist() then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Future date: site_date');
  end if;
  if v_date < date '2000-01-01' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: site_date');
  end if;

  v_rate := public.site_check_rate(p_rate_per_visit);

  begin
    insert into public.sites (site_date, site_location, site_name, client_name, status, rate_per_visit, created_by, updated_by)
    values (v_date, v_loc, v_name, v_client, 'active', v_rate, v_actor.id, v_actor.id)
    returning id into v_id;
  exception when unique_violation then
    perform public.moraya_fail('MORAYA_CONFLICT', 'Already exists: site');
  end;

  perform public.write_audit(
    v_actor.id, 'SITE_CREATED', 'site', v_id::text,
    null,
    jsonb_build_object('site_name', v_name, 'client_name', v_client, 'site_location', v_loc,
                       'site_date', v_date, 'rate_per_visit', v_rate),
    null, p_request_id,
    'Created site ' || v_name || ' (' || v_client || ')'
  );

  return jsonb_build_object('site', public.site_json(v_id, true));
end $$;

-- =====================================================================================
-- 6. update_site
--    p_patch may hold ONLY: site_date, site_location, site_name, client_name,
--    rate_per_visit (whole paise number, or null to clear the rate). Status has its own
--    function. Any other key is MORAYA_VALIDATION 'Not allowed: <key>'.
--    p_version must equal the site's current version (else 'VERSION_CONFLICT').
--    Nothing changed -> returns the site as it is, no audit row, version unchanged.
--    p_reason is optional (max 500) and is stored in the audit row.
--    Audit: SITE_UPDATED with the changed fields only (rate shown in rupees in the summary).
--    Returns {site}.
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND, MORAYA_VALIDATION, MORAYA_CONFLICT
-- =====================================================================================
create or replace function public.update_site(
  p_actor_auth_id uuid,
  p_site_id       uuid,
  p_version       integer,
  p_patch         jsonb,
  p_reason        text default null,
  p_request_id    text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  public.employees;
  v_s      public.sites;
  r        record;
  v_name   text;
  v_client text;
  v_loc    text;
  v_date   date;
  v_rate   bigint;
  v_reason text;
  v_old    jsonb := '{}'::jsonb;
  v_new    jsonb := '{}'::jsonb;
  v_old_s  jsonb := '{}'::jsonb;   -- same as v_old, but the rate as rupees text (for the summary)
  v_new_s  jsonb := '{}'::jsonb;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['site_management']);

  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: patch');
  end if;
  if p_version is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Required: version');
  end if;
  for r in select k as key from jsonb_object_keys(p_patch) as k loop
    if r.key not in ('site_date', 'site_location', 'site_name', 'client_name', 'rate_per_visit') then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Not allowed: ' || left(r.key, 40));
    end if;
  end loop;
  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  if char_length(coalesce(v_reason, '')) > 500 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too long: reason');
  end if;

  select * into v_s from public.sites s where s.id = p_site_id for update;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Site not found');
  end if;
  if v_s.version <> p_version then
    perform public.moraya_fail('MORAYA_CONFLICT', 'VERSION_CONFLICT');
  end if;

  v_name := v_s.site_name; v_client := v_s.client_name; v_loc := v_s.site_location;
  v_date := v_s.site_date; v_rate := v_s.rate_per_visit;

  if p_patch ? 'site_name' then
    v_name := public.app_settings_clean(p_patch -> 'site_name', 'site_name', 150, true);
    if char_length(v_name) < 2 then perform public.moraya_fail('MORAYA_VALIDATION', 'Too short: site_name'); end if;
  end if;
  if p_patch ? 'client_name' then
    v_client := public.app_settings_clean(p_patch -> 'client_name', 'client_name', 150, true);
    if char_length(v_client) < 2 then perform public.moraya_fail('MORAYA_VALIDATION', 'Too short: client_name'); end if;
  end if;
  if p_patch ? 'site_location' then
    v_loc := public.app_settings_clean(p_patch -> 'site_location', 'site_location', 200, true);
    if char_length(v_loc) < 2 then perform public.moraya_fail('MORAYA_VALIDATION', 'Too short: site_location'); end if;
  end if;
  if p_patch ? 'site_date' then
    if jsonb_typeof(p_patch -> 'site_date') <> 'string' then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Required: site_date');
    end if;
    v_date := public.employee_parse_date(p_patch -> 'site_date', 'site_date');
    if v_date is null or v_date < date '2000-01-01' then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: site_date');
    end if;
    if v_date > public.employee_today_ist() then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Future date: site_date');
    end if;
  end if;
  if p_patch ? 'rate_per_visit' then
    v_rate := public.site_parse_rate(p_patch -> 'rate_per_visit');
  end if;

  if v_name is distinct from v_s.site_name then
    v_old := v_old || jsonb_build_object('site_name', v_s.site_name);
    v_new := v_new || jsonb_build_object('site_name', v_name);
  end if;
  if v_client is distinct from v_s.client_name then
    v_old := v_old || jsonb_build_object('client_name', v_s.client_name);
    v_new := v_new || jsonb_build_object('client_name', v_client);
  end if;
  if v_loc is distinct from v_s.site_location then
    v_old := v_old || jsonb_build_object('site_location', v_s.site_location);
    v_new := v_new || jsonb_build_object('site_location', v_loc);
  end if;
  if v_date is distinct from v_s.site_date then
    v_old := v_old || jsonb_build_object('site_date', v_s.site_date);
    v_new := v_new || jsonb_build_object('site_date', v_date);
  end if;
  v_old_s := v_old; v_new_s := v_new;
  if v_rate is distinct from v_s.rate_per_visit then
    v_old   := v_old   || jsonb_build_object('rate_per_visit', v_s.rate_per_visit);
    v_new   := v_new   || jsonb_build_object('rate_per_visit', v_rate);
    v_old_s := v_old_s || jsonb_build_object('rate_per_visit', public.audit_rupees(v_s.rate_per_visit));
    v_new_s := v_new_s || jsonb_build_object('rate_per_visit', public.audit_rupees(v_rate));
  end if;

  if v_new = '{}'::jsonb then
    return jsonb_build_object('site', public.site_json(v_s.id, true));
  end if;

  begin
    update public.sites s set
      site_name = v_name, client_name = v_client, site_location = v_loc,
      site_date = v_date, rate_per_visit = v_rate, updated_by = v_actor.id
    where s.id = v_s.id;
  exception when unique_violation then
    perform public.moraya_fail('MORAYA_CONFLICT', 'Already exists: site');
  end;

  perform public.write_audit(
    v_actor.id, 'SITE_UPDATED', 'site', v_s.id::text,
    v_old, v_new, v_reason, p_request_id,
    public.audit_diff_summary('Changed site ' || v_name || ':', v_old_s, v_new_s)
  );

  return jsonb_build_object('site', public.site_json(v_s.id, true));
end $$;

-- =====================================================================================
-- 7. set_site_status
--    p_new_status: 'active' | 'completed' | 'inactive'. Any different status is allowed;
--    the same status again is MORAYA_INVALID_STATE. Reason optional (max 500).
--    Existing work entries, expenses and income are not touched.
--    Audit: SITE_STATUS_CHANGED. Returns {site, previous_status}.
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND, MORAYA_VALIDATION, MORAYA_INVALID_STATE
-- =====================================================================================
create or replace function public.set_site_status(
  p_actor_auth_id uuid,
  p_site_id       uuid,
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
  v_s      public.sites;
  v_new    text;
  v_reason text;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['site_management']);

  v_new := lower(btrim(coalesce(p_new_status, '')));
  if v_new not in ('active', 'completed', 'inactive') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: status');
  end if;
  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  if char_length(coalesce(v_reason, '')) > 500 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too long: reason');
  end if;

  select * into v_s from public.sites s where s.id = p_site_id for update;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Site not found');
  end if;
  if v_s.status::text = v_new then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'Site is already ' || v_new);
  end if;

  update public.sites s set status = v_new::public.site_status, updated_by = v_actor.id where s.id = v_s.id;

  perform public.write_audit(
    v_actor.id, 'SITE_STATUS_CHANGED', 'site', v_s.id::text,
    jsonb_build_object('status', v_s.status::text),
    jsonb_build_object('status', v_new),
    v_reason, p_request_id,
    'Changed status of site ' || v_s.site_name || ': ' || v_s.status::text || ' -> ' || v_new
  );

  return jsonb_build_object('site', public.site_json(v_s.id, true), 'previous_status', v_s.status);
end $$;

-- =====================================================================================
-- 8. get_site
--    main_admin, or sub_admin with site_management or report_view. Returns {site}.
--    capabilities.can_edit is true only with site_management (or main_admin).
--    Reading is not audited. Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND
-- =====================================================================================
create or replace function public.get_site(
  p_actor_auth_id uuid,
  p_site_id       uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor public.employees;
  v_json  jsonb;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['site_management', 'report_view']);
  v_json  := public.site_json(p_site_id, public.site_can_write(v_actor.id, v_actor.role));
  if v_json is null then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Site not found');
  end if;
  return jsonb_build_object('site', v_json);
end $$;

-- =====================================================================================
-- 9. list_sites
--    p_q       search in site name, location or client name (case-insensitive, max 100;
--              % _ and \ are matched literally)
--    p_status  'all' (default) | 'active' | 'completed' | 'inactive'
--    p_client  exact client name (case-insensitive) or null
--    p_sort    '<field>:<asc|desc>'; field one of sr_no, site_date, site_name, client_name,
--              site_location, status. Default 'site_date:desc'. Ties by sr_no desc.
--    p_page    1 and up; p_page_size capped to 1..100 (default 20), the size used is returned
--    Returns {items[], page, page_size, total, totals{active,completed,inactive},
--             capabilities{can_create, can_edit}}
--      items[]: id, sr_no, site_date, site_location, site_name, client_name, status,
--               rate_per_visit
--      total = rows matching the filters; totals = counts across ALL sites.
--    main_admin, or sub_admin with site_management or report_view.
--    Errors: MORAYA_FORBIDDEN, MORAYA_VALIDATION
-- =====================================================================================
create or replace function public.list_sites(
  p_actor_auth_id uuid,
  p_q             text    default null,
  p_status        text    default 'all',
  p_client        text    default null,
  p_sort          text    default 'site_date:desc',
  p_page          integer default 1,
  p_page_size     integer default 20
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor     public.employees;
  v_q         text := btrim(coalesce(p_q, ''));
  v_pat       text;
  v_status    text := lower(btrim(coalesce(p_status, 'all')));
  v_client    text := nullif(btrim(coalesce(p_client, '')), '');
  v_field     text;
  v_dir       text;
  v_col       text;
  v_page      int;
  v_size      int;
  v_total     bigint;
  v_active    bigint;
  v_completed bigint;
  v_inactive  bigint;
  v_items     jsonb;
  v_can_write boolean;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['site_management', 'report_view']);
  v_can_write := public.site_can_write(v_actor.id, v_actor.role);

  if v_status not in ('all', 'active', 'completed', 'inactive') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: status');
  end if;
  if char_length(v_q) > 100 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too long: q');
  end if;
  if char_length(coalesce(v_client, '')) > 150 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too long: client');
  end if;
  if v_q <> '' then
    v_pat := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  v_field := lower(btrim(split_part(coalesce(p_sort, 'site_date:desc'), ':', 1)));
  v_dir   := lower(btrim(split_part(coalesce(p_sort, 'site_date:desc'), ':', 2)));
  if v_dir = '' then v_dir := 'asc'; end if;
  if v_dir not in ('asc', 'desc') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: sort');
  end if;
  v_col := case v_field
             when 'sr_no'         then 's.sr_no'
             when 'site_date'     then 's.site_date'
             when 'site_name'     then 's.site_name'
             when 'client_name'   then 's.client_name'
             when 'site_location' then 's.site_location'
             when 'status'        then 's.status'
             else null end;
  if v_col is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: sort');
  end if;

  v_page := greatest(1, least(coalesce(p_page, 1), 100000));
  v_size := greatest(1, least(coalesce(p_page_size, 20), 100));

  select count(*) filter (where (v_status = 'all' or s.status::text = v_status)
                            and (v_client is null or lower(s.client_name) = lower(v_client))
                            and (v_pat is null or s.site_name ilike v_pat escape '\'
                                               or s.site_location ilike v_pat escape '\'
                                               or s.client_name ilike v_pat escape '\')),
         count(*) filter (where s.status = 'active'),
         count(*) filter (where s.status = 'completed'),
         count(*) filter (where s.status = 'inactive')
    into v_total, v_active, v_completed, v_inactive
    from public.sites s;

  -- Only v_col / v_dir (both from the whitelist above) are spliced into the text.
  execute format($sql$
    select coalesce(jsonb_agg(x.item order by x.rn), '[]'::jsonb)
      from (
        select row_number() over (order by %1$s %2$s, s.sr_no desc) as rn,
               jsonb_build_object(
                 'id',             s.id,
                 'sr_no',          s.sr_no,
                 'site_date',      s.site_date,
                 'site_location',  s.site_location,
                 'site_name',      s.site_name,
                 'client_name',    s.client_name,
                 'status',         s.status,
                 'rate_per_visit', s.rate_per_visit
               ) as item
          from public.sites s
         where ($1 = 'all' or s.status::text = $1)
           and ($2::text is null or lower(s.client_name) = lower($2))
           and ($3::text is null or s.site_name ilike $3 escape '\'
                                 or s.site_location ilike $3 escape '\'
                                 or s.client_name ilike $3 escape '\')
         order by %1$s %2$s, s.sr_no desc
         limit $4 offset $5
      ) x
  $sql$, v_col, v_dir)
  into v_items
  using v_status, v_client, v_pat, v_size, (v_page - 1) * v_size;

  return jsonb_build_object(
    'items',     v_items,
    'page',      v_page,
    'page_size', v_size,
    'total',     v_total,
    'totals',    jsonb_build_object('active', v_active, 'completed', v_completed, 'inactive', v_inactive),
    'capabilities', jsonb_build_object('can_create', v_can_write, 'can_edit', v_can_write)
  );
end $$;

-- =====================================================================================
-- 10. list_active_sites_for_worker
--    For the "select a site" box on the work entry form. Any ACTIVE employee may call it.
--    Only status 'active' sites; fields id, site_name, site_location, client_name (no rate,
--    no dates, no status). Sorted by site name. p_q optional search (name, location,
--    client; max 100). p_limit default 200, capped to 1..500.
--    Returns {items[]}.   Errors: MORAYA_FORBIDDEN, MORAYA_VALIDATION
-- =====================================================================================
create or replace function public.list_active_sites_for_worker(
  p_actor_auth_id uuid,
  p_q             text    default null,
  p_limit         integer default 200
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_q     text := btrim(coalesce(p_q, ''));
  v_pat   text;
  v_limit int := greatest(1, least(coalesce(p_limit, 200), 500));
  v_items jsonb;
begin
  perform public.moraya_require_actor(p_actor_auth_id, false, null);

  if char_length(v_q) > 100 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too long: q');
  end if;
  if v_q <> '' then
    v_pat := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  select coalesce(jsonb_agg(x.item order by x.rn), '[]'::jsonb)
    into v_items
    from (
      select row_number() over (order by lower(s.site_name), s.sr_no) as rn,
             jsonb_build_object('id', s.id, 'site_name', s.site_name,
                                'site_location', s.site_location, 'client_name', s.client_name) as item
        from public.sites s
       where s.status = 'active'
         and (v_pat is null or s.site_name ilike v_pat escape '\'
                            or s.site_location ilike v_pat escape '\'
                            or s.client_name ilike v_pat escape '\')
       order by lower(s.site_name), s.sr_no
       limit v_limit
    ) x;

  return jsonb_build_object('items', v_items);
end $$;

-- =====================================================================================
-- 11. Grants: service_role only
-- =====================================================================================
revoke all on function public.create_site(uuid, text, text, text, date, bigint, text)        from public, anon, authenticated;
revoke all on function public.update_site(uuid, uuid, integer, jsonb, text, text)            from public, anon, authenticated;
revoke all on function public.set_site_status(uuid, uuid, text, text, text)                  from public, anon, authenticated;
revoke all on function public.get_site(uuid, uuid)                                           from public, anon, authenticated;
revoke all on function public.list_sites(uuid, text, text, text, text, integer, integer)     from public, anon, authenticated;
revoke all on function public.list_active_sites_for_worker(uuid, text, integer)              from public, anon, authenticated;

grant execute on function public.create_site(uuid, text, text, text, date, bigint, text)     to service_role;
grant execute on function public.update_site(uuid, uuid, integer, jsonb, text, text)         to service_role;
grant execute on function public.set_site_status(uuid, uuid, text, text, text)               to service_role;
grant execute on function public.get_site(uuid, uuid)                                        to service_role;
grant execute on function public.list_sites(uuid, text, text, text, text, integer, integer)  to service_role;
grant execute on function public.list_active_sites_for_worker(uuid, text, integer)           to service_role;