-- 024_client_bill.sql
-- PURPOSE   : The client bill (the INVOICE_MS sample): a per-financial-year bill number, the
--             client_bills table and the RPCs the Worker calls (service_role only):
--               generate_client_bill, finalize_client_bill, cancel_client_bill,
--               get_client_bill, list_client_bills
--             plus the internal next_bill_number().
-- DEPENDS ON: 002, 008 (write_audit, moraya_require_actor, moraya_fail, audit_rupees, actions
--             CLIENT_BILL_GENERATED / CLIENT_BILL_FINALIZED / CLIENT_BILL_CANCELLED),
--             010 (app_settings, app_settings_as_json), 013 (employee_clean_reason),
--             014 (sites), 020 (fin_visit_count, fin_work_facts).
-- ROLLBACK  : drop function public.list_client_bills(uuid, uuid, text, integer, integer);
--             drop function public.get_client_bill(uuid, uuid);
--             drop function public.cancel_client_bill(uuid, uuid, text, integer, text);
--             drop function public.finalize_client_bill(uuid, uuid, integer, text);
--             drop function public.generate_client_bill(uuid, uuid, date, date, text, text);
--             drop function public.client_bill_json(uuid);
--             drop function public.next_bill_number(date);
--             drop table public.client_bills;      -- DESTROYS all bills
--             drop table public.client_bill_counters;
--             drop function public.client_bills_protect();
--             drop function public.client_bills_bump_version();
--             drop function public.client_bills_block_delete();
--             drop type public.client_bill_status;
--
-- BILL NUMBER  YYYY/YY/<prefix> N   e.g. 2026/27/MS 25
--   * Financial year runs 1 April to 31 March. The year is taken from the BILL DATE (today in
--     Asia/Kolkata), not from the server clock: on 31 March 23:30 IST the bill is still in the
--     old year; at 00:00 IST on 1 April the next bill is number 1 of the new year.
--   * The sequence restarts at 1 every financial year. No zero padding (sample shows "MS 25").
--   * The prefix is bill_prefix from app_settings at the moment of generation and is stored in the
--     number, so changing the prefix later never alters old bills. The counter is per year, not per
--     prefix, so a prefix change continues the same sequence.
--   * One atomic upsert like 015: two concurrent callers never get the same number. The counter
--     moves in the caller's transaction, so a failed generation leaves no gap.
--
-- STATUS (lowercase; display labels DRAFT / FINAL / CANCELLED)
--   draft -> final (finalize), draft -> cancelled, final -> cancelled. Nothing else.
--   FINAL locks the bill: only the cancel fields can change afterwards (trigger). FINAL also stores a
--   snapshot of the company and bank details so a later settings change never rewrites an issued bill.
--   Cancelled is terminal. Bills are never deleted (trigger, no DELETE grant).
--
-- LINE ITEM (one per bill, as in the sample)
--   qty    = verified visit count for the site in [period_from, period_to] = fin_visit_count (020)
--   rate   = sites.rate_per_visit at generation, stored on the bill
--   amount = qty x rate, enforced by a CHECK. The amount in words is made in TypeScript.
--
-- ASSUMPTIONS (please confirm)
--   D1. Fails with MORAYA_VALIDATION when the site has no rate (or a rate of 0) or when the period has
--       no verified visits (qty = 0), so a zero or meaningless bill is never created.
--   D2. Overlap guard: a site cannot have two non-cancelled bills whose periods overlap (prevents
--       billing the same visits twice). Cancel the old bill to re-bill. Raises MORAYA_INVALID_STATE.
--   D3. Finalizing requires the company bank details (bank_name, account_holder, account_number, ifsc)
--       to be set in app_settings, because the bill prints them; otherwise MORAYA_VALIDATION.
--   D4. bill_date = today in Asia/Kolkata at generation. Site name, location and client name are
--       copied onto the bill so it stays the same if the site is edited.
--   D5. get_client_bill returns the visit dates (distinct verified work dates in the period) for the
--       attached "site details" list. They are read live, not frozen.
--   D6. Reading and listing are not audited (same as the other get/list functions).
--
-- ERROR CODES: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND, MORAYA_VALIDATION, MORAYA_INVALID_STATE,
--              MORAYA_CONFLICT (VERSION_CONFLICT)

-- =====================================================================================
-- 1. Status enum and counter
-- =====================================================================================
do $$ begin
  create type public.client_bill_status as enum ('draft', 'final', 'cancelled');
exception when duplicate_object then null; end $$;

create table if not exists public.client_bill_counters (
  fy_start    integer primary key check (fy_start between 2000 and 9998),
  last_number integer not null check (last_number >= 0),
  updated_at  timestamptz not null default now()
);

-- =====================================================================================
-- 2. next_bill_number (internal)
-- =====================================================================================
create or replace function public.next_bill_number(p_bill_date date default null)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_date   date := coalesce(p_bill_date, (now() at time zone 'Asia/Kolkata')::date);
  v_fy     integer;
  v_prefix text;
  v_n      integer;
begin
  v_fy := case when extract(month from v_date) >= 4
               then extract(year from v_date)::integer
               else extract(year from v_date)::integer - 1 end;

  select s.bill_prefix into v_prefix from public.app_settings s where s.id = 1;
  if v_prefix is null then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Settings row is missing');
  end if;

  insert into public.client_bill_counters as c (fy_start, last_number)
  values (v_fy, 1)
  on conflict (fy_start) do update set last_number = c.last_number + 1, updated_at = now()
  returning c.last_number into v_n;

  return v_fy::text || '/' || lpad(((v_fy + 1) % 100)::text, 2, '0') || '/' || v_prefix || ' ' || v_n::text;
end $$;

-- =====================================================================================
-- 3. client_bills
-- =====================================================================================
create table if not exists public.client_bills (
  id                  uuid primary key default gen_random_uuid(),
  bill_number         text not null unique,
  financial_year      integer not null,                     -- start year, e.g. 2026 for 2026/27
  site_id             uuid not null references public.sites(id),
  site_name           text not null,
  site_location       text not null,
  client_name         text not null,
  bill_date           date not null,
  period_from         date not null,
  period_to           date not null,
  description         text not null,
  qty                 integer not null,
  unit                text not null default 'VISIT',
  rate                bigint not null,
  amount              bigint not null,
  status              public.client_bill_status not null default 'draft',
  version             integer not null default 1,
  finalized_at        timestamptz,
  finalized_by        uuid references public.employees(id),
  settings_snapshot   jsonb,
  cancelled_at        timestamptz,
  cancelled_by        uuid references public.employees(id),
  cancel_reason       text,
  created_by          uuid not null references public.employees(id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  constraint client_bills_number_format   check (bill_number ~ '^[0-9]{4}/[0-9]{2}/[A-Z]{1,6} [0-9]+$'),
  constraint client_bills_unit            check (unit = 'VISIT'),
  constraint client_bills_qty_positive    check (qty > 0),
  constraint client_bills_rate_range      check (rate > 0 and rate <= 1000000000000),
  constraint client_bills_amount_formula  check (amount = qty::bigint * rate and amount <= 1000000000000),
  constraint client_bills_period_order    check (period_to >= period_from and period_from >= date '2000-01-01'),
  constraint client_bills_description_len check (char_length(description) between 2 and 300 and description = btrim(description)),
  constraint client_bills_version_positive check (version >= 1),
  constraint client_bills_cancel_reason_len check (cancel_reason is null or char_length(cancel_reason) between 1 and 1000),

  -- A final bill has its finalize fields and snapshot (a cancelled bill may or may not have been final).
  constraint client_bills_final_fields check (
    status <> 'final' or (finalized_at is not null and finalized_by is not null and settings_snapshot is not null)),
  constraint client_bills_draft_clean check (
    status <> 'draft' or (finalized_at is null and finalized_by is null and settings_snapshot is null)),

  -- Cancel fields exist exactly when the status is cancelled.
  constraint client_bills_cancel_fields
    check ((status = 'cancelled')
           = (cancelled_at is not null and cancelled_by is not null
              and char_length(btrim(coalesce(cancel_reason, ''))) > 0)
       and (status = 'cancelled'
            or (cancelled_at is null and cancelled_by is null and cancel_reason is null)))
);

-- Indexes (one line each: which screen needs it)
-- Bills of one site, newest first (site page, overlap check).
create index if not exists client_bills_site_idx   on public.client_bills (site_id, bill_date desc);
-- Status tabs + newest first (bill list).
create index if not exists client_bills_status_idx on public.client_bills (status, bill_date desc);

drop trigger if exists client_bills_set_updated_at on public.client_bills;
create trigger client_bills_set_updated_at before update on public.client_bills
  for each row execute function public.set_updated_at();

create or replace function public.client_bills_bump_version() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.version := old.version + 1;
  return new;
end $$;

drop trigger if exists client_bills_bump_version on public.client_bills;
create trigger client_bills_bump_version before update on public.client_bills
  for each row execute function public.client_bills_bump_version();

-- Content never changes; only draft -> final / cancelled and final -> cancelled are allowed.
create or replace function public.client_bills_protect() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if (new.id, new.bill_number, new.financial_year, new.site_id, new.site_name, new.site_location,
      new.client_name, new.bill_date, new.period_from, new.period_to, new.description, new.qty,
      new.unit, new.rate, new.amount, new.created_by, new.created_at)
     is distinct from
     (old.id, old.bill_number, old.financial_year, old.site_id, old.site_name, old.site_location,
      old.client_name, old.bill_date, old.period_from, old.period_to, old.description, old.qty,
      old.unit, old.rate, old.amount, old.created_by, old.created_at) then
    raise exception using errcode = 'P0001', message = 'MORAYA_INVALID_STATE',
      detail = 'The content of a client bill cannot change';
  end if;
  if old.status = 'cancelled' then
    raise exception using errcode = 'P0001', message = 'MORAYA_INVALID_STATE',
      detail = 'A cancelled client bill cannot be changed';
  end if;
  if old.status = 'final' and new.status <> 'cancelled' then
    raise exception using errcode = 'P0001', message = 'MORAYA_INVALID_STATE',
      detail = 'A final client bill can only be cancelled';
  end if;
  if old.status = 'final'
     and (new.finalized_at, new.finalized_by, new.settings_snapshot)
         is distinct from (old.finalized_at, old.finalized_by, old.settings_snapshot) then
    raise exception using errcode = 'P0001', message = 'MORAYA_INVALID_STATE',
      detail = 'A final client bill is locked';
  end if;
  return new;
end $$;

drop trigger if exists client_bills_protect on public.client_bills;
create trigger client_bills_protect before update on public.client_bills
  for each row execute function public.client_bills_protect();

-- Never deleted or truncated.
create or replace function public.client_bills_block_delete() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception using errcode = 'P0001', message = 'MORAYA_INVALID_STATE',
    detail = 'Client bills cannot be deleted; cancel the bill instead';
end $$;

drop trigger if exists client_bills_no_delete on public.client_bills;
create trigger client_bills_no_delete before delete on public.client_bills
  for each row execute function public.client_bills_block_delete();
drop trigger if exists client_bills_no_truncate on public.client_bills;
create trigger client_bills_no_truncate before truncate on public.client_bills
  for each statement execute function public.client_bills_block_delete();

-- =====================================================================================
-- 4. RLS and grants (clients never read tables; the Worker reads through RPCs)
-- =====================================================================================
alter table public.client_bills         enable row level security;
alter table public.client_bill_counters enable row level security;
-- No policies for anon / authenticated: default deny.

revoke all on public.client_bills, public.client_bill_counters from public, anon, authenticated, service_role;
grant select on public.client_bills to service_role;     -- writes only through the functions below

revoke all on function public.client_bills_bump_version() from public, anon, authenticated, service_role;
revoke all on function public.client_bills_protect()      from public, anon, authenticated, service_role;
revoke all on function public.client_bills_block_delete() from public, anon, authenticated, service_role;
revoke all on function public.next_bill_number(date)      from public, anon, authenticated, service_role;

-- =====================================================================================
-- 5. client_bill_json (internal): one bill as jsonb
-- =====================================================================================
create or replace function public.client_bill_json(p_id uuid)
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id', b.id, 'bill_number', b.bill_number, 'financial_year', b.financial_year,
    'site_id', b.site_id, 'site_name', b.site_name, 'site_location', b.site_location,
    'client_name', b.client_name, 'bill_date', b.bill_date,
    'period_from', b.period_from, 'period_to', b.period_to,
    'description', b.description, 'qty', b.qty, 'unit', b.unit, 'rate', b.rate, 'amount', b.amount,
    'status', b.status, 'version', b.version,
    'finalized_at', b.finalized_at, 'finalized_by_name', fe.name,
    'cancelled_at', b.cancelled_at, 'cancelled_by_name', ce.name, 'cancel_reason', b.cancel_reason,
    'created_by_name', cr.name, 'created_at', b.created_at)
  from public.client_bills b
  join public.employees cr on cr.id = b.created_by
  left join public.employees fe on fe.id = b.finalized_by
  left join public.employees ce on ce.id = b.cancelled_by
  where b.id = p_id
$$;
revoke all on function public.client_bill_json(uuid) from public, anon, authenticated, service_role;

-- =====================================================================================
-- 6. generate_client_bill
--    Creates a DRAFT. qty from 020, rate from the site, amount = qty x rate.
--    Returns {bill}. Audit CLIENT_BILL_GENERATED.
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND (site), MORAYA_VALIDATION (dates, description,
--            no rate, no visits), MORAYA_INVALID_STATE (overlapping bill)
-- =====================================================================================
create or replace function public.generate_client_bill(
  p_actor_auth_id uuid,
  p_site_id       uuid,
  p_date_from     date,
  p_date_to       date,
  p_description   text,
  p_request_id    text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  public.employees;
  v_site   public.sites;
  v_desc   text := btrim(coalesce(p_description, ''));
  v_qty    bigint;
  v_date   date := (now() at time zone 'Asia/Kolkata')::date;
  v_number text;
  v_id     uuid;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['export']);

  if p_site_id is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Required: site_id');
  end if;
  if p_date_from is null or p_date_to is null or p_date_from > p_date_to
     or p_date_from < date '2000-01-01' or p_date_to - p_date_from > 3660 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: date range');
  end if;
  if char_length(v_desc) < 2 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too short: description');
  end if;
  if char_length(v_desc) > 300 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too long: description');
  end if;

  select * into v_site from public.sites s where s.id = p_site_id for share;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Site not found');
  end if;
  if v_site.rate_per_visit is null or v_site.rate_per_visit <= 0 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Site has no rate per visit');
  end if;

  -- One bill generation per site at a time, so the overlap check cannot be raced.
  perform pg_advisory_xact_lock(hashtextextended('client_bill:' || p_site_id::text, 0));

  if exists (select 1 from public.client_bills b
              where b.site_id = p_site_id and b.status <> 'cancelled'
                and b.period_from <= p_date_to and b.period_to >= p_date_from) then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'A bill already exists for an overlapping period');
  end if;

  v_qty := public.fin_visit_count(p_site_id, p_date_from, p_date_to);
  if v_qty < 1 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'No verified visits in this period');
  end if;
  if v_qty * v_site.rate_per_visit > 1000000000000 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: amount');
  end if;

  v_number := public.next_bill_number(v_date);

  insert into public.client_bills (
    bill_number, financial_year, site_id, site_name, site_location, client_name, bill_date,
    period_from, period_to, description, qty, unit, rate, amount, status, created_by)
  values (
    v_number, split_part(v_number, '/', 1)::integer, v_site.id, v_site.site_name, v_site.site_location,
    v_site.client_name, v_date, p_date_from, p_date_to, v_desc, v_qty::integer, 'VISIT',
    v_site.rate_per_visit, v_qty * v_site.rate_per_visit, 'draft', v_actor.id)
  returning id into v_id;

  perform public.write_audit(
    v_actor.id, 'CLIENT_BILL_GENERATED', 'client_bill', v_id::text, null,
    jsonb_build_object('bill_number', v_number, 'site', v_site.site_name, 'period_from', p_date_from,
                       'period_to', p_date_to, 'qty', v_qty, 'rate', v_site.rate_per_visit,
                       'amount', v_qty * v_site.rate_per_visit),
    null, p_request_id,
    'Generated bill ' || v_number || ' for ' || v_site.site_name || ': ' || v_qty::text || ' visits x '
      || public.audit_rupees(v_site.rate_per_visit) || ' = ' || public.audit_rupees(v_qty * v_site.rate_per_visit));

  return jsonb_build_object('bill', public.client_bill_json(v_id));
end $$;

-- =====================================================================================
-- 7. finalize_client_bill
--    draft -> final; locks it and stores the company/bank snapshot. Audit CLIENT_BILL_FINALIZED.
--    Returns {bill}. Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND, MORAYA_INVALID_STATE (not a draft),
--    MORAYA_VALIDATION (bank details missing), MORAYA_CONFLICT (VERSION_CONFLICT)
-- =====================================================================================
create or replace function public.finalize_client_bill(
  p_actor_auth_id uuid,
  p_bill_id       uuid,
  p_version       integer default null,
  p_request_id    text    default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor public.employees;
  v_b     public.client_bills;
  v_set   jsonb;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['export']);

  select * into v_b from public.client_bills b where b.id = p_bill_id for update;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Bill not found');
  end if;
  if v_b.status <> 'draft' then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'Only a draft bill can be finalized');
  end if;
  if p_version is not null and p_version <> v_b.version then
    perform public.moraya_fail('MORAYA_CONFLICT', 'VERSION_CONFLICT');
  end if;

  v_set := public.app_settings_as_json();
  if coalesce(v_set ->> 'bank_name', '') = '' or coalesce(v_set ->> 'account_holder', '') = ''
     or coalesce(v_set ->> 'account_number', '') = '' or coalesce(v_set ->> 'ifsc', '') = '' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Bank details are not set in settings');
  end if;

  update public.client_bills b set
    status = 'final', finalized_at = now(), finalized_by = v_actor.id,
    settings_snapshot = v_set - 'workers_can_see_salary' - 'updated_at' - 'updated_by_name'
  where b.id = v_b.id;

  perform public.write_audit(
    v_actor.id, 'CLIENT_BILL_FINALIZED', 'client_bill', v_b.id::text,
    jsonb_build_object('status', 'draft'), jsonb_build_object('status', 'final'),
    null, p_request_id,
    'Finalized bill ' || v_b.bill_number || ' (' || public.audit_rupees(v_b.amount) || ')');

  return jsonb_build_object('bill', public.client_bill_json(v_b.id));
end $$;

-- =====================================================================================
-- 8. cancel_client_bill
--    draft or final -> cancelled; reason required. Audit CLIENT_BILL_CANCELLED.
--    Returns {bill, previous_status}. Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND,
--    MORAYA_VALIDATION (reason), MORAYA_INVALID_STATE (already cancelled), MORAYA_CONFLICT
-- =====================================================================================
create or replace function public.cancel_client_bill(
  p_actor_auth_id uuid,
  p_bill_id       uuid,
  p_reason        text,
  p_version       integer default null,
  p_request_id    text    default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  public.employees;
  v_b      public.client_bills;
  v_reason text;
begin
  v_actor  := public.moraya_require_actor(p_actor_auth_id, false, array['export']);
  v_reason := public.employee_clean_reason(p_reason, true);

  select * into v_b from public.client_bills b where b.id = p_bill_id for update;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Bill not found');
  end if;
  if v_b.status = 'cancelled' then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'Bill is already cancelled');
  end if;
  if p_version is not null and p_version <> v_b.version then
    perform public.moraya_fail('MORAYA_CONFLICT', 'VERSION_CONFLICT');
  end if;

  update public.client_bills b set
    status = 'cancelled', cancelled_at = now(), cancelled_by = v_actor.id, cancel_reason = v_reason
  where b.id = v_b.id;

  perform public.write_audit(
    v_actor.id, 'CLIENT_BILL_CANCELLED', 'client_bill', v_b.id::text,
    jsonb_build_object('status', v_b.status::text, 'amount', v_b.amount),
    jsonb_build_object('status', 'cancelled'),
    v_reason, p_request_id,
    'Cancelled bill ' || v_b.bill_number || ' (' || public.audit_rupees(v_b.amount) || ')');

  return jsonb_build_object('bill', public.client_bill_json(v_b.id), 'previous_status', v_b.status);
end $$;

-- =====================================================================================
-- 9. get_client_bill
--    Everything the frontend needs to draw the invoice. Company and bank details come from the
--    snapshot for a FINAL (or cancelled-after-final) bill, otherwise from live settings.
--    Returns {bill, company, bank, client, line_item, total_amount, visit_dates[], details_source}
--    The amount in words is produced in TypeScript. Not audited.
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND
-- =====================================================================================
create or replace function public.get_client_bill(
  p_actor_auth_id uuid,
  p_bill_id       uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_b     public.client_bills;
  v_set   jsonb;
  v_src   text;
  v_dates jsonb;
begin
  perform public.moraya_require_actor(p_actor_auth_id, false, array['export']);

  select * into v_b from public.client_bills b where b.id = p_bill_id;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Bill not found');
  end if;

  if v_b.settings_snapshot is not null then
    v_set := v_b.settings_snapshot;  v_src := 'snapshot';
  else
    v_set := public.app_settings_as_json();  v_src := 'live';
  end if;

  select coalesce(jsonb_agg(d.fact_date order by d.fact_date), '[]'::jsonb) into v_dates
  from (select distinct f.fact_date from public.fin_work_facts f
         where f.site_id = v_b.site_id and f.fact_date between v_b.period_from and v_b.period_to) d;

  return jsonb_build_object(
    'bill', public.client_bill_json(v_b.id),
    'company', jsonb_build_object(
        'company_name', v_set -> 'company_name', 'tagline', v_set -> 'tagline',
        'address', v_set -> 'address', 'phones', v_set -> 'phones',
        'email', v_set -> 'email', 'pan', v_set -> 'pan'),
    'bank', jsonb_build_object(
        'bank_name', v_set -> 'bank_name', 'account_holder', v_set -> 'account_holder',
        'account_number', v_set -> 'account_number', 'ifsc', v_set -> 'ifsc',
        'branch', v_set -> 'branch'),
    'client', jsonb_build_object(
        'client_name', v_b.client_name, 'site_name', v_b.site_name, 'site_location', v_b.site_location),
    'line_item', jsonb_build_object(
        'sr_no', 1, 'description', v_b.description, 'qty', v_b.qty, 'unit', v_b.unit,
        'rate', v_b.rate, 'amount', v_b.amount),
    'total_amount', v_b.amount,
    'visit_dates', v_dates,
    'details_source', v_src
  );
end $$;

-- =====================================================================================
-- 10. list_client_bills
--     p_site_id one site or null; p_status 'all' (default) | draft | final | cancelled;
--     p_page 1 and up; p_page_size capped 1..100 (default 20). Newest first.
--     Returns {items[], page, page_size, total}. Errors: MORAYA_FORBIDDEN, MORAYA_VALIDATION
-- =====================================================================================
create or replace function public.list_client_bills(
  p_actor_auth_id uuid,
  p_site_id       uuid    default null,
  p_status        text    default 'all',
  p_page          integer default 1,
  p_page_size     integer default 20
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_page  integer := greatest(1, least(coalesce(p_page, 1), 100000));
  v_size  integer := greatest(1, least(coalesce(p_page_size, 20), 100));
  v_total bigint;
  v_items jsonb;
begin
  perform public.moraya_require_actor(p_actor_auth_id, false, array['export']);
  if p_status is not null and p_status not in ('all', 'draft', 'final', 'cancelled') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: status');
  end if;

  select count(*) into v_total from public.client_bills b
   where (p_site_id is null or b.site_id = p_site_id)
     and (coalesce(p_status, 'all') = 'all' or b.status::text = p_status);

  select coalesce(jsonb_agg(public.client_bill_json(x.id) order by x.bill_date desc, x.created_at desc), '[]'::jsonb)
    into v_items
  from (select b.id, b.bill_date, b.created_at from public.client_bills b
         where (p_site_id is null or b.site_id = p_site_id)
           and (coalesce(p_status, 'all') = 'all' or b.status::text = p_status)
         order by b.bill_date desc, b.created_at desc, b.id
         limit v_size offset (v_page - 1) * v_size) x;

  return jsonb_build_object('items', v_items, 'page', v_page, 'page_size', v_size, 'total', v_total);
end $$;

-- =====================================================================================
-- 11. Grants: service_role only (matches 007 / 014 / 018)
-- =====================================================================================
revoke all on function public.generate_client_bill(uuid, uuid, date, date, text, text) from public, anon, authenticated;
revoke all on function public.finalize_client_bill(uuid, uuid, integer, text)          from public, anon, authenticated;
revoke all on function public.cancel_client_bill(uuid, uuid, text, integer, text)      from public, anon, authenticated;
revoke all on function public.get_client_bill(uuid, uuid)                              from public, anon, authenticated;
revoke all on function public.list_client_bills(uuid, uuid, text, integer, integer)    from public, anon, authenticated;

grant execute on function public.generate_client_bill(uuid, uuid, date, date, text, text) to service_role;
grant execute on function public.finalize_client_bill(uuid, uuid, integer, text)          to service_role;
grant execute on function public.cancel_client_bill(uuid, uuid, text, integer, text)      to service_role;
grant execute on function public.get_client_bill(uuid, uuid)                              to service_role;
grant execute on function public.list_client_bills(uuid, uuid, text, integer, integer)    to service_role;