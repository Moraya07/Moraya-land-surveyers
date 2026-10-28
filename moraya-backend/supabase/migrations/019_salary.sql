-- 019_salary.sql
-- PURPOSE   : Salary records. The salary_records table, an append-only history of every
--             change, and the RPCs the Worker calls (service_role only): create_salary,
--             update_salary, set_salary_status, get_salary, list_salary, get_my_salary.
-- DEPENDS ON: 001 (set_updated_at), 002 (employees), 003 (permissions), 008 (write_audit,
--             moraya_require_actor, moraya_fail, audit_diff_summary, audit_rupees, audit
--             actions SALARY_CREATED / SALARY_UPDATED / SALARY_STATUS_CHANGED), 010
--             (app_settings.workers_can_see_salary, app_settings_clean), 013 (employee_today_ist,
--             employee_parse_date, employee_clean_reason), 018 (income_parse_money).
-- ROLLBACK  : drop function public.get_my_salary(uuid,integer,integer);
--             drop function public.list_salary(uuid,uuid,text,date,date,text,text,integer,integer);
--             drop function public.get_salary(uuid,uuid);
--             drop function public.set_salary_status(uuid,uuid,integer,text,bigint,date,text,text);
--             drop function public.update_salary(uuid,uuid,integer,jsonb,text,text);
--             drop function public.create_salary(uuid,uuid,date,date,bigint,bigint,date,text,text);
--             drop function public.salary_json(uuid);
--             drop function public.salary_check_target(public.employees,uuid);
--             drop function public.salary_status_for(bigint,bigint);
--             drop table public.salary_history;
--             drop table public.salary_records;   -- DESTROYS all salary data (020+ read it)
--             drop function public.salary_history_snapshot();
--             drop function public.salary_history_block_change();
--             drop function public.salary_protect();
--             drop function public.salary_bump_version();
--             drop function public.salary_block_delete();
--             drop type public.salary_status;
--
-- WHAT A SALARY RECORD IS: what one employee is owed for one period, and how much of it has
--   been paid. Fields (Admin Workflow section 10): employee, period, amount, credited date,
--   status, remarks.
--   PERIOD (decision): two dates, period_start and period_end (inclusive), not a text label,
--   so reports can filter by date range. A monthly salary is 2026-10-01 .. 2026-10-31.
--   The frontend shows it as "Oct 2026" when the dates cover one calendar month.
--   amount       what is owed for the period, paise, 1 .. 1,000,000,000,000
--   paid_amount  how much has been paid so far, paise, 0 .. amount
--   credited_date the date the money was credited (the latest payment). Present exactly
--                when paid_amount > 0.
--
-- STATUS (lowercase; display labels PENDING / PAID / PARTIALLY_PAID)
--   pending          paid_amount = 0                (credited_date empty)
--   partially_paid   0 < paid_amount < amount
--   paid             paid_amount = amount
--   Derived from the two amounts by the functions and CHECKED by a table constraint, so the
--   status can never disagree with the money. There is no 'cancelled' status (the spec lists
--   three). A wrong record is corrected with update_salary / set_salary_status; every
--   version stays in salary_history. (If you want voiding later, add a status in a new file.)
--   Official salary totals (paid, pending) are defined in 020, not here.
--
-- WHO MAY DO WHAT
--   create / update / set status / get / list : main_admin, or sub_admin with salary_management
--   get_my_salary : any active employee, only their own rows, and only while
--                   app_settings.workers_can_see_salary is true (else MORAYA_FORBIDDEN)
--   Extra protection (decision): a sub_admin cannot touch the salary of the main_admin, nor
--   their OWN salary (MORAYA_FORBIDDEN); only the main_admin can. Revoked/inactive employees
--   can still have salary recorded (final settlements).
--
-- RULES
--   * One record per employee per exact period (unique), and periods of the same employee
--     may not overlap (checked in the functions, MORAYA_CONFLICT 'Already exists: salary').
--   * period_end >= period_start; both after 2000-01-01; a period may not start in the future
--     (India time). credited_date: not in the future, not before 2000-01-01.
--   * A change of AMOUNT requires a reason (5-500). Moving paid_amount DOWN (a correction)
--     requires a reason too. Other edits: reason optional.
--   * version rises on every update; update_salary requires the version the screen was
--     loaded with, set_salary_status takes it optionally (MORAYA_CONFLICT 'VERSION_CONFLICT').
--   * Never deleted or truncated (trigger and grants).
--
-- HISTORY: salary_history gets a row for the creation and for every change of a record, by
--   trigger (the state AFTER the change, event, who, when). Append-only. Never exposed to
--   clients. The audit log keeps the reasons.
--
-- ERROR DETAILS: 'Required: <field>', 'Invalid: <field>', 'Not allowed: <field>',
--   'Too long: <field>', 'Future date: <field>', 'Already exists: salary' (CONFLICT),
--   'VERSION_CONFLICT', 'Salary not found', 'Employee not found'.

-- =====================================================================================
-- 1. Status enum
-- =====================================================================================
do $$ begin
  create type public.salary_status as enum ('pending', 'partially_paid', 'paid');
exception when duplicate_object then null; end $$;

-- =====================================================================================
-- 2. salary_records
-- =====================================================================================
create table if not exists public.salary_records (
  id             uuid primary key default gen_random_uuid(),
  employee_id    uuid not null references public.employees(id),
  period_start   date not null,
  period_end     date not null,
  amount         bigint not null,
  paid_amount    bigint not null default 0,
  credited_date  date,
  status         public.salary_status not null default 'pending',
  remarks        text,
  version        integer not null default 1,
  created_by     uuid not null references public.employees(id),
  updated_by     uuid references public.employees(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  constraint salary_amount_range    check (amount > 0 and amount <= 1000000000000),
  constraint salary_paid_range      check (paid_amount >= 0 and paid_amount <= amount),
  constraint salary_period_order    check (period_end >= period_start and period_start >= date '2000-01-01'),
  constraint salary_period_length   check (period_end - period_start <= 366),
  constraint salary_credited_floor  check (credited_date is null or credited_date >= date '2000-01-01'),
  constraint salary_remarks_len     check (remarks is null or char_length(remarks) between 1 and 1000),
  constraint salary_version_positive check (version >= 1),
  -- Status always agrees with the money.
  constraint salary_status_consistent check (
       (status = 'pending'        and paid_amount = 0)
    or (status = 'partially_paid' and paid_amount > 0 and paid_amount < amount)
    or (status = 'paid'           and paid_amount = amount)),
  -- A credited date exists exactly when something was paid.
  constraint salary_credited_when_paid check ((paid_amount > 0) = (credited_date is not null))
);

-- One record per employee per exact period.
create unique index if not exists salary_employee_period_key
  on public.salary_records (employee_id, period_start, period_end);
-- Salary of one employee, newest period first (employee page, personal salary report,
-- get_my_salary).
create index if not exists salary_employee_period_idx on public.salary_records (employee_id, period_end desc);
-- Status filter (pending / partial salary lists, dashboard).
create index if not exists salary_status_period_idx   on public.salary_records (status, period_end desc);
-- Period range filters and overall salary reports.
create index if not exists salary_period_idx          on public.salary_records (period_end desc, period_start);

drop trigger if exists salary_set_updated_at on public.salary_records;
create trigger salary_set_updated_at before update on public.salary_records
  for each row execute function public.set_updated_at();

create or replace function public.salary_bump_version() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.version := old.version + 1;
  return new;
end $$;

drop trigger if exists salary_bump_version on public.salary_records;
create trigger salary_bump_version before update on public.salary_records
  for each row execute function public.salary_bump_version();

-- The employee and the creator of a record never change.
create or replace function public.salary_protect() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.id <> old.id or new.employee_id <> old.employee_id or new.created_by <> old.created_by
     or new.created_at <> old.created_at then
    raise exception using errcode = 'P0001', message = 'MORAYA_INVALID_STATE',
      detail = 'A salary record''s id, employee, creator and creation time cannot change';
  end if;
  return new;
end $$;

drop trigger if exists salary_protect on public.salary_records;
create trigger salary_protect before update on public.salary_records
  for each row execute function public.salary_protect();

-- Never deleted or truncated.
create or replace function public.salary_block_delete() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception using errcode = 'P0001', message = 'MORAYA_INVALID_STATE',
    detail = 'Salary records cannot be deleted; correct the record instead';
end $$;

drop trigger if exists salary_no_delete on public.salary_records;
create trigger salary_no_delete before delete on public.salary_records
  for each row execute function public.salary_block_delete();
drop trigger if exists salary_no_truncate on public.salary_records;
create trigger salary_no_truncate before truncate on public.salary_records
  for each statement execute function public.salary_block_delete();

-- =====================================================================================
-- 3. salary_history (append-only, written by trigger)
-- =====================================================================================
create table if not exists public.salary_history (
  id             bigint generated always as identity primary key,
  salary_id      uuid not null references public.salary_records(id),
  version        integer not null,
  event          text not null,
  changed_by     uuid,
  changed_at     timestamptz not null default now(),
  -- state of the record after the change
  employee_id    uuid not null,
  period_start   date not null,
  period_end     date not null,
  amount         bigint not null,
  paid_amount    bigint not null,
  credited_date  date,
  status         public.salary_status not null,
  remarks        text,
  constraint salary_history_event check (event in ('created', 'updated', 'status_changed'))
);
-- Timeline of one salary record.
create index if not exists salary_history_record_idx on public.salary_history (salary_id, id);

create or replace function public.salary_history_block_change() returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using errcode = 'P0001', message = 'MORAYA_INVALID_STATE',
    detail = 'History rows are append-only';
end $$;

drop trigger if exists salary_history_no_change on public.salary_history;
create trigger salary_history_no_change before update or delete on public.salary_history
  for each row execute function public.salary_history_block_change();
drop trigger if exists salary_history_no_truncate on public.salary_history;
create trigger salary_history_no_truncate before truncate on public.salary_history
  for each statement execute function public.salary_history_block_change();

create or replace function public.salary_history_snapshot() returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event text;
begin
  v_event := case
    when tg_op = 'INSERT' then 'created'
    when new.status is distinct from old.status or new.paid_amount is distinct from old.paid_amount
         then 'status_changed'
    else 'updated' end;
  insert into public.salary_history
    (salary_id, version, event, changed_by, employee_id, period_start, period_end, amount,
     paid_amount, credited_date, status, remarks)
  values
    (new.id, new.version, v_event, coalesce(new.updated_by, new.created_by), new.employee_id,
     new.period_start, new.period_end, new.amount, new.paid_amount, new.credited_date, new.status, new.remarks);
  return null;
end $$;

drop trigger if exists salary_history_ins on public.salary_records;
create trigger salary_history_ins after insert on public.salary_records
  for each row execute function public.salary_history_snapshot();
drop trigger if exists salary_history_upd on public.salary_records;
create trigger salary_history_upd after update on public.salary_records
  for each row execute function public.salary_history_snapshot();

-- =====================================================================================
-- 4. RLS and grants (clients never read tables; the Worker reads through RPCs)
-- =====================================================================================
alter table public.salary_records enable row level security;
alter table public.salary_history enable row level security;
-- No policies for anon / authenticated: default deny.

revoke all on public.salary_records, public.salary_history from public, anon, authenticated, service_role;
grant select on public.salary_records, public.salary_history to service_role;   -- writes only through functions/triggers

revoke all on function public.salary_bump_version()          from public, anon, authenticated, service_role;
revoke all on function public.salary_protect()               from public, anon, authenticated, service_role;
revoke all on function public.salary_block_delete()          from public, anon, authenticated, service_role;
revoke all on function public.salary_history_block_change()  from public, anon, authenticated, service_role;
revoke all on function public.salary_history_snapshot()      from public, anon, authenticated, service_role;

-- =====================================================================================
-- 5. Internal helpers (no grant to anyone)
-- =====================================================================================

-- The one place that turns the two amounts into a status.
create or replace function public.salary_status_for(p_amount bigint, p_paid bigint)
returns public.salary_status
language sql
immutable
set search_path = public, pg_temp
as $$
  select case when p_paid = 0         then 'pending'::public.salary_status
              when p_paid >= p_amount then 'paid'::public.salary_status
              else 'partially_paid'::public.salary_status end;
$$;

-- Who may touch the salary of this employee: a sub_admin may not touch the main_admin's
-- salary or their own. Raises MORAYA_FORBIDDEN. Returns the target employee row.
create or replace function public.salary_check_target(p_actor public.employees, p_employee_id uuid)
returns public.employees
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_t public.employees;
begin
  select e.* into v_t from public.employees e where e.id = p_employee_id;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Employee not found');
  end if;
  if p_actor.role <> 'main_admin' and (v_t.role = 'main_admin' or v_t.id = p_actor.id) then
    perform public.moraya_fail('MORAYA_FORBIDDEN');
  end if;
  return v_t;
end $$;

-- The salary object returned by every admin function.
create or replace function public.salary_json(p_id uuid)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  r record;
begin
  select sr.*, e.name as employee_name, e.employee_id as employee_code, e.designation
    into r
    from public.salary_records sr
    join public.employees e on e.id = sr.employee_id
   where sr.id = p_id;
  if not found then return null; end if;

  return jsonb_build_object(
    'id',            r.id,
    'employee',      jsonb_build_object('id', r.employee_id, 'name', r.employee_name,
                                        'employee_id', r.employee_code, 'designation', r.designation),
    'period_start',  r.period_start,
    'period_end',    r.period_end,
    'amount',        r.amount,
    'paid_amount',   r.paid_amount,
    'pending_amount', r.amount - r.paid_amount,
    'credited_date', r.credited_date,
    'status',        r.status,
    'remarks',       r.remarks,
    'version',       r.version,
    'created_at',    r.created_at,
    'updated_at',    r.updated_at
  );
end $$;

revoke all on function public.salary_status_for(bigint, bigint)                       from public, anon, authenticated, service_role;
revoke all on function public.salary_check_target(public.employees, uuid)             from public, anon, authenticated, service_role;
revoke all on function public.salary_json(uuid)                                       from public, anon, authenticated, service_role;

-- =====================================================================================
-- 6. create_salary
--    Required: p_employee_id, p_period_start, p_period_end, p_amount (paise > 0).
--    Optional: p_paid_amount (default 0, <= amount; status derived), p_credited_date
--    (required when p_paid_amount > 0, must be empty otherwise; not in the future),
--    p_remarks. Overlapping periods of the same employee -> MORAYA_CONFLICT.
--    Audit: SALARY_CREATED. Returns {salary}.
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND, MORAYA_VALIDATION, MORAYA_CONFLICT
-- =====================================================================================
create or replace function public.create_salary(
  p_actor_auth_id uuid,
  p_employee_id   uuid,
  p_period_start  date,
  p_period_end    date,
  p_amount        bigint,
  p_paid_amount   bigint default 0,
  p_credited_date date   default null,
  p_remarks       text   default null,
  p_request_id    text   default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor   public.employees;
  v_t       public.employees;
  v_paid    bigint := coalesce(p_paid_amount, 0);
  v_remarks text;
  v_status  public.salary_status;
  v_id      uuid;
  v_today   date := public.employee_today_ist();
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['salary_management']);
  if p_employee_id is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Required: employee_id');
  end if;
  v_t := public.salary_check_target(v_actor, p_employee_id);

  if p_period_start is null then perform public.moraya_fail('MORAYA_VALIDATION', 'Required: period_start'); end if;
  if p_period_end   is null then perform public.moraya_fail('MORAYA_VALIDATION', 'Required: period_end'); end if;
  if p_period_start < date '2000-01-01' or p_period_end < p_period_start or p_period_end - p_period_start > 366 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: period');
  end if;
  if p_period_start > v_today then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Future date: period_start');
  end if;

  if p_amount is null or p_amount <= 0 or p_amount > 1000000000000 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: amount');
  end if;
  if v_paid < 0 or v_paid > p_amount then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: paid_amount');
  end if;
  if v_paid > 0 and p_credited_date is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Required: credited_date');
  end if;
  if v_paid = 0 and p_credited_date is not null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Not allowed: credited_date');
  end if;
  if p_credited_date is not null then
    if p_credited_date < date '2000-01-01' then perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: credited_date'); end if;
    if p_credited_date > v_today then perform public.moraya_fail('MORAYA_VALIDATION', 'Future date: credited_date'); end if;
  end if;
  v_remarks := public.app_settings_clean(to_jsonb(p_remarks), 'remarks', 1000, false);

  -- No overlapping period for the same employee (serialised per employee).
  perform 1 from public.employees e where e.id = p_employee_id for update;
  if exists (select 1 from public.salary_records s
              where s.employee_id = p_employee_id
                and s.period_start <= p_period_end and s.period_end >= p_period_start) then
    perform public.moraya_fail('MORAYA_CONFLICT', 'Already exists: salary');
  end if;

  v_status := public.salary_status_for(p_amount, v_paid);
  begin
    insert into public.salary_records
      (employee_id, period_start, period_end, amount, paid_amount, credited_date, status, remarks, created_by, updated_by)
    values
      (p_employee_id, p_period_start, p_period_end, p_amount, v_paid, p_credited_date, v_status, v_remarks,
       v_actor.id, v_actor.id)
    returning id into v_id;
  exception when unique_violation then
    perform public.moraya_fail('MORAYA_CONFLICT', 'Already exists: salary');
  end;

  perform public.write_audit(
    v_actor.id, 'SALARY_CREATED', 'salary', v_id::text,
    null,
    jsonb_build_object('employee_id', p_employee_id, 'period_start', p_period_start, 'period_end', p_period_end,
                       'amount', p_amount, 'paid_amount', v_paid, 'credited_date', p_credited_date,
                       'status', v_status::text, 'remarks', v_remarks),
    null, p_request_id,
    'Added salary ' || public.audit_rupees(p_amount) || ' for ' || v_t.name || ' (' || p_period_start::text
      || ' to ' || p_period_end::text || ', paid ' || public.audit_rupees(v_paid) || ')'
  );

  return jsonb_build_object('salary', public.salary_json(v_id));
end $$;

-- =====================================================================================
-- 7. update_salary
--    p_patch may hold ONLY: period_start, period_end, amount, credited_date, remarks.
--    (paid_amount and status change through set_salary_status. credited_date can be edited
--    only while something is paid.) The employee cannot change. p_version must equal the
--    current version. A change of AMOUNT requires p_reason (5-500). Status is re-derived
--    (for example raising the amount of a paid record makes it partially_paid).
--    Lowering the amount below paid_amount is refused ('Invalid: amount').
--    Nothing changed -> returned as is, no audit row, no new version.
--    Audit: SALARY_UPDATED with old and new values of the changed fields.
--    Returns {salary}.
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND, MORAYA_VALIDATION, MORAYA_CONFLICT
-- =====================================================================================
create or replace function public.update_salary(
  p_actor_auth_id uuid,
  p_salary_id     uuid,
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
  v_t       public.employees;
  v_s       public.salary_records;
  r         record;
  v_start   date;
  v_end     date;
  v_amount  bigint;
  v_cred    date;
  v_remarks text;
  v_status  public.salary_status;
  v_reason  text;
  v_today   date := public.employee_today_ist();
  v_old     jsonb := '{}'::jsonb;
  v_new     jsonb := '{}'::jsonb;
  v_old_s   jsonb := '{}'::jsonb;
  v_new_s   jsonb := '{}'::jsonb;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['salary_management']);

  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: patch');
  end if;
  if p_version is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Required: version');
  end if;
  for r in select k as key from jsonb_object_keys(p_patch) as k loop
    if r.key not in ('period_start', 'period_end', 'amount', 'credited_date', 'remarks') then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Not allowed: ' || left(r.key, 40));
    end if;
  end loop;

  select * into v_s from public.salary_records s where s.id = p_salary_id for update;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Salary not found');
  end if;
  v_t := public.salary_check_target(v_actor, v_s.employee_id);
  if v_s.version <> p_version then
    perform public.moraya_fail('MORAYA_CONFLICT', 'VERSION_CONFLICT');
  end if;

  v_start := v_s.period_start; v_end := v_s.period_end; v_amount := v_s.amount;
  v_cred := v_s.credited_date; v_remarks := v_s.remarks;

  if p_patch ? 'period_start' then
    v_start := public.employee_parse_date(p_patch -> 'period_start', 'period_start');
    if v_start is null then perform public.moraya_fail('MORAYA_VALIDATION', 'Required: period_start'); end if;
  end if;
  if p_patch ? 'period_end' then
    v_end := public.employee_parse_date(p_patch -> 'period_end', 'period_end');
    if v_end is null then perform public.moraya_fail('MORAYA_VALIDATION', 'Required: period_end'); end if;
  end if;
  if v_start < date '2000-01-01' or v_end < v_start or v_end - v_start > 366 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: period');
  end if;
  if v_start > v_today and v_start is distinct from v_s.period_start then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Future date: period_start');
  end if;

  if p_patch ? 'amount' then
    v_amount := public.income_parse_money(p_patch -> 'amount', 'amount', 1);
    if v_amount < v_s.paid_amount then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: amount');
    end if;
  end if;
  if p_patch ? 'credited_date' then
    if v_s.paid_amount = 0 then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Not allowed: credited_date');
    end if;
    if jsonb_typeof(p_patch -> 'credited_date') <> 'string' then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Required: credited_date');
    end if;
    v_cred := public.employee_parse_date(p_patch -> 'credited_date', 'credited_date');
    if v_cred is null or v_cred < date '2000-01-01' then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: credited_date');
    end if;
    if v_cred > v_today then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Future date: credited_date');
    end if;
  end if;
  if p_patch ? 'remarks' then
    v_remarks := public.app_settings_clean(p_patch -> 'remarks', 'remarks', 1000, false);
  end if;

  v_reason := public.employee_clean_reason(p_reason, v_amount is distinct from v_s.amount);

  if v_start is distinct from v_s.period_start then
    v_old := v_old || jsonb_build_object('period_start', v_s.period_start);
    v_new := v_new || jsonb_build_object('period_start', v_start);
  end if;
  if v_end is distinct from v_s.period_end then
    v_old := v_old || jsonb_build_object('period_end', v_s.period_end);
    v_new := v_new || jsonb_build_object('period_end', v_end);
  end if;
  if v_cred is distinct from v_s.credited_date then
    v_old := v_old || jsonb_build_object('credited_date', v_s.credited_date);
    v_new := v_new || jsonb_build_object('credited_date', v_cred);
  end if;
  if v_remarks is distinct from v_s.remarks then
    v_old := v_old || jsonb_build_object('remarks', v_s.remarks);
    v_new := v_new || jsonb_build_object('remarks', v_remarks);
  end if;
  v_old_s := v_old; v_new_s := v_new;
  if v_amount is distinct from v_s.amount then
    v_old   := v_old   || jsonb_build_object('amount', v_s.amount);
    v_new   := v_new   || jsonb_build_object('amount', v_amount);
    v_old_s := v_old_s || jsonb_build_object('amount', public.audit_rupees(v_s.amount));
    v_new_s := v_new_s || jsonb_build_object('amount', public.audit_rupees(v_amount));
  end if;

  if v_new = '{}'::jsonb then
    return jsonb_build_object('salary', public.salary_json(v_s.id));
  end if;

  -- Overlap check only when the period moved.
  if v_start is distinct from v_s.period_start or v_end is distinct from v_s.period_end then
    if exists (select 1 from public.salary_records x
                where x.employee_id = v_s.employee_id and x.id <> v_s.id
                  and x.period_start <= v_end and x.period_end >= v_start) then
      perform public.moraya_fail('MORAYA_CONFLICT', 'Already exists: salary');
    end if;
  end if;

  v_status := public.salary_status_for(v_amount, v_s.paid_amount);
  if v_status is distinct from v_s.status then
    v_old   := v_old   || jsonb_build_object('status', v_s.status::text);
    v_new   := v_new   || jsonb_build_object('status', v_status::text);
    v_old_s := v_old_s || jsonb_build_object('status', v_s.status::text);
    v_new_s := v_new_s || jsonb_build_object('status', v_status::text);
  end if;

  begin
    update public.salary_records s set
      period_start = v_start, period_end = v_end, amount = v_amount, credited_date = v_cred,
      remarks = v_remarks, status = v_status, updated_by = v_actor.id
    where s.id = v_s.id;
  exception when unique_violation then
    perform public.moraya_fail('MORAYA_CONFLICT', 'Already exists: salary');
  end;

  perform public.write_audit(
    v_actor.id, 'SALARY_UPDATED', 'salary', v_s.id::text,
    v_old, v_new, v_reason, p_request_id,
    public.audit_diff_summary('Changed salary of ' || v_t.name || ':', v_old_s, v_new_s)
  );

  return jsonb_build_object('salary', public.salary_json(v_s.id));
end $$;

-- =====================================================================================
-- 8. set_salary_status
--    p_new_status: 'pending' | 'partially_paid' | 'paid'. Keeps status and paid_amount
--    consistent:
--      pending         paid_amount becomes 0, credited_date cleared
--      paid            paid_amount becomes the full amount; p_credited_date default today
--      partially_paid  p_paid_amount required, 0 < p_paid_amount < amount;
--                      p_credited_date default today
--    (p_paid_amount is ignored for 'pending'; for 'paid' it must be empty or equal the amount.)
--    Moving paid_amount DOWN (a correction) requires p_reason (5-500); otherwise optional.
--    The same status AND the same paid amount again -> MORAYA_INVALID_STATE.
--    p_version optional (VERSION_CONFLICT if given and different).
--    Audit: SALARY_STATUS_CHANGED. Returns {salary, previous_status}.
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND, MORAYA_VALIDATION, MORAYA_INVALID_STATE,
--            MORAYA_CONFLICT
-- =====================================================================================
create or replace function public.set_salary_status(
  p_actor_auth_id uuid,
  p_salary_id     uuid,
  p_version       integer default null,
  p_new_status    text    default null,
  p_paid_amount   bigint  default null,
  p_credited_date date    default null,
  p_reason        text    default null,
  p_request_id    text    default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  public.employees;
  v_t      public.employees;
  v_s      public.salary_records;
  v_new    text := lower(btrim(coalesce(p_new_status, '')));
  v_paid   bigint;
  v_cred   date;
  v_reason text;
  v_today  date := public.employee_today_ist();
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['salary_management']);

  if v_new not in ('pending', 'partially_paid', 'paid') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: status');
  end if;

  select * into v_s from public.salary_records s where s.id = p_salary_id for update;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Salary not found');
  end if;
  v_t := public.salary_check_target(v_actor, v_s.employee_id);
  if p_version is not null and p_version <> v_s.version then
    perform public.moraya_fail('MORAYA_CONFLICT', 'VERSION_CONFLICT');
  end if;

  if v_new = 'pending' then
    v_paid := 0; v_cred := null;
  elsif v_new = 'paid' then
    if p_paid_amount is not null and p_paid_amount <> v_s.amount then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: paid_amount');
    end if;
    v_paid := v_s.amount;
  else
    if p_paid_amount is null or p_paid_amount <= 0 or p_paid_amount >= v_s.amount then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: paid_amount');
    end if;
    v_paid := p_paid_amount;
  end if;

  if v_new <> 'pending' then
    v_cred := coalesce(p_credited_date, case when v_paid = v_s.paid_amount then v_s.credited_date end, v_today);
    if v_cred < date '2000-01-01' then perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: credited_date'); end if;
    if v_cred > v_today then perform public.moraya_fail('MORAYA_VALIDATION', 'Future date: credited_date'); end if;
  end if;

  if v_s.status::text = v_new and v_s.paid_amount = v_paid then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'Salary is already ' || v_new);
  end if;

  v_reason := public.employee_clean_reason(p_reason, v_paid < v_s.paid_amount);

  update public.salary_records s set
    status = v_new::public.salary_status, paid_amount = v_paid, credited_date = v_cred, updated_by = v_actor.id
  where s.id = v_s.id;

  perform public.write_audit(
    v_actor.id, 'SALARY_STATUS_CHANGED', 'salary', v_s.id::text,
    jsonb_build_object('status', v_s.status::text, 'paid_amount', v_s.paid_amount, 'credited_date', v_s.credited_date),
    jsonb_build_object('status', v_new, 'paid_amount', v_paid, 'credited_date', v_cred),
    v_reason, p_request_id,
    'Changed salary status of ' || v_t.name || ' (' || v_s.period_start::text || ' to ' || v_s.period_end::text
      || '): ' || v_s.status::text || ' -> ' || v_new || ', paid ' || public.audit_rupees(v_s.paid_amount)
      || ' -> ' || public.audit_rupees(v_paid)
  );

  return jsonb_build_object('salary', public.salary_json(v_s.id), 'previous_status', v_s.status);
end $$;

-- =====================================================================================
-- 9. get_salary
--    Returns {salary, history[]} (history oldest first: id, version, event, changed_at,
--    changed_by_name, period_start, period_end, amount, paid_amount, credited_date, status,
--    remarks). Same access rule as the write functions (a sub_admin cannot see the
--    main_admin's or their own salary). Reading is not audited.
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND
-- =====================================================================================
create or replace function public.get_salary(
  p_actor_auth_id uuid,
  p_salary_id     uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor public.employees;
  v_json  jsonb;
  v_emp   uuid;
  v_hist  jsonb;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['salary_management']);
  select s.employee_id into v_emp from public.salary_records s where s.id = p_salary_id;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Salary not found');
  end if;
  perform public.salary_check_target(v_actor, v_emp);
  v_json := public.salary_json(p_salary_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', h.id, 'version', h.version, 'event', h.event, 'changed_at', h.changed_at,
           'changed_by_name', c.name, 'period_start', h.period_start, 'period_end', h.period_end,
           'amount', h.amount, 'paid_amount', h.paid_amount, 'credited_date', h.credited_date,
           'status', h.status, 'remarks', h.remarks) order by h.id), '[]'::jsonb)
    into v_hist
    from public.salary_history h
    left join public.employees c on c.id = h.changed_by
   where h.salary_id = p_salary_id;

  return jsonb_build_object('salary', v_json, 'history', v_hist);
end $$;

-- =====================================================================================
-- 10. list_salary
--    main_admin, or sub_admin with salary_management. A sub_admin does not see rows of the
--    main_admin or of themselves.
--    p_employee_id one employee or null
--    p_status      'all' (default) | 'pending' | 'partially_paid' | 'paid'
--    p_date_from / p_date_to  rows whose period OVERLAPS this range (either may be null)
--    p_q           search in employee name or employee id (max 100; % _ \ literal)
--    p_sort        '<field>:<asc|desc>'; field one of period_end, period_start, amount, status,
--                  employee_name. Default 'period_end:desc'. Ties by created_at desc.
--    p_page 1 and up; p_page_size capped 1..100 (default 20)
--    Returns {items[], page, page_size, total, totals{pending, partially_paid, paid}}
--      items[]: the fields of salary_json. totals = COUNTS per status over the filters except
--      the status filter. Money sums are not returned: official totals live in 020.
--    Errors: MORAYA_FORBIDDEN, MORAYA_VALIDATION
-- =====================================================================================
create or replace function public.list_salary(
  p_actor_auth_id uuid,
  p_employee_id   uuid    default null,
  p_status        text    default 'all',
  p_date_from     date    default null,
  p_date_to       date    default null,
  p_q             text    default null,
  p_sort          text    default 'period_end:desc',
  p_page          integer default 1,
  p_page_size     integer default 20
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor   public.employees;
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
  v_pending bigint; v_partial bigint; v_paid bigint;
  v_items   jsonb;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['salary_management']);

  if v_status not in ('all', 'pending', 'partially_paid', 'paid') then
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

  v_field := lower(btrim(split_part(coalesce(p_sort, 'period_end:desc'), ':', 1)));
  v_dir   := lower(btrim(split_part(coalesce(p_sort, 'period_end:desc'), ':', 2)));
  if v_dir = '' then v_dir := 'asc'; end if;
  if v_dir not in ('asc', 'desc') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: sort');
  end if;
  v_order := case v_field
    when 'period_end'    then 'sr.period_end ' || v_dir
    when 'period_start'  then 'sr.period_start ' || v_dir
    when 'amount'        then 'sr.amount ' || v_dir
    when 'status'        then 'sr.status ' || v_dir
    when 'employee_name' then 'lower(e.name) ' || v_dir
    else null end;
  if v_order is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: sort');
  end if;
  v_order := v_order || ', sr.created_at desc, sr.id';

  v_page := greatest(1, least(coalesce(p_page, 1), 100000));
  v_size := greatest(1, least(coalesce(p_page_size, 20), 100));

  -- $1 employee, $2 from, $3 to, $4 pattern, $5 actor id, $6 actor is main_admin
  v_from := $f$
      from public.salary_records sr
      join public.employees e on e.id = sr.employee_id
     where ($1::uuid is null or sr.employee_id = $1)
       and ($2::date is null or sr.period_end >= $2)
       and ($3::date is null or sr.period_start <= $3)
       and ($4::text is null or e.name ilike $4 escape '\' or e.employee_id ilike $4 escape '\')
       and ($6::boolean or (e.role <> 'main_admin' and sr.employee_id <> $5))
  $f$;

  v_sql := 'select count(*) filter (where $7::text = ''all'' or sr.status::text = $7::text),
                   count(*) filter (where sr.status = ''pending''),
                   count(*) filter (where sr.status = ''partially_paid''),
                   count(*) filter (where sr.status = ''paid'') ' || v_from;
  execute v_sql
    into v_total, v_pending, v_partial, v_paid
    using p_employee_id, p_date_from, p_date_to, v_pat, v_actor.id, (v_actor.role = 'main_admin'), v_status;

  v_sql := 'select coalesce(jsonb_agg(jsonb_build_object(
              ''id'', p.id,
              ''employee'', jsonb_build_object(''id'', p.employee_id, ''name'', p.employee_name,
                                              ''employee_id'', p.employee_code, ''designation'', p.designation),
              ''period_start'', p.period_start, ''period_end'', p.period_end,
              ''amount'', p.amount, ''paid_amount'', p.paid_amount,
              ''pending_amount'', p.amount - p.paid_amount,
              ''credited_date'', p.credited_date, ''status'', p.status, ''remarks'', p.remarks,
              ''version'', p.version
            ) order by p.rn), ''[]''::jsonb)
            from (
              select row_number() over (order by ' || v_order || ') as rn,
                     sr.id, sr.employee_id, e.name as employee_name, e.employee_id as employee_code,
                     e.designation, sr.period_start, sr.period_end, sr.amount, sr.paid_amount,
                     sr.credited_date, sr.status, sr.remarks, sr.version '
            || v_from
            || ' and ($7::text = ''all'' or sr.status::text = $7::text)
                 order by ' || v_order || '
                 limit $8 offset $9) p';
  execute v_sql
    into v_items
    using p_employee_id, p_date_from, p_date_to, v_pat, v_actor.id, (v_actor.role = 'main_admin'), v_status,
          v_size, (v_page - 1) * v_size;

  return jsonb_build_object(
    'items',     v_items,
    'page',      v_page,
    'page_size', v_size,
    'total',     v_total,
    'totals',    jsonb_build_object('pending', v_pending, 'partially_paid', v_partial, 'paid', v_paid)
  );
end $$;

-- =====================================================================================
-- 11. get_my_salary
--    Any ACTIVE employee; returns ONLY their own rows, newest period first, and only while
--    app_settings.workers_can_see_salary is true; otherwise MORAYA_FORBIDDEN (also when the
--    settings row is missing). No history, no other employee, no admin fields.
--    p_page 1 and up; p_page_size capped 1..100 (default 20).
--    Returns {items[], page, page_size, total}
--      items[]: id, period_start, period_end, amount, paid_amount, credited_date, status, remarks
--    Errors: MORAYA_FORBIDDEN
-- =====================================================================================
create or replace function public.get_my_salary(
  p_actor_auth_id uuid,
  p_page          integer default 1,
  p_page_size     integer default 20
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor public.employees;
  v_flag  boolean;
  v_page  int := greatest(1, least(coalesce(p_page, 1), 100000));
  v_size  int := greatest(1, least(coalesce(p_page_size, 20), 100));
  v_total bigint;
  v_items jsonb;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, null);

  select a.workers_can_see_salary into v_flag from public.app_settings a where a.id = 1;
  if v_flag is not true then
    perform public.moraya_fail('MORAYA_FORBIDDEN');
  end if;

  select count(*) into v_total from public.salary_records sr where sr.employee_id = v_actor.id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'period_start', p.period_start, 'period_end', p.period_end,
           'amount', p.amount, 'paid_amount', p.paid_amount, 'credited_date', p.credited_date,
           'status', p.status, 'remarks', p.remarks) order by p.rn), '[]'::jsonb)
    into v_items
    from (
      select row_number() over (order by sr.period_end desc, sr.period_start desc, sr.id) as rn,
             sr.id, sr.period_start, sr.period_end, sr.amount, sr.paid_amount, sr.credited_date,
             sr.status, sr.remarks
        from public.salary_records sr
       where sr.employee_id = v_actor.id
       order by sr.period_end desc, sr.period_start desc, sr.id
       limit v_size offset (v_page - 1) * v_size
    ) p;

  return jsonb_build_object('items', v_items, 'page', v_page, 'page_size', v_size, 'total', v_total);
end $$;

-- =====================================================================================
-- 12. Grants: service_role only
-- =====================================================================================
revoke all on function public.create_salary(uuid, uuid, date, date, bigint, bigint, date, text, text)   from public, anon, authenticated;
revoke all on function public.update_salary(uuid, uuid, integer, jsonb, text, text)                      from public, anon, authenticated;
revoke all on function public.set_salary_status(uuid, uuid, integer, text, bigint, date, text, text)     from public, anon, authenticated;
revoke all on function public.get_salary(uuid, uuid)                                                     from public, anon, authenticated;
revoke all on function public.list_salary(uuid, uuid, text, date, date, text, text, integer, integer)    from public, anon, authenticated;
revoke all on function public.get_my_salary(uuid, integer, integer)                                      from public, anon, authenticated;

grant execute on function public.create_salary(uuid, uuid, date, date, bigint, bigint, date, text, text)  to service_role;
grant execute on function public.update_salary(uuid, uuid, integer, jsonb, text, text)                    to service_role;
grant execute on function public.set_salary_status(uuid, uuid, integer, text, bigint, date, text, text)   to service_role;
grant execute on function public.get_salary(uuid, uuid)                                                   to service_role;
grant execute on function public.list_salary(uuid, uuid, text, date, date, text, text, integer, integer)  to service_role;
grant execute on function public.get_my_salary(uuid, integer, integer)                                    to service_role;