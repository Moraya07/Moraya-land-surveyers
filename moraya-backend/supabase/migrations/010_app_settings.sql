-- 010_app_settings.sql
-- PURPOSE   : Company details, bank details, bill prefix and the "workers can see salary"
--             switch, kept in ONE row. Read and written only through RPC functions.
-- DEPENDS ON: 001 (set_updated_at), 002 (employees), 008 (write_audit, moraya_require_actor,
--             moraya_fail, SETTINGS_UPDATED).
-- ROLLBACK  : drop function public.update_app_settings(uuid,jsonb,text);
--             drop function public.get_public_settings(uuid);
--             drop function public.get_app_settings(uuid);
--             drop function public.app_settings_as_json();
--             drop function public.app_settings_clean(jsonb,text,int,boolean,text,text,text);
--             drop table public.app_settings;
-- NOTES     : Added beyond the prompt's field list: tagline (the line under the company
--             name on the sample invoice). Bank details are all optional until the
--             Main Admin fills them in; formats are checked when present.

-- =====================================================================================
-- 1. Table (exactly one row, id is always 1)
-- =====================================================================================
create table if not exists public.app_settings (
  id                      smallint primary key default 1 check (id = 1),
  company_name            text    not null check (char_length(btrim(company_name)) between 1 and 200),
  tagline                 text    check (tagline is null or char_length(tagline) <= 200),
  address                 text    check (address is null or char_length(address) <= 500),
  phones                  text[]  not null default '{}' check (cardinality(phones) <= 4),
  email                   text    check (email is null or (char_length(email) <= 200
                                          and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
  pan                     text    check (pan is null or pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  bank_name               text    check (bank_name is null or char_length(bank_name) <= 200),
  account_holder          text    check (account_holder is null or char_length(account_holder) <= 200),
  account_number          text    check (account_number is null or account_number ~ '^[0-9]{9,18}$'),
  ifsc                    text    check (ifsc is null or ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$'),
  branch                  text    check (branch is null or char_length(branch) <= 200),
  bill_prefix             text    not null default 'MS' check (bill_prefix ~ '^[A-Z]{1,6}$'),
  workers_can_see_salary  boolean not null default false,
  updated_at              timestamptz not null default now(),
  updated_by              uuid references public.employees(id)
);

drop trigger if exists app_settings_set_updated_at on public.app_settings;
create trigger app_settings_set_updated_at before update on public.app_settings
  for each row execute function public.set_updated_at();

-- The single row can never be deleted or truncated.
create or replace function public.app_settings_block_delete() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'app_settings cannot be deleted' using errcode = 'P0001';
end $$;

drop trigger if exists app_settings_no_delete on public.app_settings;
create trigger app_settings_no_delete before delete on public.app_settings
  for each row execute function public.app_settings_block_delete();
drop trigger if exists app_settings_no_truncate on public.app_settings;
create trigger app_settings_no_truncate before truncate on public.app_settings
  for each statement execute function public.app_settings_block_delete();

-- Placeholder row (not real data). The Main Admin replaces it in Settings.
insert into public.app_settings (id, company_name, address, bank_name, account_holder, branch)
values (1, 'Company name (update in Settings)', 'Address (update in Settings)',
        'Bank name', 'Account holder', 'Branch')
on conflict (id) do nothing;

-- =====================================================================================
-- 2. RLS and grants (service_role reads only; all writes go through update_app_settings)
--    The explicit deny policy documents "no client access" and keeps the table from
--    showing up as "RLS on, no policy" in the 027 coverage check.
-- =====================================================================================
alter table public.app_settings enable row level security;

drop policy if exists app_settings_no_client_access on public.app_settings;
create policy app_settings_no_client_access on public.app_settings
  for all to anon, authenticated using (false) with check (false);

revoke all on public.app_settings from public, anon, authenticated;
revoke all on public.app_settings from service_role;
grant select on public.app_settings to service_role;

-- =====================================================================================
-- 3. Internal helpers
-- =====================================================================================

-- Trims, normalises and validates one text value. Raises MORAYA_VALIDATION with the
-- field name as detail. Blank or null gives null unless the field is required.
create or replace function public.app_settings_clean(
  p_value    jsonb,
  p_field    text,
  p_max      int,
  p_required boolean default false,
  p_pattern  text default null,
  p_case     text default null,
  p_strip    text default null
) returns text
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v text;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    if p_required then perform public.moraya_fail('MORAYA_VALIDATION', 'Required: ' || p_field); end if;
    return null;
  end if;
  if jsonb_typeof(p_value) <> 'string' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: ' || p_field);
  end if;

  v := btrim(p_value #>> '{}');
  if p_strip is not null then v := regexp_replace(v, p_strip, '', 'g'); end if;
  if p_case = 'upper' then v := upper(v); elsif p_case = 'lower' then v := lower(v); end if;

  if v = '' then
    if p_required then perform public.moraya_fail('MORAYA_VALIDATION', 'Required: ' || p_field); end if;
    return null;
  end if;
  if char_length(v) > p_max then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too long: ' || p_field);
  end if;
  if p_pattern is not null and v !~ p_pattern then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: ' || p_field);
  end if;
  return v;
end $$;

-- The settings row as jsonb for the Worker: every field except id and updated_by,
-- plus updated_by_name.
create or replace function public.app_settings_as_json() returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb;
begin
  select (to_jsonb(s) - 'id' - 'updated_by') || jsonb_build_object('updated_by_name', e.name)
    into v
    from public.app_settings s
    left join public.employees e on e.id = s.updated_by
   where s.id = 1;
  if v is null then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Settings row is missing');
  end if;
  return v;
end $$;

-- =====================================================================================
-- 4. get_app_settings : main_admin, or sub_admin with report_view or export
--    Returns the full company and bank details (the client bill needs them).
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND
-- =====================================================================================
create or replace function public.get_app_settings(p_actor_auth_id uuid) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.moraya_require_actor(p_actor_auth_id, false, array['report_view', 'export']);
  return public.app_settings_as_json();
end $$;

-- =====================================================================================
-- 5. get_public_settings : any active user; ONLY workers_can_see_salary
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND
-- =====================================================================================
create or replace function public.get_public_settings(p_actor_auth_id uuid) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v boolean;
begin
  perform public.moraya_require_actor(p_actor_auth_id, false, null);
  select s.workers_can_see_salary into v from public.app_settings s where s.id = 1;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Settings row is missing');
  end if;
  return jsonb_build_object('workers_can_see_salary', v);
end $$;

-- =====================================================================================
-- 6. update_app_settings : main_admin only
--    p_patch is a JSON object with any of: company_name, tagline, address, phones (array,
--    max 4), email, pan, bank_name, account_holder, account_number, ifsc, branch,
--    bill_prefix, workers_can_see_salary. Unknown keys are rejected.
--    Normalisation: text is trimmed, blank becomes null (except company_name and
--    bill_prefix), email is lowercased, pan, ifsc and bill_prefix are uppercased,
--    spaces and hyphens are removed from account_number.
--    Audit: only the changed fields are stored; account_number is masked to its last 4
--    digits by write_audit. If nothing actually changes, nothing is written or audited.
--    Returns {changed: bool, settings: {...}}.
--    Errors: MORAYA_FORBIDDEN, MORAYA_VALIDATION, MORAYA_NOT_FOUND
-- =====================================================================================
create or replace function public.update_app_settings(
  p_actor_auth_id uuid,
  p_patch         jsonb,
  p_request_id    text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor       public.employees;
  v_row         public.app_settings;
  v_old_json    jsonb;
  v_norm        jsonb := '{}'::jsonb;
  v_old_changed jsonb;
  v_new_changed jsonb;
  v_labels      text[];
  v_arr         text[];
  v_item        jsonb;
  r             record;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, true, null);

  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Send an object with at least one field');
  end if;

  for r in select key, value from jsonb_each(p_patch) loop
    case r.key
      when 'company_name' then
        v_norm := v_norm || jsonb_build_object(r.key, public.app_settings_clean(r.value, r.key, 200, true));
      when 'tagline' then
        v_norm := v_norm || jsonb_build_object(r.key, public.app_settings_clean(r.value, r.key, 200));
      when 'address' then
        v_norm := v_norm || jsonb_build_object(r.key, public.app_settings_clean(r.value, r.key, 500));
      when 'email' then
        v_norm := v_norm || jsonb_build_object(r.key, public.app_settings_clean(
          r.value, r.key, 200, false, '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$', 'lower'));
      when 'pan' then
        v_norm := v_norm || jsonb_build_object(r.key, public.app_settings_clean(
          r.value, r.key, 10, false, '^[A-Z]{5}[0-9]{4}[A-Z]$', 'upper'));
      when 'bank_name' then
        v_norm := v_norm || jsonb_build_object(r.key, public.app_settings_clean(r.value, r.key, 200));
      when 'account_holder' then
        v_norm := v_norm || jsonb_build_object(r.key, public.app_settings_clean(r.value, r.key, 200));
      when 'account_number' then
        v_norm := v_norm || jsonb_build_object(r.key, public.app_settings_clean(
          r.value, r.key, 18, false, '^[0-9]{9,18}$', null, '[ -]'));
      when 'ifsc' then
        v_norm := v_norm || jsonb_build_object(r.key, public.app_settings_clean(
          r.value, r.key, 11, false, '^[A-Z]{4}0[A-Z0-9]{6}$', 'upper'));
      when 'branch' then
        v_norm := v_norm || jsonb_build_object(r.key, public.app_settings_clean(r.value, r.key, 200));
      when 'bill_prefix' then
        v_norm := v_norm || jsonb_build_object(r.key, public.app_settings_clean(
          r.value, r.key, 6, true, '^[A-Z]{1,6}$', 'upper'));
      when 'workers_can_see_salary' then
        if jsonb_typeof(r.value) <> 'boolean' then
          perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: workers_can_see_salary');
        end if;
        v_norm := v_norm || jsonb_build_object(r.key, r.value);
      when 'phones' then
        if jsonb_typeof(r.value) <> 'array' or jsonb_array_length(r.value) > 4 then
          perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: phones');
        end if;
        v_arr := '{}';
        for v_item in select value from jsonb_array_elements(r.value) loop
          v_arr := v_arr || public.app_settings_clean(v_item, 'phones', 20, true, '^[0-9+() -]{6,20}$');
        end loop;
        v_norm := v_norm || jsonb_build_object('phones', to_jsonb(v_arr));
      else
        perform public.moraya_fail('MORAYA_VALIDATION', 'Unknown field: ' || left(r.key, 50));
    end case;
  end loop;

  select * into v_row from public.app_settings s where s.id = 1 for update;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Settings row is missing');
  end if;
  v_old_json := to_jsonb(v_row);

  select coalesce(jsonb_object_agg(k.key, v_old_json -> k.key), '{}'::jsonb),
         coalesce(jsonb_object_agg(k.key, v_norm -> k.key), '{}'::jsonb),
         array_agg(replace(k.key, '_', ' ') order by k.key)
    into v_old_changed, v_new_changed, v_labels
    from jsonb_object_keys(v_norm) as k(key)
   where (v_old_json -> k.key) is distinct from (v_norm -> k.key);

  if v_labels is null then
    return jsonb_build_object('changed', false, 'settings', public.app_settings_as_json());
  end if;

  update public.app_settings s set
    company_name   = case when v_norm ? 'company_name'   then v_norm ->> 'company_name'   else s.company_name end,
    tagline        = case when v_norm ? 'tagline'        then v_norm ->> 'tagline'        else s.tagline end,
    address        = case when v_norm ? 'address'        then v_norm ->> 'address'        else s.address end,
    phones         = case when v_norm ? 'phones'
                          then array(select jsonb_array_elements_text(v_norm -> 'phones'))
                          else s.phones end,
    email          = case when v_norm ? 'email'          then v_norm ->> 'email'          else s.email end,
    pan            = case when v_norm ? 'pan'            then v_norm ->> 'pan'            else s.pan end,
    bank_name      = case when v_norm ? 'bank_name'      then v_norm ->> 'bank_name'      else s.bank_name end,
    account_holder = case when v_norm ? 'account_holder' then v_norm ->> 'account_holder' else s.account_holder end,
    account_number = case when v_norm ? 'account_number' then v_norm ->> 'account_number' else s.account_number end,
    ifsc           = case when v_norm ? 'ifsc'           then v_norm ->> 'ifsc'           else s.ifsc end,
    branch         = case when v_norm ? 'branch'         then v_norm ->> 'branch'         else s.branch end,
    bill_prefix    = case when v_norm ? 'bill_prefix'    then v_norm ->> 'bill_prefix'    else s.bill_prefix end,
    workers_can_see_salary = case when v_norm ? 'workers_can_see_salary'
                                  then (v_norm ->> 'workers_can_see_salary')::boolean
                                  else s.workers_can_see_salary end,
    updated_by     = v_actor.id
  where s.id = 1;

  perform public.write_audit(
    v_actor.id, 'SETTINGS_UPDATED', 'settings', '1',
    v_old_changed, v_new_changed, null, p_request_id,
    'Changed settings: ' || array_to_string(v_labels, ', ')
  );

  return jsonb_build_object('changed', true, 'settings', public.app_settings_as_json());
end $$;

-- =====================================================================================
-- 7. Function grants: service_role only
-- =====================================================================================
revoke all on function public.app_settings_block_delete()                                       from public, anon, authenticated;
revoke all on function public.app_settings_clean(jsonb, text, int, boolean, text, text, text)  from public, anon, authenticated;
revoke all on function public.app_settings_as_json()                                            from public, anon, authenticated;
revoke all on function public.get_app_settings(uuid)                                            from public, anon, authenticated;
revoke all on function public.get_public_settings(uuid)                                         from public, anon, authenticated;
revoke all on function public.update_app_settings(uuid, jsonb, text)                            from public, anon, authenticated;

grant execute on function public.app_settings_clean(jsonb, text, int, boolean, text, text, text) to service_role;
grant execute on function public.app_settings_as_json()                                          to service_role;
grant execute on function public.get_app_settings(uuid)                                          to service_role;
grant execute on function public.get_public_settings(uuid)                                       to service_role;
grant execute on function public.update_app_settings(uuid, jsonb, text)                          to service_role;