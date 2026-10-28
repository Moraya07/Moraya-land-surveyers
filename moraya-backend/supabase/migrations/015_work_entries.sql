-- 015_work_entries.sql
-- PURPOSE   : Tables and constraints for work entries. NO business functions here (they come
--             in 017: submit, resubmit, approve, request changes, reject, cancel, lists).
--             Contains: the verification_status enum, the yearly code counter and
--             next_work_entry_code(), the work_entries table, the "no future work" trigger,
--             protection triggers (immutable fields, no delete), indexes, RLS and grants.
-- DEPENDS ON: 001 (set_updated_at), 002 (employees), 014 (sites).
-- ROLLBACK  : drop table public.work_entries;           -- DESTROYS all work entries (016 and
--                                                       -- later files reference it: drop those first)
--             drop table public.work_entry_counters;
--             drop function public.next_work_entry_code();
--             drop function public.work_entries_check_not_future();
--             drop function public.work_entries_protect_fields();
--             drop function public.work_entries_block_delete();
--             drop type public.verification_status;
--
-- STATUS VALUES (lowercase in the database; the uppercase names are display labels):
--   draft, pending_verification, verified, changes_requested, rejected, cancelled
--   The enum is named verification_status so 016 can reuse it for expenses.
--   The transition table (who may move an entry from where to where) is written in 017.
--   The only transition rule enforced here is a consistency check on the data (see the
--   CHECK constraints): a status never exists without the fields it needs.
--
-- WORK ENTRY CODE: WE-YYYY-NNNNN, e.g. WE-2026-00001.
--   YYYY is the year (India time) in which the code was ISSUED, not the year of work_date.
--   The number restarts at 00001 every year. Past 99999 in a year the number simply gets
--   longer (WE-2026-100000); it is never cut off.
--   The code is issued by a column default, so a row cannot exist without one.
--   next_work_entry_code() is INTERNAL: nobody has EXECUTE on it (the owner, and so every
--   SECURITY DEFINER function including the column default, can still run it). The
--   counter is incremented inside the caller's transaction: a rolled-back submit gives
--   its number back, so there are no gaps and never a duplicate. The counter row stays
--   locked until the caller commits, so two submissions in the same instant queue for a
--   few milliseconds: fine for this workload.
--
-- VERSION: work_entries.version is the SUBMISSION ROUND, not an edit counter. It is 1 on
--   the first submission and goes up by one on each resubmission (done explicitly by
--   resubmit_work_entry in 017, which also snapshots the previous round into the 016
--   history tables). There is no automatic bump trigger, so approving or cancelling does
--   not change it.
--
-- NO FUTURE WORK (Asia/Kolkata) - how it works and the edge cases
--   work_date + work_time are read as INDIA local time and compared with the actual time
--   in India at the moment of the insert or of the update that changes either column. If
--   the combined moment is later than "now in India", the statement fails with
--   MORAYA_VALIDATION, detail 'Future date: work_date'. It is a trigger, so a direct
--   write, a bug in a later function or a tampered request cannot get around it.
--   Edge cases:
--   * UTC vs India: India is UTC+5:30 all year (no daylight saving). Between 00:00 and
--     05:30 India time the UTC date is still "yesterday". Comparing work_date with the UTC
--     date would wrongly reject today's entries in those hours, so the trigger converts
--     to India time first.
--   * Midnight: at 23:58 on 28 Oct an entry for 29 Oct 00:05 is in the future and is
--     refused; a minute after midnight, 29 Oct 00:00 is accepted. An entry dated "today"
--     with a time earlier than now is always fine, also for a form that was opened before
--     midnight (it then just refers to "yesterday", which is the past).
--   * Same minute: the trigger is exact to the microsecond. A worker who types 10:16 at
--     10:15:50 is refused. A phone clock running ahead of the server can therefore cause
--     a refusal for "now"; the frontend should clamp the time field to the current time
--     and the Worker can show a clear message. No tolerance is built in because the
--     specification says future entries must not be allowed.
--   * Slow requests: the clock is read when the trigger runs (clock_timestamp), not when
--     the transaction started, so a request that straddles midnight is judged correctly.
--   * Only inserts and updates that actually CHANGE work_date or work_time are checked, so
--     approving or cancelling an old entry never re-validates it.

-- =====================================================================================
-- 1. Status enum
-- =====================================================================================
do $$ begin
  create type public.verification_status as enum
    ('draft', 'pending_verification', 'verified', 'changes_requested', 'rejected', 'cancelled');
exception when duplicate_object then null; end $$;

-- =====================================================================================
-- 2. Yearly counter + code generator
-- =====================================================================================
create table if not exists public.work_entry_counters (
  year        integer primary key check (year between 2000 and 9999),
  last_number integer not null check (last_number >= 0),
  updated_at  timestamptz not null default now()
);

create or replace function public.next_work_entry_code() returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_year integer := extract(year from (now() at time zone 'Asia/Kolkata'))::integer;
  v_n    integer;
begin
  -- One atomic statement: creates the year's row or adds one. A concurrent caller waits
  -- on the row lock and then sees the new value, so two callers never get the same number.
  insert into public.work_entry_counters as c (year, last_number)
  values (v_year, 1)
  on conflict (year) do update set last_number = c.last_number + 1, updated_at = now()
  returning c.last_number into v_n;

  return 'WE-' || v_year::text || '-' ||
         case when v_n < 100000 then lpad(v_n::text, 5, '0') else v_n::text end;
end $$;

-- =====================================================================================
-- 3. work_entries
-- =====================================================================================
create table if not exists public.work_entries (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null unique default public.next_work_entry_code(),
  site_id             uuid not null references public.sites(id),
  surveyor_id         uuid not null references public.employees(id),
  assistant_id        uuid references public.employees(id),
  work_date           date not null,
  work_time           time not null,
  remarks             text,
  verification_status public.verification_status not null default 'draft',
  version             integer not null default 1,
  submitted_at        timestamptz,
  reviewed_by         uuid references public.employees(id),
  reviewed_at         timestamptz,
  review_reason       text,
  cancelled_at        timestamptz,
  cancelled_by        uuid references public.employees(id),
  cancel_reason       text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  constraint work_entries_code_format       check (code ~ '^WE-[0-9]{4}-[0-9]{5,}$'),
  constraint work_entries_date_floor        check (work_date >= date '2000-01-01'),
  constraint work_entries_version_positive  check (version >= 1),
  constraint work_entries_remarks_len       check (remarks is null or char_length(remarks) between 1 and 1000),
  constraint work_entries_review_reason_len check (review_reason is null or char_length(review_reason) between 1 and 1000),
  constraint work_entries_cancel_reason_len check (cancel_reason is null or char_length(cancel_reason) between 1 and 1000),

  -- The surveyor and the assistant of one entry are different people.
  constraint work_entries_surveyor_not_assistant
    check (assistant_id is null or assistant_id <> surveyor_id),

  -- Nobody reviews an entry they worked on (surveyor or assistant).
  constraint work_entries_reviewer_not_worker
    check (reviewed_by is null or (reviewed_by <> surveyor_id and reviewed_by is distinct from assistant_id)),

  -- Anything that was submitted has a submission time (drafts and cancelled drafts may not).
  constraint work_entries_submitted_has_time
    check (verification_status in ('draft', 'cancelled') or submitted_at is not null),

  -- A review outcome always says who and when; a "no" outcome always says why.
  constraint work_entries_reviewed_has_reviewer
    check (verification_status not in ('verified', 'changes_requested', 'rejected')
           or (reviewed_by is not null and reviewed_at is not null)),
  constraint work_entries_negative_needs_reason
    check (verification_status not in ('changes_requested', 'rejected')
           or char_length(btrim(coalesce(review_reason, ''))) > 0),

  -- Cancellation: the three cancel fields exist exactly when the status is cancelled.
  constraint work_entries_cancel_fields
    check ((verification_status = 'cancelled')
           = (cancelled_at is not null and cancelled_by is not null
              and char_length(btrim(coalesce(cancel_reason, ''))) > 0)
       and (verification_status = 'cancelled'
            or (cancelled_at is null and cancelled_by is null and cancel_reason is null)))
);

-- =====================================================================================
-- 4. Indexes (each one line: which screen or report needs it)
-- =====================================================================================
-- Site invoice, site reports, "work of this site", visit count (distinct site + date).
create index if not exists work_entries_site_date_idx      on public.work_entries (site_id, work_date desc);
-- "My work" for the surveyor, personal employee reports.
create index if not exists work_entries_surveyor_date_idx  on public.work_entries (surveyor_id, work_date desc);
-- "My work" where the worker was the assistant (most entries have none, so partial).
create index if not exists work_entries_assistant_date_idx on public.work_entries (assistant_id, work_date desc)
  where assistant_id is not null;
-- Date-range filters on the admin list and every report.
create index if not exists work_entries_date_idx           on public.work_entries (work_date desc);
-- Admin list filtered by status, status counts on the dashboard.
create index if not exists work_entries_status_date_idx    on public.work_entries (verification_status, work_date desc);
-- The Verification Center queue: oldest pending first.
create index if not exists work_entries_pending_queue_idx  on public.work_entries (submitted_at)
  where verification_status = 'pending_verification';

-- Double-click / double-submit protection: the same surveyor cannot have two live entries
-- for the same site at the same date and time. Rejected and cancelled ones do not count,
-- so a rejected entry can be entered again.
create unique index if not exists work_entries_no_double_submit_key
  on public.work_entries (surveyor_id, site_id, work_date, work_time)
  where verification_status not in ('rejected', 'cancelled');

-- =====================================================================================
-- 5. Triggers
-- =====================================================================================
drop trigger if exists work_entries_set_updated_at on public.work_entries;
create trigger work_entries_set_updated_at before update on public.work_entries
  for each row execute function public.set_updated_at();

-- 5a. No future work (see the long note in the header).
create or replace function public.work_entries_check_not_future() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and new.work_date = old.work_date and new.work_time = old.work_time then
    return new;   -- date and time untouched: nothing to validate
  end if;

  if (new.work_date + new.work_time) > (clock_timestamp() at time zone 'Asia/Kolkata') then
    raise exception using errcode = 'P0001', message = 'MORAYA_VALIDATION',
      detail = 'Future date: work_date';
  end if;
  return new;
end $$;

drop trigger if exists work_entries_no_future on public.work_entries;
create trigger work_entries_no_future before insert or update of work_date, work_time on public.work_entries
  for each row execute function public.work_entries_check_not_future();

-- 5b. The identity of an entry never changes: id, code, surveyor and creation time.
--     (Site, assistant, date, time and remarks may change, but only through resubmission
--     in 017, which keeps the history.)
create or replace function public.work_entries_protect_fields() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.id <> old.id or new.code <> old.code or new.surveyor_id <> old.surveyor_id
     or new.created_at <> old.created_at then
    raise exception using errcode = 'P0001', message = 'MORAYA_INVALID_STATE',
      detail = 'A work entry''s id, code, surveyor and creation time cannot change';
  end if;
  return new;
end $$;

drop trigger if exists work_entries_protect_fields on public.work_entries;
create trigger work_entries_protect_fields before update on public.work_entries
  for each row execute function public.work_entries_protect_fields();

-- 5c. Work entries are never deleted or truncated (cancel them instead).
create or replace function public.work_entries_block_delete() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception using errcode = 'P0001', message = 'MORAYA_INVALID_STATE',
    detail = 'Work entries cannot be deleted; cancel the entry instead';
end $$;

drop trigger if exists work_entries_no_delete on public.work_entries;
create trigger work_entries_no_delete before delete on public.work_entries
  for each row execute function public.work_entries_block_delete();

drop trigger if exists work_entries_no_truncate on public.work_entries;
create trigger work_entries_no_truncate before truncate on public.work_entries
  for each statement execute function public.work_entries_block_delete();

-- =====================================================================================
-- 6. RLS and grants (clients never read tables; the Worker reads through RPCs in 017)
-- =====================================================================================
alter table public.work_entries         enable row level security;
alter table public.work_entry_counters  enable row level security;
-- No policies for anon / authenticated: default deny.

revoke all on public.work_entries        from public, anon, authenticated, service_role;
revoke all on public.work_entry_counters from public, anon, authenticated, service_role;
grant select on public.work_entries to service_role;   -- writes only through SECURITY DEFINER functions
-- work_entry_counters: no grant at all; only next_work_entry_code() touches it.

revoke all on function public.next_work_entry_code()          from public, anon, authenticated, service_role;
revoke all on function public.work_entries_check_not_future() from public, anon, authenticated, service_role;
revoke all on function public.work_entries_protect_fields()   from public, anon, authenticated, service_role;
revoke all on function public.work_entries_block_delete()     from public, anon, authenticated, service_role;