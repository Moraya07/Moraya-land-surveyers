-- 016_expenses_and_history.sql
-- PURPOSE   : 1. expense_categories (extensible list) and expenses (one row per amount a
--                surveyor spends on a work entry).
--             2. Rules that keep an expense consistent with its work entry (owner, site,
--                date, status) enforced in the database, so no function can get them wrong.
--             3. History: work_entry_history and expense_history. A row is written
--                AUTOMATICALLY (triggers) for every creation, every resubmission, every
--                status change and every other change, so old versions are never lost.
--             No business functions here (they come in 017).
-- DEPENDS ON: 001 (set_updated_at), 002 (employees), 008 (moraya_fail), 014 (sites),
--             015 (work_entries, verification_status).
-- ROLLBACK  : drop table public.expense_history;
--             drop table public.work_entry_history;
--             drop trigger if exists work_entries_cascade_to_expenses on public.work_entries;
--             drop trigger if exists work_entries_history_ins on public.work_entries;
--             drop trigger if exists work_entries_history_upd on public.work_entries;
--             drop table public.expenses;
--             drop table public.expense_categories;
--             drop function public.work_entries_cascade_to_expenses();
--             drop function public.work_entries_history_snapshot();
--             drop function public.expenses_history_snapshot();
--             drop function public.expenses_enforce_rules();
--             drop function public.expenses_block_delete();
--             drop function public.history_block_change();
--             drop index if exists work_entries_id_surveyor_key;
--             (DESTROYS all expenses and history. Drop 017+ objects that use them first.)
--
-- ---------------------------------------------------------------------------------
-- ASSUMPTION FOR YOU TO APPROVE: how expense status relates to work entry status
--   Default chosen: an expense simply FOLLOWS its work entry. Reviewing the work entry
--   changes its expenses in the same transaction (a trigger does it, so it cannot be
--   forgotten). Nobody reviews an expense on its own.
--
--     work entry becomes ...      its (non-cancelled) expenses become ...
--     draft                       draft
--     pending_verification        pending_verification   (submit and resubmit)
--     verified                    verified
--     changes_requested           changes_requested
--     rejected                    rejected
--     cancelled                   cancelled (cancel time, person and reason copied)
--
--   * An expense that was cancelled ON ITS OWN (spec section 7: a financial record is
--     cancelled, never deleted) stays cancelled whatever happens to the work entry later.
--     It is final: nothing on it can change any more. It is excluded from every total.
--     (No function in 017 cancels a single expense; the table allows it for later.)
--   * Site and date of an expense always equal the site and work date of its work entry.
--     If a resubmission changes the entry's site or date, its expenses move with it.
--   * Amount, category and remarks can change only while the work entry is draft,
--     pending_verification or changes_requested. Once verified, rejected or cancelled
--     the money is frozen.
--   * A new expense can be added only to a work entry in draft, pending_verification or
--     changes_requested.
--   * One work entry may have several expenses (the model allows it; 017 creates one).
--   * Expenses carry no "created_by" column: the owner is always the surveyor of the
--     work entry (enforced), so created_by would only repeat employee_id.
--   * Categories are lowercase codes in a table: travel, food, transport, other. To add
--     one: insert into expense_categories (code, label, sort_order) values (...).
--     A deactivated category cannot be used for new or changed expenses; old rows keep it.
--
-- HISTORY (what is recorded and how to read it)
--   Each history row is the state of the record AFTER the change, plus an event name,
--   who did it and when. So the full timeline of an entry is its history rows in id order;
--   the last one equals the current row. Rows are append-only (update, delete and
--   truncate are blocked) and are never exposed to clients.
--   work_entry_history.event : created, submitted, resubmitted, approved,
--                              changes_requested, rejected, cancelled, updated, status_changed
--   expense_history.event    : created, updated, resubmitted, verified, changes_requested,
--                              rejected, cancelled, status_changed
--   work_entry_history.version / expense_history.work_entry_version = the submission round
--   of the work entry at that moment, so "round 1 had expense Rs 500, round 2 had Rs 450"
--   is one query.
--   changed_by: the surveyor for created/submitted/resubmitted/updated; the reviewer for
--   approved / changes_requested / rejected; the person who cancelled for cancelled.
--   (Triggers cannot see the logged-in person; they read it from the row's own fields.
--   The audit_logs rows written by the 017 functions remain the record of who clicked.)

-- =====================================================================================
-- 1. Categories
-- =====================================================================================
create table if not exists public.expense_categories (
  code        text primary key check (code ~ '^[a-z][a-z0-9_]{0,29}$'),
  label       text not null check (char_length(btrim(label)) between 1 and 60),
  is_active   boolean not null default true,
  sort_order  integer not null default 100,
  created_at  timestamptz not null default now()
);

insert into public.expense_categories (code, label, sort_order) values
  ('travel',    'Travel',    10),
  ('food',      'Food',      20),
  ('transport', 'Transport', 30),
  ('other',     'Other',     90)
on conflict (code) do nothing;

-- =====================================================================================
-- 2. Support for the "only the surveyor owns the expense" foreign key
--    work_entries.surveyor_id never changes (015 trigger), so a composite key is safe.
-- =====================================================================================
create unique index if not exists work_entries_id_surveyor_key on public.work_entries (id, surveyor_id);

-- =====================================================================================
-- 3. expenses
-- =====================================================================================
create table if not exists public.expenses (
  id                  uuid primary key default gen_random_uuid(),
  work_entry_id       uuid not null,
  employee_id         uuid not null references public.employees(id),
  site_id             uuid not null references public.sites(id),
  expense_date        date not null,
  amount              bigint not null,
  category            text not null default 'other' references public.expense_categories(code),
  remarks             text,
  verification_status public.verification_status not null default 'draft',
  cancelled_at        timestamptz,
  cancelled_by        uuid references public.employees(id),
  cancel_reason       text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  -- Only the surveyor of the work entry can own its expenses (declarative backstop; the
  -- trigger below reports the same problem with a friendly error first).
  constraint expenses_owner_is_surveyor
    foreign key (work_entry_id, employee_id) references public.work_entries (id, surveyor_id),

  constraint expenses_amount_range  check (amount > 0 and amount <= 1000000000000),
  constraint expenses_date_floor    check (expense_date >= date '2000-01-01'),
  constraint expenses_remarks_len   check (remarks is null or char_length(remarks) between 1 and 1000),
  constraint expenses_cancel_reason_len check (cancel_reason is null or char_length(cancel_reason) between 1 and 1000),
  -- Cancel fields exist exactly when the status is cancelled.
  constraint expenses_cancel_fields
    check ((verification_status = 'cancelled')
           = (cancelled_at is not null and cancelled_by is not null
              and char_length(btrim(coalesce(cancel_reason, ''))) > 0)
       and (verification_status = 'cancelled'
            or (cancelled_at is null and cancelled_by is null and cancel_reason is null)))
);

-- Indexes (one line each: which screen or report needs it)
-- All expenses of one work entry (detail page, cascade on review).
create index if not exists expenses_work_entry_idx   on public.expenses (work_entry_id);
-- Site expense reports and site net balance.
create index if not exists expenses_site_date_idx    on public.expenses (site_id, expense_date desc);
-- Employee expense report, own expense totals on the worker dashboard.
create index if not exists expenses_employee_date_idx on public.expenses (employee_id, expense_date desc);
-- Date-range totals and status filters (verified vs pending sums).
create index if not exists expenses_status_date_idx  on public.expenses (verification_status, expense_date desc);

drop trigger if exists expenses_set_updated_at on public.expenses;
create trigger expenses_set_updated_at before update on public.expenses
  for each row execute function public.set_updated_at();

-- =====================================================================================
-- 4. Trigger functions (all SECURITY DEFINER with a fixed search_path, no grants)
-- =====================================================================================

-- 4a. The rules for one expense (see the header). Locks the work entry row FOR SHARE so
--     it cannot change status while the expense is being written.
create or replace function public.expenses_enforce_rules() returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_we              public.work_entries;
  v_editable        boolean;
  v_content_changed boolean;
  v_cat_active      boolean;
begin
  select * into v_we from public.work_entries w where w.id = new.work_entry_id for share;
  if not found then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: work_entry_id');
  end if;
  v_editable := v_we.verification_status in ('draft', 'pending_verification', 'changes_requested');

  if tg_op = 'INSERT' then
    if new.employee_id <> v_we.surveyor_id then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: employee_id');
    end if;
    if not v_editable then
      perform public.moraya_fail('MORAYA_INVALID_STATE', 'Work entry is not open for expenses');
    end if;
    if new.site_id <> v_we.site_id then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: site_id');
    end if;
    if new.expense_date <> v_we.work_date then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: expense_date');
    end if;
    select c.is_active into v_cat_active from public.expense_categories c where c.code = new.category;
    if v_cat_active is not true then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: category');
    end if;
    -- A new expense always starts in the status of its work entry, never cancelled.
    new.verification_status := v_we.verification_status;
    new.cancelled_at := null; new.cancelled_by := null; new.cancel_reason := null;
    return new;
  end if;

  -- UPDATE
  if new.id <> old.id or new.work_entry_id <> old.work_entry_id
     or new.employee_id <> old.employee_id or new.created_at <> old.created_at then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'An expense''s id, work entry, owner and creation time cannot change');
  end if;

  -- A cancelled expense is final.
  if old.verification_status = 'cancelled' then
    if (new.amount, new.category, new.remarks, new.expense_date, new.site_id,
        new.verification_status, new.cancelled_at, new.cancelled_by, new.cancel_reason)
       is distinct from
       (old.amount, old.category, old.remarks, old.expense_date, old.site_id,
        old.verification_status, old.cancelled_at, old.cancelled_by, old.cancel_reason) then
      perform public.moraya_fail('MORAYA_INVALID_STATE', 'A cancelled expense cannot be changed');
    end if;
    return new;
  end if;

  v_content_changed :=
    (new.amount, new.category, new.remarks, new.expense_date, new.site_id)
    is distinct from
    (old.amount, old.category, old.remarks, old.expense_date, old.site_id);
  if v_content_changed and not v_editable then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'The expense can no longer be changed');
  end if;

  if new.category is distinct from old.category then
    select c.is_active into v_cat_active from public.expense_categories c where c.code = new.category;
    if v_cat_active is not true then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: category');
    end if;
  end if;

  -- A live expense always sits on the site and date of its work entry.
  if new.verification_status <> 'cancelled' then
    if new.site_id <> v_we.site_id then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: site_id');
    end if;
    if new.expense_date <> v_we.work_date then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: expense_date');
    end if;
  end if;

  -- Status moves only by following the work entry (the cascade) or by cancelling.
  if new.verification_status is distinct from old.verification_status
     and new.verification_status <> 'cancelled'
     and new.verification_status <> v_we.verification_status then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'An expense follows the status of its work entry');
  end if;

  return new;
end $$;

drop trigger if exists expenses_enforce_rules on public.expenses;
create trigger expenses_enforce_rules before insert or update on public.expenses
  for each row execute function public.expenses_enforce_rules();

-- 4b. Expenses are never deleted or truncated.
create or replace function public.expenses_block_delete() returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using errcode = 'P0001', message = 'MORAYA_INVALID_STATE',
    detail = 'Expenses cannot be deleted; cancel the expense instead';
end $$;

drop trigger if exists expenses_no_delete on public.expenses;
create trigger expenses_no_delete before delete on public.expenses
  for each row execute function public.expenses_block_delete();
drop trigger if exists expenses_no_truncate on public.expenses;
create trigger expenses_no_truncate before truncate on public.expenses
  for each statement execute function public.expenses_block_delete();

-- 4c. The cascade: a work entry changed status, site or date -> its live expenses follow,
--     in the same transaction, in ONE update per expense (so one history row each).
create or replace function public.work_entries_cascade_to_expenses() returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.expenses x set
    site_id             = new.site_id,
    expense_date        = new.work_date,
    verification_status = new.verification_status,
    cancelled_at        = case when new.verification_status = 'cancelled' then new.cancelled_at end,
    cancelled_by        = case when new.verification_status = 'cancelled' then new.cancelled_by end,
    cancel_reason       = case when new.verification_status = 'cancelled' then new.cancel_reason end
  where x.work_entry_id = new.id
    and x.verification_status <> 'cancelled'            -- individually cancelled ones are final
    and (x.site_id <> new.site_id
         or x.expense_date <> new.work_date
         or x.verification_status <> new.verification_status);
  return null;
end $$;

drop trigger if exists work_entries_cascade_to_expenses on public.work_entries;
create trigger work_entries_cascade_to_expenses after update on public.work_entries
  for each row
  when (old.verification_status is distinct from new.verification_status
        or old.site_id is distinct from new.site_id
        or old.work_date is distinct from new.work_date)
  execute function public.work_entries_cascade_to_expenses();

-- =====================================================================================
-- 5. History tables (append-only)
-- =====================================================================================
create table if not exists public.work_entry_history (
  id                  bigint generated always as identity primary key,
  work_entry_id       uuid not null references public.work_entries(id),
  code                text not null,
  version             integer not null,
  event               text not null,
  changed_by          uuid,
  changed_at          timestamptz not null default now(),
  -- state of the work entry after the change
  site_id             uuid not null,
  surveyor_id         uuid not null,
  assistant_id        uuid,
  work_date           date not null,
  work_time           time not null,
  remarks             text,
  verification_status public.verification_status not null,
  submitted_at        timestamptz,
  reviewed_by         uuid,
  reviewed_at         timestamptz,
  review_reason       text,
  cancelled_at        timestamptz,
  cancelled_by        uuid,
  cancel_reason       text,
  constraint work_entry_history_event check (event in
    ('created','submitted','resubmitted','approved','changes_requested','rejected','cancelled','updated','status_changed'))
);
-- Timeline of one work entry.
create index if not exists work_entry_history_entry_idx on public.work_entry_history (work_entry_id, id);

create table if not exists public.expense_history (
  id                  bigint generated always as identity primary key,
  expense_id          uuid not null references public.expenses(id),
  work_entry_id       uuid not null references public.work_entries(id),
  work_entry_version  integer not null,
  event               text not null,
  changed_by          uuid,
  changed_at          timestamptz not null default now(),
  -- state of the expense after the change
  employee_id         uuid not null,
  site_id             uuid not null,
  expense_date        date not null,
  amount              bigint not null,
  category            text not null,
  remarks             text,
  verification_status public.verification_status not null,
  cancelled_at        timestamptz,
  cancelled_by        uuid,
  cancel_reason       text,
  constraint expense_history_event check (event in
    ('created','updated','resubmitted','verified','changes_requested','rejected','cancelled','status_changed'))
);
-- Timeline of one expense.
create index if not exists expense_history_expense_idx on public.expense_history (expense_id, id);
-- "What did round N of this work entry cost": all expenses of an entry by round.
create index if not exists expense_history_entry_idx   on public.expense_history (work_entry_id, work_entry_version);

-- Append-only.
create or replace function public.history_block_change() returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using errcode = 'P0001', message = 'MORAYA_INVALID_STATE',
    detail = 'History rows are append-only';
end $$;

drop trigger if exists work_entry_history_no_change   on public.work_entry_history;
create trigger work_entry_history_no_change before update or delete on public.work_entry_history
  for each row execute function public.history_block_change();
drop trigger if exists work_entry_history_no_truncate on public.work_entry_history;
create trigger work_entry_history_no_truncate before truncate on public.work_entry_history
  for each statement execute function public.history_block_change();

drop trigger if exists expense_history_no_change   on public.expense_history;
create trigger expense_history_no_change before update or delete on public.expense_history
  for each row execute function public.history_block_change();
drop trigger if exists expense_history_no_truncate on public.expense_history;
create trigger expense_history_no_truncate before truncate on public.expense_history
  for each statement execute function public.history_block_change();

-- 5a. Work entry snapshots
create or replace function public.work_entries_history_snapshot() returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event text;
  v_by    uuid;
begin
  if tg_op = 'INSERT' then
    v_event := case when new.verification_status = 'pending_verification' then 'submitted' else 'created' end;
  elsif new.verification_status is distinct from old.verification_status then
    v_event := case new.verification_status
      when 'pending_verification' then case when old.verification_status = 'changes_requested'
                                            then 'resubmitted' else 'submitted' end
      when 'verified'             then 'approved'
      when 'changes_requested'    then 'changes_requested'
      when 'rejected'             then 'rejected'
      when 'cancelled'            then 'cancelled'
      else 'status_changed' end;
  else
    v_event := 'updated';
  end if;

  v_by := case when v_event in ('approved', 'changes_requested', 'rejected') then new.reviewed_by
               when v_event = 'cancelled' then new.cancelled_by
               else new.surveyor_id end;

  insert into public.work_entry_history
    (work_entry_id, code, version, event, changed_by,
     site_id, surveyor_id, assistant_id, work_date, work_time, remarks, verification_status,
     submitted_at, reviewed_by, reviewed_at, review_reason, cancelled_at, cancelled_by, cancel_reason)
  values
    (new.id, new.code, new.version, v_event, v_by,
     new.site_id, new.surveyor_id, new.assistant_id, new.work_date, new.work_time, new.remarks, new.verification_status,
     new.submitted_at, new.reviewed_by, new.reviewed_at, new.review_reason, new.cancelled_at, new.cancelled_by, new.cancel_reason);
  return null;
end $$;

drop trigger if exists work_entries_history_ins on public.work_entries;
create trigger work_entries_history_ins after insert on public.work_entries
  for each row execute function public.work_entries_history_snapshot();

drop trigger if exists work_entries_history_upd on public.work_entries;
create trigger work_entries_history_upd after update on public.work_entries
  for each row
  when (old.verification_status is distinct from new.verification_status
        or old.site_id          is distinct from new.site_id
        or old.assistant_id     is distinct from new.assistant_id
        or old.work_date        is distinct from new.work_date
        or old.work_time        is distinct from new.work_time
        or old.remarks          is distinct from new.remarks
        or old.version          is distinct from new.version
        or old.review_reason    is distinct from new.review_reason)
  execute function public.work_entries_history_snapshot();

-- 5b. Expense snapshots
create or replace function public.expenses_history_snapshot() returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event   text;
  v_by      uuid;
  v_version integer;
  v_reviewer uuid;
begin
  select w.version, w.reviewed_by into v_version, v_reviewer
    from public.work_entries w where w.id = new.work_entry_id;

  if tg_op = 'INSERT' then
    v_event := 'created';
  elsif new.verification_status is distinct from old.verification_status then
    v_event := case new.verification_status
      when 'cancelled'            then 'cancelled'
      when 'verified'             then 'verified'
      when 'changes_requested'    then 'changes_requested'
      when 'rejected'             then 'rejected'
      when 'pending_verification' then case when old.verification_status = 'changes_requested'
                                            then 'resubmitted' else 'status_changed' end
      else 'status_changed' end;
  else
    v_event := 'updated';
  end if;

  v_by := case when v_event = 'cancelled' then new.cancelled_by
               when v_event in ('verified', 'changes_requested', 'rejected') then v_reviewer
               else new.employee_id end;

  insert into public.expense_history
    (expense_id, work_entry_id, work_entry_version, event, changed_by,
     employee_id, site_id, expense_date, amount, category, remarks, verification_status,
     cancelled_at, cancelled_by, cancel_reason)
  values
    (new.id, new.work_entry_id, v_version, v_event, v_by,
     new.employee_id, new.site_id, new.expense_date, new.amount, new.category, new.remarks, new.verification_status,
     new.cancelled_at, new.cancelled_by, new.cancel_reason);
  return null;
end $$;

drop trigger if exists expenses_history_ins on public.expenses;
create trigger expenses_history_ins after insert on public.expenses
  for each row execute function public.expenses_history_snapshot();

drop trigger if exists expenses_history_upd on public.expenses;
create trigger expenses_history_upd after update on public.expenses
  for each row
  when (old.amount              is distinct from new.amount
        or old.category         is distinct from new.category
        or old.remarks          is distinct from new.remarks
        or old.expense_date     is distinct from new.expense_date
        or old.site_id          is distinct from new.site_id
        or old.verification_status is distinct from new.verification_status
        or old.cancelled_at     is distinct from new.cancelled_at)
  execute function public.expenses_history_snapshot();

-- =====================================================================================
-- 6. RLS and grants (clients never read tables; the Worker reads through RPCs in 017)
-- =====================================================================================
alter table public.expense_categories enable row level security;
alter table public.expenses           enable row level security;
alter table public.work_entry_history enable row level security;
alter table public.expense_history    enable row level security;
-- No policies for anon / authenticated: default deny.

revoke all on public.expense_categories, public.expenses, public.work_entry_history, public.expense_history
  from public, anon, authenticated, service_role;
grant select on public.expense_categories, public.expenses, public.work_entry_history, public.expense_history
  to service_role;   -- writes only through SECURITY DEFINER functions and the triggers above

revoke all on function public.expenses_enforce_rules()           from public, anon, authenticated, service_role;
revoke all on function public.expenses_block_delete()            from public, anon, authenticated, service_role;
revoke all on function public.work_entries_cascade_to_expenses() from public, anon, authenticated, service_role;
revoke all on function public.history_block_change()             from public, anon, authenticated, service_role;
revoke all on function public.work_entries_history_snapshot()    from public, anon, authenticated, service_role;
revoke all on function public.expenses_history_snapshot()        from public, anon, authenticated, service_role;