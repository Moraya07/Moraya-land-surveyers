-- 018_income.sql
-- PURPOSE   : Site income. The income_transactions table plus the RPCs the Worker calls
--             (service_role only): create_income, update_income, cancel_income, get_income,
--             list_income.
-- DEPENDS ON: 001 (set_updated_at), 002 (employees), 003 (permissions), 008 (write_audit,
--             moraya_require_actor, moraya_fail, audit_diff_summary, audit_rupees, audit
--             actions INCOME_CREATED / INCOME_UPDATED / INCOME_CANCELLED), 010
--             (app_settings_clean), 013 (employee_today_ist, employee_parse_date,
--             employee_clean_reason), 014 (sites).
-- ROLLBACK  : drop function public.list_income(uuid,uuid,text,date,date,text,text,integer,integer);
--             drop function public.get_income(uuid,uuid);
--             drop function public.cancel_income(uuid,uuid,integer,text,text);
--             drop function public.update_income(uuid,uuid,integer,jsonb,text,text);
--             drop function public.create_income(uuid,uuid,date,bigint,text,bigint,text,text);
--             drop function public.income_json(uuid);
--             drop function public.income_parse_money(jsonb,text,bigint);
--             drop function public.income_status_for(bigint,bigint);
--             drop table public.income_transactions;   -- DESTROYS all income (020+ read it)
--             drop function public.income_protect();
--             drop function public.income_bump_version();
--             drop function public.income_block_delete();
--             drop type public.income_status;
--
-- WHAT AN INCOME TRANSACTION IS: money a client owes or has paid for a site. Entered by
--   admins only; workers never see income (no worker function exists in this file).
--   amount          the full amount billed/expected, paise, 1 .. 1,000,000,000,000
--   received_amount how much of it has actually arrived, paise, 0 .. amount
--
-- STATUS (lowercase; display labels PENDING / RECEIVED / PARTIALLY_RECEIVED / CANCELLED)
--   The status is DERIVED from the two amounts by the functions and CHECKED by a table
--   constraint, so it can never disagree with the money:
--     pending             received_amount = 0
--     partially_received  0 < received_amount < amount
--     received            received_amount = amount
--     cancelled           set only by cancel_income; received_amount is kept as it was
--   A cancelled transaction is final: nothing on it can change any more (trigger).
--   Official totals (received income, pending income) are defined in 020, not here.
--
-- WHO MAY DO WHAT: main_admin, or sub_admin with income_management, for every function.
--   Everyone else (workers, other sub admins, inactive accounts) gets MORAYA_FORBIDDEN.
--
-- RULES
--   * The site must exist. Any site status is accepted (payments arrive after a site is
--     completed). The site of a transaction never changes: to move money to another site,
--     cancel and create again.
--   * income_date: not in the future (Asia/Kolkata), not before 2000-01-01; default today.
--   * description 2-300 characters (required); remarks up to 1000.
--   * Changing the AMOUNT requires a reason (5-500 characters). Other edits: reason optional.
--   * Lowering the amount below received_amount is refused ('Invalid: amount').
--   * version rises on every update; update_income / cancel_income can be given the version
--     the screen was loaded with (MORAYA_CONFLICT 'VERSION_CONFLICT' if different).
--     update_income requires it; cancel_income treats it as optional.
--   * Never deleted or truncated (trigger and grants); cancel instead.
--
-- ERROR DETAILS: 'Required: <field>', 'Invalid: <field>', 'Not allowed: <field>',
--   'Too short|Too long: <field>', 'Future date: income_date', 'VERSION_CONFLICT',
--   'Income not found', 'Site not found'.

-- =====================================================================================
-- 1. Status enum
-- =====================================================================================
do $$ begin
  create type public.income_status as enum ('pending', 'received', 'partially_received', 'cancelled');
exception when duplicate_object then null; end $$;

-- =====================================================================================
-- 2. income_transactions
-- =====================================================================================
create table if not exists public.income_transactions (
  id               uuid primary key default gen_random_uuid(),
  site_id          uuid not null references public.sites(id),
  income_date      date not null default ((now() at time zone 'Asia/Kolkata')::date),
  amount           bigint not null,
  received_amount  bigint not null default 0,
  description      text not null,
  remarks          text,
  status           public.income_status not null default 'pending',
  version          integer not null default 1,
  cancelled_at     timestamptz,
  cancelled_by     uuid references public.employees(id),
  cancel_reason    text,
  created_by       uuid not null references public.employees(id),
  updated_by       uuid references public.employees(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint income_amount_range      check (amount > 0 and amount <= 1000000000000),
  constraint income_received_range    check (received_amount >= 0 and received_amount <= amount),
  constraint income_date_floor        check (income_date >= date '2000-01-01'),
  constraint income_description_len   check (char_length(description) between 2 and 300 and description = btrim(description)),
  constraint income_remarks_len       check (remarks is null or char_length(remarks) between 1 and 1000),
  constraint income_cancel_reason_len check (cancel_reason is null or char_length(cancel_reason) between 1 and 1000),
  constraint income_version_positive  check (version >= 1),

  -- Status always agrees with the money (cancelled is the one free-standing status).
  constraint income_status_consistent check (
       (status = 'pending'            and received_amount = 0)
    or (status = 'partially_received' and received_amount > 0 and received_amount < amount)
    or (status = 'received'           and received_amount = amount)
    or  status = 'cancelled'),

  -- Cancel fields exist exactly when the status is cancelled.
  constraint income_cancel_fields
    check ((status = 'cancelled')
           = (cancelled_at is not null and cancelled_by is not null
              and char_length(btrim(coalesce(cancel_reason, ''))) > 0)
       and (status = 'cancelled'
            or (cancelled_at is null and cancelled_by is null and cancel_reason is null)))
);

-- Indexes (one line each: which screen or report needs it)
-- Income of one site, newest first (site page, site income reports, site net balance).
create index if not exists income_site_date_idx   on public.income_transactions (site_id, income_date desc);
-- Status filter + newest first (income list tabs, pending income).
create index if not exists income_status_date_idx on public.income_transactions (status, income_date desc);
-- Date-range totals and reports.
create index if not exists income_date_idx        on public.income_transactions (income_date desc);

drop trigger if exists income_set_updated_at on public.income_transactions;
create trigger income_set_updated_at before update on public.income_transactions
  for each row execute function public.set_updated_at();

create or replace function public.income_bump_version() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.version := old.version + 1;
  return new;
end $$;

drop trigger if exists income_bump_version on public.income_transactions;
create trigger income_bump_version before update on public.income_transactions
  for each row execute function public.income_bump_version();

-- Identity never changes; a cancelled transaction is final.
create or replace function public.income_protect() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.id <> old.id or new.site_id <> old.site_id or new.created_by <> old.created_by
     or new.created_at <> old.created_at then
    raise exception using errcode = 'P0001', message = 'MORAYA_INVALID_STATE',
      detail = 'An income transaction''s id, site, creator and creation time cannot change';
  end if;
  if old.status = 'cancelled' then
    raise exception using errcode = 'P0001', message = 'MORAYA_INVALID_STATE',
      detail = 'A cancelled income transaction cannot be changed';
  end if;
  return new;
end $$;

drop trigger if exists income_protect on public.income_transactions;
create trigger income_protect before update on public.income_transactions
  for each row execute function public.income_protect();

-- Never deleted or truncated.
create or replace function public.income_block_delete() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception using errcode = 'P0001', message = 'MORAYA_INVALID_STATE',
    detail = 'Income cannot be deleted; cancel the transaction instead';
end $$;

drop trigger if exists income_no_delete on public.income_transactions;
create trigger income_no_delete before delete on public.income_transactions
  for each row execute function public.income_block_delete();
drop trigger if exists income_no_truncate on public.income_transactions;
create trigger income_no_truncate before truncate on public.income_transactions
  for each statement execute function public.income_block_delete();

-- =====================================================================================
-- 3. RLS and grants (clients never read tables; the Worker reads through RPCs)
-- =====================================================================================
alter table public.income_transactions enable row level security;
-- No policies for anon / authenticated: default deny.

revoke all on public.income_transactions from public, anon, authenticated, service_role;
grant select on public.income_transactions to service_role;   -- writes only through the functions below

revoke all on function public.income_bump_version() from public, anon, authenticated, service_role;
revoke all on function public.income_protect()      from public, anon, authenticated, service_role;
revoke all on function public.income_block_delete() from public, anon, authenticated, service_role;

-- =====================================================================================
-- 4. Internal helpers (no grant to anyone)
-- =====================================================================================

-- The one place that turns the two amounts into a status.
create or replace function public.income_status_for(p_amount bigint, p_received bigint)
returns public.income_status
language sql
immutable
set search_path = public, pg_temp
as $$
  select case when p_received = 0         then 'pending'::public.income_status
              when p_received >= p_amount then 'received'::public.income_status
              else 'partially_received'::public.income_status end;
$$;

-- jsonb value from a patch -> paise. Must be a JSON whole number >= p_min, <= 1e12.
create or replace function public.income_parse_money(p_value jsonb, p_field text, p_min bigint)
returns bigint
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_num numeric;
begin
  if p_value is null or jsonb_typeof(p_value) <> 'number' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: ' || p_field);
  end if;
  v_num := (p_value #>> '{}')::numeric;
  if v_num <> trunc(v_num) or v_num < p_min or v_num > 1000000000000 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: ' || p_field);
  end if;
  return v_num::bigint;
end $$;

-- The income object returned by every function.
create or replace function public.income_json(p_id uuid)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  r record;
begin
  select i.*, s.site_name, s.client_name, s.site_location,
         c.name as created_by_name, x.name as cancelled_by_name
    into r
    from public.income_transactions i
    join public.sites s on s.id = i.site_id
    left join public.employees c on c.id = i.created_by
    left join public.employees x on x.id = i.cancelled_by
   where i.id = p_id;
  if not found then return null; end if;

  return jsonb_build_object(
    'id',              r.id,
    'site',            jsonb_build_object('id', r.site_id, 'site_name', r.site_name,
                                          'site_location', r.site_location, 'client_name', r.client_name),
    'income_date',     r.income_date,
    'amount',          r.amount,
    'received_amount', r.received_amount,
    'pending_amount',  case when r.status = 'cancelled' then 0 else r.amount - r.received_amount end,
    'description',     r.description,
    'remarks',         r.remarks,
    'status',          r.status,
    'version',         r.version,
    'cancelled_at',    r.cancelled_at,
    'cancelled_by_name', r.cancelled_by_name,
    'cancel_reason',   r.cancel_reason,
    'created_by_name', r.created_by_name,
    'created_at',      r.created_at,
    'updated_at',      r.updated_at,
    'capabilities',    jsonb_build_object('can_edit', r.status <> 'cancelled', 'can_cancel', r.status <> 'cancelled')
  );
end $$;

revoke all on function public.income_status_for(bigint, bigint)          from public, anon, authenticated, service_role;
revoke all on function public.income_parse_money(jsonb, text, bigint)    from public, anon, authenticated, service_role;
revoke all on function public.income_json(uuid)                          from public, anon, authenticated, service_role;

-- =====================================================================================
-- 5. create_income
--    Required: p_site_id, p_amount (paise > 0), p_description. Optional: p_income_date
--    (default today in India), p_received_amount (default 0, must be <= amount),
--    p_remarks. Status is derived (pending / partially_received / received).
--    Audit: INCOME_CREATED. Returns {income}.
--    Errors: MORAYA_FORBIDDEN, MORAYA_VALIDATION, MORAYA_NOT_FOUND ('Site not found')
-- =====================================================================================
create or replace function public.create_income(
  p_actor_auth_id   uuid,
  p_site_id         uuid,
  p_income_date     date,
  p_amount          bigint,
  p_description     text,
  p_received_amount bigint default 0,
  p_remarks         text   default null,
  p_request_id      text   default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor    public.employees;
  v_site     text;
  v_date     date;
  v_desc     text;
  v_remarks  text;
  v_received bigint := coalesce(p_received_amount, 0);
  v_status   public.income_status;
  v_id       uuid;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['income_management']);

  if p_site_id is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Required: site_id');
  end if;
  select s.site_name into v_site from public.sites s where s.id = p_site_id for share;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Site not found');
  end if;

  if p_amount is null or p_amount <= 0 or p_amount > 1000000000000 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: amount');
  end if;
  if v_received < 0 or v_received > p_amount then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: received_amount');
  end if;

  v_date := coalesce(p_income_date, public.employee_today_ist());
  if v_date < date '2000-01-01' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: income_date');
  end if;
  if v_date > public.employee_today_ist() then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Future date: income_date');
  end if;

  v_desc := public.app_settings_clean(to_jsonb(p_description), 'description', 300, true);
  if char_length(v_desc) < 2 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too short: description');
  end if;
  v_remarks := public.app_settings_clean(to_jsonb(p_remarks), 'remarks', 1000, false);

  v_status := public.income_status_for(p_amount, v_received);

  insert into public.income_transactions
    (site_id, income_date, amount, received_amount, description, remarks, status, created_by, updated_by)
  values
    (p_site_id, v_date, p_amount, v_received, v_desc, v_remarks, v_status, v_actor.id, v_actor.id)
  returning id into v_id;

  perform public.write_audit(
    v_actor.id, 'INCOME_CREATED', 'income', v_id::text,
    null,
    jsonb_build_object('site_id', p_site_id, 'income_date', v_date, 'amount', p_amount,
                       'received_amount', v_received, 'status', v_status::text,
                       'description', v_desc, 'remarks', v_remarks),
    null, p_request_id,
    'Added income ' || public.audit_rupees(p_amount) || ' for ' || v_site
      || ' (received ' || public.audit_rupees(v_received) || ')'
  );

  return jsonb_build_object('income', public.income_json(v_id));
end $$;

-- =====================================================================================
-- 6. update_income
--    p_patch may hold ONLY: income_date, amount, received_amount, description, remarks
--    (remarks: string or null). The site cannot change. Any other key is MORAYA_VALIDATION
--    'Not allowed: <key>'. p_version must equal the current version.
--    A change of AMOUNT requires p_reason (5-500). Other changes: reason optional.
--    Status is re-derived from the new amounts. A cancelled transaction cannot be edited
--    (MORAYA_INVALID_STATE). Nothing changed -> returned as is, no audit row, no new version.
--    Audit: INCOME_UPDATED with old and new values of the changed fields.
--    Returns {income}.
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND, MORAYA_VALIDATION, MORAYA_INVALID_STATE,
--            MORAYA_CONFLICT
-- =====================================================================================
create or replace function public.update_income(
  p_actor_auth_id uuid,
  p_income_id     uuid,
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
  v_actor   public.employees;
  v_i       public.income_transactions;
  r         record;
  v_date    date;
  v_amount  bigint;
  v_recv    bigint;
  v_desc    text;
  v_remarks text;
  v_status  public.income_status;
  v_reason  text;
  v_old     jsonb := '{}'::jsonb;
  v_new     jsonb := '{}'::jsonb;
  v_old_s   jsonb := '{}'::jsonb;   -- same, with money as rupee text (summary only)
  v_new_s   jsonb := '{}'::jsonb;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['income_management']);

  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: patch');
  end if;
  if p_version is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Required: version');
  end if;
  for r in select k as key from jsonb_object_keys(p_patch) as k loop
    if r.key not in ('income_date', 'amount', 'received_amount', 'description', 'remarks') then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Not allowed: ' || left(r.key, 40));
    end if;
  end loop;

  select * into v_i from public.income_transactions i where i.id = p_income_id for update;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Income not found');
  end if;
  if v_i.status = 'cancelled' then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'A cancelled income transaction cannot be changed');
  end if;
  if v_i.version <> p_version then
    perform public.moraya_fail('MORAYA_CONFLICT', 'VERSION_CONFLICT');
  end if;

  v_date := v_i.income_date; v_amount := v_i.amount; v_recv := v_i.received_amount;
  v_desc := v_i.description; v_remarks := v_i.remarks;

  if p_patch ? 'income_date' then
    if jsonb_typeof(p_patch -> 'income_date') <> 'string' then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Required: income_date');
    end if;
    v_date := public.employee_parse_date(p_patch -> 'income_date', 'income_date');
    if v_date is null or v_date < date '2000-01-01' then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: income_date');
    end if;
    if v_date > public.employee_today_ist() then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Future date: income_date');
    end if;
  end if;
  if p_patch ? 'amount' then
    v_amount := public.income_parse_money(p_patch -> 'amount', 'amount', 1);
  end if;
  if p_patch ? 'received_amount' then
    v_recv := public.income_parse_money(p_patch -> 'received_amount', 'received_amount', 0);
  end if;
  if v_recv > v_amount then
    perform public.moraya_fail('MORAYA_VALIDATION',
      case when p_patch ? 'received_amount' then 'Invalid: received_amount' else 'Invalid: amount' end);
  end if;
  if p_patch ? 'description' then
    v_desc := public.app_settings_clean(p_patch -> 'description', 'description', 300, true);
    if char_length(v_desc) < 2 then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Too short: description');
    end if;
  end if;
  if p_patch ? 'remarks' then
    v_remarks := public.app_settings_clean(p_patch -> 'remarks', 'remarks', 1000, false);
  end if;

  -- Reason: required when the amount changes.
  v_reason := public.employee_clean_reason(p_reason, v_amount is distinct from v_i.amount);

  if v_date is distinct from v_i.income_date then
    v_old := v_old || jsonb_build_object('income_date', v_i.income_date);
    v_new := v_new || jsonb_build_object('income_date', v_date);
  end if;
  if v_desc is distinct from v_i.description then
    v_old := v_old || jsonb_build_object('description', v_i.description);
    v_new := v_new || jsonb_build_object('description', v_desc);
  end if;
  if v_remarks is distinct from v_i.remarks then
    v_old := v_old || jsonb_build_object('remarks', v_i.remarks);
    v_new := v_new || jsonb_build_object('remarks', v_remarks);
  end if;
  v_old_s := v_old; v_new_s := v_new;
  if v_amount is distinct from v_i.amount then
    v_old   := v_old   || jsonb_build_object('amount', v_i.amount);
    v_new   := v_new   || jsonb_build_object('amount', v_amount);
    v_old_s := v_old_s || jsonb_build_object('amount', public.audit_rupees(v_i.amount));
    v_new_s := v_new_s || jsonb_build_object('amount', public.audit_rupees(v_amount));
  end if;
  if v_recv is distinct from v_i.received_amount then
    v_old   := v_old   || jsonb_build_object('received_amount', v_i.received_amount);
    v_new   := v_new   || jsonb_build_object('received_amount', v_recv);
    v_old_s := v_old_s || jsonb_build_object('received amount', public.audit_rupees(v_i.received_amount));
    v_new_s := v_new_s || jsonb_build_object('received amount', public.audit_rupees(v_recv));
  end if;

  if v_new = '{}'::jsonb then
    return jsonb_build_object('income', public.income_json(v_i.id));
  end if;

  v_status := public.income_status_for(v_amount, v_recv);
  if v_status is distinct from v_i.status then
    v_old   := v_old   || jsonb_build_object('status', v_i.status::text);
    v_new   := v_new   || jsonb_build_object('status', v_status::text);
    v_old_s := v_old_s || jsonb_build_object('status', v_i.status::text);
    v_new_s := v_new_s || jsonb_build_object('status', v_status::text);
  end if;

  update public.income_transactions i set
    income_date = v_date, amount = v_amount, received_amount = v_recv,
    description = v_desc, remarks = v_remarks, status = v_status, updated_by = v_actor.id
  where i.id = v_i.id;

  perform public.write_audit(
    v_actor.id, 'INCOME_UPDATED', 'income', v_i.id::text,
    v_old, v_new, v_reason, p_request_id,
    public.audit_diff_summary('Changed income:', v_old_s, v_new_s)
  );

  return jsonb_build_object('income', public.income_json(v_i.id));
end $$;

-- =====================================================================================
-- 7. cancel_income
--    Any transaction that is not already cancelled. p_reason required (5-500). The money
--    fields are kept as they were (history); cancelled income is excluded from every
--    official total (020). p_version optional (VERSION_CONFLICT if given and different).
--    Audit: INCOME_CANCELLED. Returns {income, previous_status}.
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND, MORAYA_VALIDATION, MORAYA_INVALID_STATE,
--            MORAYA_CONFLICT
-- =====================================================================================
create or replace function public.cancel_income(
  p_actor_auth_id uuid,
  p_income_id     uuid,
  p_version       integer default null,
  p_reason        text    default null,
  p_request_id    text    default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  public.employees;
  v_i      public.income_transactions;
  v_reason text;
  v_site   text;
begin
  v_actor  := public.moraya_require_actor(p_actor_auth_id, false, array['income_management']);
  v_reason := public.employee_clean_reason(p_reason, true);

  select * into v_i from public.income_transactions i where i.id = p_income_id for update;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Income not found');
  end if;
  if v_i.status = 'cancelled' then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'Income is already cancelled');
  end if;
  if p_version is not null and p_version <> v_i.version then
    perform public.moraya_fail('MORAYA_CONFLICT', 'VERSION_CONFLICT');
  end if;

  select s.site_name into v_site from public.sites s where s.id = v_i.site_id;

  update public.income_transactions i set
    status = 'cancelled', cancelled_at = now(), cancelled_by = v_actor.id,
    cancel_reason = v_reason, updated_by = v_actor.id
  where i.id = v_i.id;

  perform public.write_audit(
    v_actor.id, 'INCOME_CANCELLED', 'income', v_i.id::text,
    jsonb_build_object('status', v_i.status::text, 'amount', v_i.amount, 'received_amount', v_i.received_amount),
    jsonb_build_object('status', 'cancelled'),
    v_reason, p_request_id,
    'Cancelled income ' || public.audit_rupees(v_i.amount) || ' for ' || coalesce(v_site, '-')
      || ' (received ' || public.audit_rupees(v_i.received_amount) || ')'
  );

  return jsonb_build_object('income', public.income_json(v_i.id), 'previous_status', v_i.status);
end $$;

-- =====================================================================================
-- 8. get_income
--    Returns {income}. Reading is not audited.
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND
-- =====================================================================================
create or replace function public.get_income(
  p_actor_auth_id uuid,
  p_income_id     uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_json jsonb;
begin
  perform public.moraya_require_actor(p_actor_auth_id, false, array['income_management']);
  v_json := public.income_json(p_income_id);
  if v_json is null then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Income not found');
  end if;
  return jsonb_build_object('income', v_json);
end $$;

-- =====================================================================================
-- 9. list_income
--    p_site_id   one site or null
--    p_status    'all' (default) | 'pending' | 'partially_received' | 'received' | 'cancelled'
--    p_date_from / p_date_to  income_date range, inclusive
--    p_q         search in description, remarks, site name, client name (max 100;
--                % _ and \ are literal)
--    p_sort      '<field>:<asc|desc>'; field one of income_date, amount, received_amount,
--                status, created_at. Default 'income_date:desc'. Ties by created_at desc.
--    p_page 1 and up; p_page_size capped 1..100 (default 20), the size used is returned
--    Returns {items[], page, page_size, total, totals{pending, partially_received, received,
--             cancelled}, capabilities{can_create, can_edit}}
--      items[]: the same fields as income_json without cancel details and capabilities.
--      total = rows matching all filters; totals = COUNTS per status over the filters except
--      the status filter. Money sums are not returned here: official totals live in 020.
--    Errors: MORAYA_FORBIDDEN, MORAYA_VALIDATION
-- =====================================================================================
create or replace function public.list_income(
  p_actor_auth_id uuid,
  p_site_id       uuid    default null,
  p_status        text    default 'all',
  p_date_from     date    default null,
  p_date_to       date    default null,
  p_q             text    default null,
  p_sort          text    default 'income_date:desc',
  p_page          integer default 1,
  p_page_size     integer default 20
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status  text := lower(btrim(coalesce(p_status, 'all')));
  v_q       text := btrim(coalesce(p_q, ''));
  v_pat     text;
  v_field   text;
  v_dir     text;
  v_order   text;
  v_page    int;
  v_size    int;
  v_from    text;
  v_sql     text;
  v_total   bigint;
  v_pending bigint; v_partial bigint; v_received bigint; v_cancelled bigint;
  v_items   jsonb;
begin
  perform public.moraya_require_actor(p_actor_auth_id, false, array['income_management']);

  if v_status not in ('all', 'pending', 'partially_received', 'received', 'cancelled') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: status');
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

  v_field := lower(btrim(split_part(coalesce(p_sort, 'income_date:desc'), ':', 1)));
  v_dir   := lower(btrim(split_part(coalesce(p_sort, 'income_date:desc'), ':', 2)));
  if v_dir = '' then v_dir := 'asc'; end if;
  if v_dir not in ('asc', 'desc') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: sort');
  end if;
  v_order := case v_field
    when 'income_date'     then 'i.income_date ' || v_dir
    when 'amount'          then 'i.amount ' || v_dir
    when 'received_amount' then 'i.received_amount ' || v_dir
    when 'status'          then 'i.status ' || v_dir
    when 'created_at'      then 'i.created_at ' || v_dir
    else null end;
  if v_order is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: sort');
  end if;
  v_order := v_order || ', i.created_at desc, i.id';

  v_page := greatest(1, least(coalesce(p_page, 1), 100000));
  v_size := greatest(1, least(coalesce(p_page_size, 20), 100));

  -- $1 site, $2 from, $3 to, $4 pattern
  v_from := $f$
      from public.income_transactions i
      join public.sites s on s.id = i.site_id
     where ($1::uuid is null or i.site_id = $1)
       and ($2::date is null or i.income_date >= $2)
       and ($3::date is null or i.income_date <= $3)
       and ($4::text is null or i.description ilike $4 escape '\'
                             or i.remarks ilike $4 escape '\'
                             or s.site_name ilike $4 escape '\'
                             or s.client_name ilike $4 escape '\')
  $f$;

  v_sql := 'select count(*) filter (where $5::text = ''all'' or i.status::text = $5::text),
                   count(*) filter (where i.status = ''pending''),
                   count(*) filter (where i.status = ''partially_received''),
                   count(*) filter (where i.status = ''received''),
                   count(*) filter (where i.status = ''cancelled'') ' || v_from;
  execute v_sql
    into v_total, v_pending, v_partial, v_received, v_cancelled
    using p_site_id, p_date_from, p_date_to, v_pat, v_status;

  v_sql := 'select coalesce(jsonb_agg(jsonb_build_object(
              ''id'', p.id,
              ''site'', jsonb_build_object(''id'', p.site_id, ''site_name'', p.site_name,
                                          ''site_location'', p.site_location, ''client_name'', p.client_name),
              ''income_date'', p.income_date, ''amount'', p.amount, ''received_amount'', p.received_amount,
              ''pending_amount'', case when p.status = ''cancelled'' then 0 else p.amount - p.received_amount end,
              ''description'', p.description, ''remarks'', p.remarks, ''status'', p.status,
              ''version'', p.version, ''created_at'', p.created_at
            ) order by p.rn), ''[]''::jsonb)
            from (
              select row_number() over (order by ' || v_order || ') as rn,
                     i.id, i.site_id, s.site_name, s.site_location, s.client_name,
                     i.income_date, i.amount, i.received_amount, i.description, i.remarks,
                     i.status, i.version, i.created_at '
            || v_from
            || ' and ($5::text = ''all'' or i.status::text = $5::text)
                 order by ' || v_order || '
                 limit $6 offset $7) p';
  execute v_sql
    into v_items
    using p_site_id, p_date_from, p_date_to, v_pat, v_status, v_size, (v_page - 1) * v_size;

  return jsonb_build_object(
    'items',     v_items,
    'page',      v_page,
    'page_size', v_size,
    'total',     v_total,
    'totals',    jsonb_build_object('pending', v_pending, 'partially_received', v_partial,
                                    'received', v_received, 'cancelled', v_cancelled),
    'capabilities', jsonb_build_object('can_create', true, 'can_edit', true)
  );
end $$;

-- =====================================================================================
-- 10. Grants: service_role only
-- =====================================================================================
revoke all on function public.create_income(uuid, uuid, date, bigint, text, bigint, text, text) from public, anon, authenticated;
revoke all on function public.update_income(uuid, uuid, integer, jsonb, text, text)             from public, anon, authenticated;
revoke all on function public.cancel_income(uuid, uuid, integer, text, text)                    from public, anon, authenticated;
revoke all on function public.get_income(uuid, uuid)                                            from public, anon, authenticated;
revoke all on function public.list_income(uuid, uuid, text, date, date, text, text, integer, integer)
  from public, anon, authenticated;

grant execute on function public.create_income(uuid, uuid, date, bigint, text, bigint, text, text) to service_role;
grant execute on function public.update_income(uuid, uuid, integer, jsonb, text, text)             to service_role;
grant execute on function public.cancel_income(uuid, uuid, integer, text, text)                    to service_role;
grant execute on function public.get_income(uuid, uuid)                                            to service_role;
grant execute on function public.list_income(uuid, uuid, text, date, date, text, text, integer, integer)
  to service_role;