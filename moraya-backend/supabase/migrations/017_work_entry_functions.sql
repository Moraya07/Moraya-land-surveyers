-- 017_work_entry_functions.sql
-- PURPOSE   : The verification state machine for work entries. The RPCs the Worker calls
--             (service_role only):
--               submit_work_entry, resubmit_work_entry,
--               approve_work_entry, request_work_entry_changes, reject_work_entry,
--               cancel_work_entry,
--               list_work_entries_admin, list_my_work, get_work_entry.
--             Tables, constraints, history triggers and the expense cascade already exist
--             (015, 016); this file only adds functions. No table is changed.
-- DEPENDS ON: 001, 002, 003, 008 (write_audit, moraya_require_actor, moraya_fail,
--             audit_diff_summary, audit_rupees, audit actions WORK_*), 010 (app_settings_clean),
--             013 (employee_today_ist, employee_clean_reason), 014 (sites), 015 (work_entries),
--             016 (expenses, expense_categories, work_entry_history, expense_history).
-- ROLLBACK  : drop function public.get_work_entry(uuid,uuid);
--             drop function public.list_my_work(uuid,date,date,uuid,text,text,text,text,integer,integer);
--             drop function public.list_work_entries_admin(uuid,date,date,uuid,uuid,text,text,text,integer,integer);
--             drop function public.cancel_work_entry(uuid,uuid,text,integer,text);
--             drop function public.reject_work_entry(uuid,uuid,text,integer,text);
--             drop function public.request_work_entry_changes(uuid,uuid,text,integer,text);
--             drop function public.approve_work_entry(uuid,uuid,integer,text);
--             drop function public.resubmit_work_entry(uuid,uuid,uuid,date,time,uuid,bigint,text,text,integer,text);
--             drop function public.submit_work_entry(uuid,uuid,date,time,uuid,bigint,text,text,text);
--             drop function public.work_entries_page(uuid,text,date,date,uuid,uuid,text,text,text,text,integer,integer);
--             drop function public.work_entry_review(uuid,uuid,text,text,integer,text);
--             drop function public.work_entry_json(uuid,uuid,boolean);
--             drop function public.work_state_json(uuid,uuid,date,time,text,bigint,text,integer,boolean);
--             drop function public.work_check_assistant(uuid,uuid,uuid);
--             drop function public.work_check_site(uuid,uuid);
--             drop function public.work_clean_form(date,time,bigint,text,text);
--             drop function public.work_entry_expense_total(uuid);
--             drop function public.work_next_or_fail(public.verification_status,text);
--             drop function public.work_entry_next_status(public.verification_status,text);
--             drop function public.work_has_perm(uuid,public.user_role,text[]);
--             (No data is touched.)
--
-- Status values are lowercase in the database (see 015); the uppercase names are labels.
-- Error convention (008): SQLSTATE P0001, MESSAGE = stable code, DETAIL = short text the
--   Worker maps to a form field. Codes used here: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND,
--   MORAYA_INVALID_STATE, MORAYA_VALIDATION, MORAYA_CONFLICT.
--   Details: 'Required: <field>', 'Invalid: <field>', 'Not allowed: <field>',
--   'Too short|Too long: <field>', 'Future date: work_date' (also raised by the 015 trigger),
--   'Already exists: work_entry' (MORAYA_CONFLICT), 'VERSION_CONFLICT' (MORAYA_CONFLICT),
--   'Cannot <action> a work entry that is <status>' (MORAYA_INVALID_STATE).
--
-- =====================================================================================
-- TRANSITION TABLE (the only place the rules live: work_entry_next_status)
-- =====================================================================================
--   action            from status            to status             who
--   ----------------  ---------------------  --------------------  -------------------------
--   submit            (no row yet)           pending_verification  the surveyor = the caller
--   resubmit          changes_requested      pending_verification  the surveyor of the entry
--   approve           pending_verification   verified              verification permission *
--   request_changes   pending_verification   changes_requested      verification permission *
--   reject            pending_verification   rejected              verification permission *
--   cancel            draft                  cancelled             verification permission
--                     pending_verification   cancelled
--                     changes_requested      cancelled
--                     verified               cancelled   (the controlled correction path)
--   * and the reviewer is neither the surveyor nor the assistant of that entry.
--   Every other (status, action) pair raises MORAYA_INVALID_STATE. In particular:
--     verified, rejected, cancelled are final for approve / request_changes / reject /
--     resubmit; a rejected entry is not cancellable (it is already excluded everywhere);
--     a cancelled entry never comes back; 'draft' entries are not created by any function
--     here (the column exists for later), they can only be cancelled.
--   "verification permission" = main_admin, or a sub_admin holding 'verification'.
--   Expenses follow the work entry in the same transaction (016 cascade trigger).
--
-- =====================================================================================
-- ASSUMPTIONS FOR YOU TO APPROVE
-- =====================================================================================
--  1. Function names: the prompt says "request_changes" and "reject". They are named
--     request_work_entry_changes and reject_work_entry so every name says what it works on.
--  2. Any ACTIVE employee (any role) may submit work as the surveyor; the surveyor is
--     always the caller and cannot be chosen. Any ACTIVE employee other than the surveyor
--     may be the assistant.
--  3. The expense is optional on submit: p_expense_amount null = no expense row. Given, it
--     must be whole paise, 1 .. 1,000,000,000,000. One expense per entry is created; the
--     category defaults to 'other'. The expense remarks stay empty (the remarks belong to
--     the work entry).
--  4. Review functions take an OPTIONAL p_version (the round the reviewer was looking at).
--     If given and different from the entry's current round -> MORAYA_CONFLICT
--     'VERSION_CONFLICT' (the worker resubmitted while the admin had the old page open).
--     The Worker should always send it.
--  5. Resubmit is a FULL replacement of the form (site, date, time, assistant, expense,
--     remarks). Site and assistant that are unchanged are accepted even if the site was
--     since completed or the assistant deactivated (the worker must not be trapped);
--     a NEW site must be active and a NEW assistant must be active.
--     p_expense_amount null on resubmit removes the expense (it is cancelled on its own, a
--     final state, with the reason 'Removed by the surveyor when resubmitting').
--  6. On resubmit the review fields (reviewed_by, reviewed_at, review_reason) of the entry
--     are cleared; the old reason stays readable in the history returned by get_work_entry.
--  7. Cancel uses the same permission as review ('verification'). The "reviewer cannot be a
--     participant" rule is NOT applied to cancel (it would stop the Main Admin cancelling
--     their own mistaken entry). Reason required, 5-500 characters.
--  8. Admin list filter "employee" matches the surveyor OR the assistant.
--     Admin list / get: main_admin, or sub_admin with 'verification' or 'report_view'.
--  9. A worker who is neither surveyor nor assistant (and not an admin) asking for an entry
--     gets MORAYA_NOT_FOUND (existence is not revealed). A resubmit attempt by someone
--     who is not the surveyor gets MORAYA_FORBIDDEN.
-- 10. work_time is stored to the minute (seconds dropped), so the double-submit unique index
--     from 015 works at minute level.
--
-- WHO SEES WHAT (expense amounts)
--   admin (see 8)  : everything, including expenses and expense history
--   the surveyor   : everything about their own entry, including expenses
--   the assistant  : the entry and its work history, NEVER expense amounts, expenses or
--                    expense history (keys are absent, not zero)
--   (An admin who is also the surveyor or assistant gets the admin view.)
--
-- AUDIT: every write function writes exactly one audit row in the same transaction
--   (WORK_SUBMITTED, WORK_RESUBMITTED, WORK_APPROVED, WORK_CHANGES_REQUESTED, WORK_REJECTED,
--   WORK_CANCELLED; entity_type 'work_entry', entity_id = the entry's uuid). These actions
--   already exist in the 008 catalogue; no new action is added. Reads are not audited.

-- =====================================================================================
-- 0. Fix for moraya_fail (defined in 008)
--    008's version passes DETAIL = null when no detail is given (for example
--    moraya_fail('MORAYA_FORBIDDEN')); PostgreSQL then fails with "RAISE statement option
--    cannot be null", so the Worker never sees the stable code. This replacement raises the
--    same error without a DETAIL when there is none. Same signature, same grants; safe to
--    re-run. (008 itself is left untouched.)
-- =====================================================================================
create or replace function public.moraya_fail(p_code text, p_detail text default null)
returns void
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if p_detail is null then
    raise exception using errcode = 'P0001', message = p_code;
  end if;
  raise exception using errcode = 'P0001', message = p_code, detail = p_detail;
end $$;

-- =====================================================================================
-- 1. Internal helpers (no grant to anyone; only the functions below call them)
-- =====================================================================================

-- main_admin, or a sub_admin holding at least one of the permissions.
create or replace function public.work_has_perm(p_id uuid, p_role public.user_role, p_perms text[])
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select p_role = 'main_admin'
      or (p_role = 'sub_admin' and exists (
            select 1 from public.sub_admin_permissions sp
             where sp.employee_id = p_id and sp.permission = any (p_perms)));
$$;

-- The transition table. Returns the next status, or null when the move is not allowed.
create or replace function public.work_entry_next_status(p_from public.verification_status, p_action text)
returns public.verification_status
language sql
immutable
set search_path = public, pg_temp
as $$
  select case p_action
    when 'resubmit'        then case when p_from = 'changes_requested'
                                     then 'pending_verification'::public.verification_status end
    when 'approve'         then case when p_from = 'pending_verification'
                                     then 'verified'::public.verification_status end
    when 'request_changes' then case when p_from = 'pending_verification'
                                     then 'changes_requested'::public.verification_status end
    when 'reject'          then case when p_from = 'pending_verification'
                                     then 'rejected'::public.verification_status end
    when 'cancel'          then case when p_from in ('draft', 'pending_verification', 'changes_requested', 'verified')
                                     then 'cancelled'::public.verification_status end
  end;
$$;

-- Same, but raises MORAYA_INVALID_STATE for an illegal move.
create or replace function public.work_next_or_fail(p_from public.verification_status, p_action text)
returns public.verification_status
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_next public.verification_status := public.work_entry_next_status(p_from, p_action);
begin
  if v_next is null then
    perform public.moraya_fail('MORAYA_INVALID_STATE',
      'Cannot ' || replace(coalesce(p_action, '?'), '_', ' ') || ' a work entry that is ' || p_from::text);
  end if;
  return v_next;
end $$;

-- The money of one entry, in paise: its expenses minus the ones removed on their own.
-- (When the whole entry is cancelled its expenses are cancelled with the same timestamp;
-- those still count here so a cancelled entry shows what it had.)
create or replace function public.work_entry_expense_total(p_id uuid)
returns bigint
language sql
stable
set search_path = public, pg_temp
as $$
  select sum(x.amount)::bigint
    from public.expenses x
    join public.work_entries w on w.id = x.work_entry_id
   where x.work_entry_id = p_id
     and (x.verification_status <> 'cancelled'
          or (w.verification_status = 'cancelled' and x.cancelled_at = w.cancelled_at));
$$;

-- Validates and normalises the worker's form fields. Raises MORAYA_VALIDATION.
--   o_time     : the time cut to the minute
--   o_category : lowercase category code (null when there is no expense)
--   o_remarks  : trimmed remarks or null
create or replace function public.work_clean_form(
  p_work_date date, p_work_time time, p_amount bigint, p_category text, p_remarks text,
  out o_time time, out o_category text, out o_remarks text
)
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if p_work_date is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Required: work_date');
  end if;
  if p_work_date < date '2000-01-01' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: work_date');
  end if;
  if p_work_date > public.employee_today_ist() then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Future date: work_date');
  end if;
  if p_work_time is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Required: work_time');
  end if;
  o_time := make_time(extract(hour from p_work_time)::int, extract(minute from p_work_time)::int, 0);

  o_remarks := public.app_settings_clean(to_jsonb(p_remarks), 'remarks', 1000, false);

  if p_amount is not null then
    if p_amount <= 0 or p_amount > 1000000000000 then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: expense_amount');
    end if;
    o_category := coalesce(nullif(lower(btrim(coalesce(p_category, ''))), ''), 'other');
    if not exists (select 1 from public.expense_categories c where c.code = o_category and c.is_active) then
      perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: category');
    end if;
  end if;
end $$;

-- The site must exist and be active (or be the one the entry already has). Locks the site
-- row FOR SHARE so it cannot be deactivated half-way through this transaction.
create or replace function public.work_check_site(p_site uuid, p_current uuid)
returns void
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_status public.site_status;
begin
  if p_site is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Required: site_id');
  end if;
  select s.status into v_status from public.sites s where s.id = p_site for share;
  if not found or (v_status <> 'active' and p_site is distinct from p_current) then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: site_id');
  end if;
end $$;

-- The assistant (if any) is another, active employee (or the one the entry already has).
create or replace function public.work_check_assistant(p_assistant uuid, p_surveyor uuid, p_current uuid)
returns void
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_status public.account_status;
begin
  if p_assistant is null then return; end if;
  if p_assistant = p_surveyor then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Not allowed: assistant_id');
  end if;
  select e.account_status into v_status from public.employees e where e.id = p_assistant;
  if not found or (v_status <> 'active' and p_assistant is distinct from p_current) then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: assistant_id');
  end if;
end $$;

-- The editable part of an entry as jsonb, for audit old/new values and summaries.
--   p_human false : ids and paise (stored in old_value / new_value)
--   p_human true  : names and rupee text (used only to build the one-line summary)
create or replace function public.work_state_json(
  p_site uuid, p_assistant uuid, p_date date, p_time time, p_remarks text,
  p_amount bigint, p_category text, p_version integer, p_human boolean
) returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_site text;
  v_asst text;
begin
  if p_human then
    select s.site_name into v_site from public.sites s where s.id = p_site;
    select e.name into v_asst from public.employees e where e.id = p_assistant;
    return jsonb_build_object(
      'site', v_site, 'assistant', v_asst, 'work date', p_date,
      'work time', to_char(p_time, 'HH24:MI'), 'remarks', p_remarks,
      'expense', case when p_amount is null then null else public.audit_rupees(p_amount) end,
      'category', p_category);
  end if;
  return jsonb_build_object(
    'site_id', p_site, 'assistant_id', p_assistant, 'work_date', p_date,
    'work_time', to_char(p_time, 'HH24:MI'), 'remarks', p_remarks,
    'expense_amount', p_amount, 'expense_category', p_category, 'version', p_version);
end $$;

-- The work entry object, as THIS viewer may see it. Returns null when the viewer may not
-- see the entry at all (callers turn that into MORAYA_NOT_FOUND). Access rule: an admin
-- (main_admin, or sub_admin with verification / report_view), the surveyor, or the assistant.
create or replace function public.work_entry_json(p_id uuid, p_viewer_id uuid, p_with_history boolean)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v        public.employees;
  w        record;
  v_admin  boolean;
  v_rev    boolean;
  v_surv   boolean;
  v_asst   boolean;
  v_money  boolean;
  v_out    jsonb;
  v_exp    jsonb;
  v_hist   jsonb;
  v_ehist  jsonb;
begin
  select e.* into v from public.employees e where e.id = p_viewer_id;
  if not found then return null; end if;

  select w0.*, s.site_name, s.site_location, s.client_name,
         su.name as surveyor_name, su.employee_id as surveyor_emp,
         a.name  as assistant_name, a.employee_id as assistant_emp,
         rv.name as reviewer_name, cb.name as cancelled_by_name
    into w
    from public.work_entries w0
    join public.sites s      on s.id  = w0.site_id
    join public.employees su on su.id = w0.surveyor_id
    left join public.employees a  on a.id  = w0.assistant_id
    left join public.employees rv on rv.id = w0.reviewed_by
    left join public.employees cb on cb.id = w0.cancelled_by
   where w0.id = p_id;
  if not found then return null; end if;

  v_admin := public.work_has_perm(v.id, v.role, array['verification', 'report_view']);
  v_rev   := public.work_has_perm(v.id, v.role, array['verification']);
  v_surv  := w.surveyor_id = v.id;
  v_asst  := w.assistant_id is not null and w.assistant_id = v.id;
  if not (v_admin or v_surv or v_asst) then return null; end if;
  v_money := v_admin or v_surv;

  v_out := jsonb_build_object(
    'id',            w.id,
    'code',          w.code,
    'work_date',     w.work_date,
    'work_time',     to_char(w.work_time, 'HH24:MI'),
    'remarks',       w.remarks,
    'status',        w.verification_status,
    'version',       w.version,
    'submitted_at',  w.submitted_at,
    'site',          jsonb_build_object('id', w.site_id, 'site_name', w.site_name,
                                        'site_location', w.site_location, 'client_name', w.client_name),
    'surveyor',      jsonb_build_object('id', w.surveyor_id, 'name', w.surveyor_name, 'employee_id', w.surveyor_emp),
    'assistant',     case when w.assistant_id is null then null
                          else jsonb_build_object('id', w.assistant_id, 'name', w.assistant_name,
                                                  'employee_id', w.assistant_emp) end,
    'reviewed_by_name', w.reviewer_name,
    'reviewed_at',   w.reviewed_at,
    'review_reason', w.review_reason,
    'cancelled_at',  w.cancelled_at,
    'cancelled_by_name', w.cancelled_by_name,
    'cancel_reason', w.cancel_reason,
    'created_at',    w.created_at,
    'updated_at',    w.updated_at,
    'viewer_role',   case when v_admin then 'admin' when v_surv then 'surveyor' else 'assistant' end,
    'capabilities',  jsonb_build_object(
        'can_resubmit', v_surv and w.verification_status = 'changes_requested',
        'can_review',   v_rev and not v_surv and not v_asst and w.verification_status = 'pending_verification',
        'can_cancel',   v_rev and public.work_entry_next_status(w.verification_status, 'cancel') is not null)
  );

  if v_money then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', x.id, 'amount', x.amount, 'category', x.category, 'category_label', c.label,
             'remarks', x.remarks, 'status', x.verification_status,
             'cancelled_at', x.cancelled_at, 'cancel_reason', x.cancel_reason)
           order by x.created_at, x.id), '[]'::jsonb)
      into v_exp
      from public.expenses x
      left join public.expense_categories c on c.code = x.category
     where x.work_entry_id = w.id;
    v_out := v_out || jsonb_build_object('expenses', v_exp,
                                         'expense_total', public.work_entry_expense_total(w.id));
  end if;

  if p_with_history then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', h.id, 'event', h.event, 'version', h.version, 'changed_at', h.changed_at,
             'changed_by_name', cb.name, 'status', h.verification_status,
             'site_name', hs.site_name, 'assistant_name', ha.name,
             'work_date', h.work_date, 'work_time', to_char(h.work_time, 'HH24:MI'),
             'remarks', h.remarks, 'review_reason', h.review_reason, 'cancel_reason', h.cancel_reason)
           order by h.id), '[]'::jsonb)
      into v_hist
      from (select * from public.work_entry_history hh
             where hh.work_entry_id = w.id order by hh.id limit 200) h
      join public.sites hs on hs.id = h.site_id
      left join public.employees cb on cb.id = h.changed_by
      left join public.employees ha on ha.id = h.assistant_id;
    v_out := v_out || jsonb_build_object('history', v_hist);

    if v_money then
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', eh.id, 'expense_id', eh.expense_id, 'event', eh.event,
               'version', eh.work_entry_version, 'changed_at', eh.changed_at,
               'amount', eh.amount, 'category', eh.category, 'status', eh.verification_status)
             order by eh.id), '[]'::jsonb)
        into v_ehist
        from (select * from public.expense_history e2
               where e2.work_entry_id = w.id order by e2.id limit 200) eh;
      v_out := v_out || jsonb_build_object('expense_history', v_ehist);
    end if;
  end if;

  return v_out;
end $$;

revoke all on function public.work_has_perm(uuid, public.user_role, text[])                from public, anon, authenticated, service_role;
revoke all on function public.work_entry_next_status(public.verification_status, text)     from public, anon, authenticated, service_role;
revoke all on function public.work_next_or_fail(public.verification_status, text)          from public, anon, authenticated, service_role;
revoke all on function public.work_entry_expense_total(uuid)                               from public, anon, authenticated, service_role;
revoke all on function public.work_clean_form(date, time, bigint, text, text)              from public, anon, authenticated, service_role;
revoke all on function public.work_check_site(uuid, uuid)                                  from public, anon, authenticated, service_role;
revoke all on function public.work_check_assistant(uuid, uuid, uuid)                       from public, anon, authenticated, service_role;
revoke all on function public.work_state_json(uuid, uuid, date, time, text, bigint, text, integer, boolean)
                                                                                           from public, anon, authenticated, service_role;
revoke all on function public.work_entry_json(uuid, uuid, boolean)                         from public, anon, authenticated, service_role;

-- =====================================================================================
-- 2. submit_work_entry
--    Surveyor = the caller. Creates the work entry (status pending_verification, round 1)
--    and, when p_expense_amount is given, its expense, in one transaction.
--    p_work_date / p_work_time are India local time; no future moment (also enforced by the
--    015 trigger). p_expense_amount in paise, null = no expense. p_expense_category
--    lowercase code, default 'other'.
--    The same surveyor, site, date and minute twice (double click) -> MORAYA_CONFLICT.
--    Audit: WORK_SUBMITTED. Returns {work_entry} (the surveyor's view).
--    Errors: MORAYA_FORBIDDEN (not an active employee), MORAYA_VALIDATION, MORAYA_CONFLICT
-- =====================================================================================
create or replace function public.submit_work_entry(
  p_actor_auth_id    uuid,
  p_site_id          uuid,
  p_work_date        date,
  p_work_time        time,
  p_assistant_id     uuid   default null,
  p_expense_amount   bigint default null,
  p_expense_category text   default null,
  p_remarks          text   default null,
  p_request_id       text   default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor public.employees;
  v_f     record;
  v_id    uuid;
  v_code  text;
  v_new   jsonb;
  v_human jsonb;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, null);

  select * into v_f from public.work_clean_form(p_work_date, p_work_time, p_expense_amount,
                                                p_expense_category, p_remarks);
  perform public.work_check_site(p_site_id, null);
  perform public.work_check_assistant(p_assistant_id, v_actor.id, null);

  begin
    insert into public.work_entries
      (site_id, surveyor_id, assistant_id, work_date, work_time, remarks, verification_status, submitted_at)
    values
      (p_site_id, v_actor.id, p_assistant_id, p_work_date, v_f.o_time, v_f.o_remarks,
       'pending_verification', now())
    returning id, code into v_id, v_code;

    if p_expense_amount is not null then
      insert into public.expenses (work_entry_id, employee_id, site_id, expense_date, amount, category)
      values (v_id, v_actor.id, p_site_id, p_work_date, p_expense_amount, v_f.o_category);
    end if;
  exception when unique_violation then
    perform public.moraya_fail('MORAYA_CONFLICT', 'Already exists: work_entry');
  end;

  v_new   := public.work_state_json(p_site_id, p_assistant_id, p_work_date, v_f.o_time, v_f.o_remarks,
                                    p_expense_amount, v_f.o_category, 1, false);
  v_human := public.work_state_json(p_site_id, p_assistant_id, p_work_date, v_f.o_time, v_f.o_remarks,
                                    p_expense_amount, v_f.o_category, 1, true);

  perform public.write_audit(
    v_actor.id, 'WORK_SUBMITTED', 'work_entry', v_id::text,
    null,
    v_new || jsonb_build_object('code', v_code, 'status', 'pending_verification'),
    null, p_request_id,
    'Submitted work entry ' || v_code || ' for ' || coalesce(v_human ->> 'site', '-')
      || ' on ' || p_work_date::text
      || case when p_expense_amount is null then '' else ' (expense ' || public.audit_rupees(p_expense_amount) || ')' end
  );

  return jsonb_build_object('work_entry', public.work_entry_json(v_id, v_actor.id, false));
end $$;

-- =====================================================================================
-- 3. resubmit_work_entry
--    Only the surveyor of the entry, only from changes_requested. Full replacement of the
--    form (assumption 5). Round goes up by one (version + 1), status back to
--    pending_verification, review fields cleared (the history keeps the old reason).
--    p_version optional: the round the worker was editing (VERSION_CONFLICT if different).
--    The 015/016 triggers snapshot the previous round into the history tables and move the
--    expense with the entry.
--    Audit: WORK_RESUBMITTED (old and new editable fields). Returns {work_entry}.
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND, MORAYA_INVALID_STATE, MORAYA_VALIDATION,
--            MORAYA_CONFLICT
-- =====================================================================================
create or replace function public.resubmit_work_entry(
  p_actor_auth_id    uuid,
  p_work_entry_id    uuid,
  p_site_id          uuid,
  p_work_date        date,
  p_work_time        time,
  p_assistant_id     uuid   default null,
  p_expense_amount   bigint default null,
  p_expense_category text   default null,
  p_remarks          text   default null,
  p_version          integer default null,
  p_request_id       text   default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  public.employees;
  v_f      record;
  v_w      public.work_entries;
  v_x      public.expenses;
  v_has_x  boolean;
  v_next   public.verification_status;
  v_old    jsonb;
  v_new    jsonb;
  v_old_h  jsonb;
  v_new_h  jsonb;
  v_round  integer;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, null);

  select * into v_f from public.work_clean_form(p_work_date, p_work_time, p_expense_amount,
                                                p_expense_category, p_remarks);

  select * into v_w from public.work_entries w where w.id = p_work_entry_id for update;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Work entry not found');
  end if;
  if v_w.surveyor_id <> v_actor.id then
    perform public.moraya_fail('MORAYA_FORBIDDEN');
  end if;

  v_next := public.work_next_or_fail(v_w.verification_status, 'resubmit');
  if p_version is not null and p_version <> v_w.version then
    perform public.moraya_fail('MORAYA_CONFLICT', 'VERSION_CONFLICT');
  end if;

  perform public.work_check_site(p_site_id, v_w.site_id);
  perform public.work_check_assistant(p_assistant_id, v_actor.id, v_w.assistant_id);

  -- The one live expense (this file creates at most one per entry).
  select * into v_x from public.expenses x
   where x.work_entry_id = v_w.id and x.verification_status <> 'cancelled'
   order by x.created_at, x.id limit 1 for update;
  v_has_x := found;

  v_old   := public.work_state_json(v_w.site_id, v_w.assistant_id, v_w.work_date, v_w.work_time, v_w.remarks,
                                    case when v_has_x then v_x.amount end,
                                    case when v_has_x then v_x.category end, v_w.version, false);
  v_old_h := public.work_state_json(v_w.site_id, v_w.assistant_id, v_w.work_date, v_w.work_time, v_w.remarks,
                                    case when v_has_x then v_x.amount end,
                                    case when v_has_x then v_x.category end, v_w.version, true);
  v_round := v_w.version + 1;

  -- 1) The entry first: its status/site/date change cascades to the expense (016 trigger),
  --    which also makes the expense editable again for step 2.
  begin
    update public.work_entries w set
      site_id             = p_site_id,
      assistant_id        = p_assistant_id,
      work_date           = p_work_date,
      work_time           = v_f.o_time,
      remarks             = v_f.o_remarks,
      verification_status = v_next,
      version             = v_round,
      submitted_at        = now(),
      reviewed_by         = null,
      reviewed_at         = null,
      review_reason       = null
    where w.id = v_w.id;
  exception when unique_violation then
    perform public.moraya_fail('MORAYA_CONFLICT', 'Already exists: work_entry');
  end;

  -- 2) The expense content.
  if p_expense_amount is null then
    if v_has_x then
      update public.expenses x set
        verification_status = 'cancelled',
        cancelled_at        = now(),
        cancelled_by        = v_actor.id,
        cancel_reason       = 'Removed by the surveyor when resubmitting'
      where x.id = v_x.id;
    end if;
  elsif v_has_x then
    update public.expenses x set amount = p_expense_amount, category = v_f.o_category
     where x.id = v_x.id
       and (x.amount, x.category) is distinct from (p_expense_amount, v_f.o_category);
  else
    insert into public.expenses (work_entry_id, employee_id, site_id, expense_date, amount, category)
    values (v_w.id, v_actor.id, p_site_id, p_work_date, p_expense_amount, v_f.o_category);
  end if;

  v_new   := public.work_state_json(p_site_id, p_assistant_id, p_work_date, v_f.o_time, v_f.o_remarks,
                                    p_expense_amount, v_f.o_category, v_round, false);
  v_new_h := public.work_state_json(p_site_id, p_assistant_id, p_work_date, v_f.o_time, v_f.o_remarks,
                                    p_expense_amount, v_f.o_category, v_round, true);

  perform public.write_audit(
    v_actor.id, 'WORK_RESUBMITTED', 'work_entry', v_w.id::text,
    v_old || jsonb_build_object('status', v_w.verification_status::text),
    v_new || jsonb_build_object('status', v_next::text),
    null, p_request_id,
    public.audit_diff_summary('Resubmitted work entry ' || v_w.code || ' (round ' || v_round::text || '):',
                              v_old_h, v_new_h)
  );

  return jsonb_build_object('work_entry', public.work_entry_json(v_w.id, v_actor.id, false));
end $$;

-- =====================================================================================
-- 4. work_entry_review (INTERNAL; the four public wrappers below call it)
--    p_action: 'approve' | 'request_changes' | 'reject' | 'cancel'
--    Order of checks: permission -> reason -> entry exists -> not a participant (not for
--    cancel) -> legal transition -> version. Reason is required for everything except
--    approve (5-500 characters).
--    Returns {work_entry (admin view), previous_status}.
-- =====================================================================================
create or replace function public.work_entry_review(
  p_actor_auth_id uuid,
  p_work_entry_id uuid,
  p_action        text,
  p_reason        text,
  p_version       integer,
  p_request_id    text
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor   public.employees;
  v_w       public.work_entries;
  v_next    public.verification_status;
  v_reason  text;
  v_total   bigint;
  v_sname   text;
  v_site    text;
  v_audit   text;
  v_verb    text;
begin
  v_actor  := public.moraya_require_actor(p_actor_auth_id, false, array['verification']);
  v_reason := public.employee_clean_reason(p_reason, p_action <> 'approve');

  select * into v_w from public.work_entries w where w.id = p_work_entry_id for update;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Work entry not found');
  end if;

  if p_action <> 'cancel'
     and (v_w.surveyor_id = v_actor.id or v_w.assistant_id is not distinct from v_actor.id) then
    perform public.moraya_fail('MORAYA_FORBIDDEN');   -- nobody reviews their own work
  end if;

  v_next := public.work_next_or_fail(v_w.verification_status, p_action);
  if p_version is not null and p_version <> v_w.version then
    perform public.moraya_fail('MORAYA_CONFLICT', 'VERSION_CONFLICT');
  end if;

  v_total := public.work_entry_expense_total(v_w.id);
  select e.name into v_sname from public.employees e where e.id = v_w.surveyor_id;
  select s.site_name into v_site from public.sites s where s.id = v_w.site_id;

  if p_action = 'approve' then
    update public.work_entries w set
      verification_status = v_next, reviewed_by = v_actor.id, reviewed_at = now(), review_reason = null
    where w.id = v_w.id;
    v_audit := 'WORK_APPROVED';        v_verb := 'Approved';
  elsif p_action in ('request_changes', 'reject') then
    update public.work_entries w set
      verification_status = v_next, reviewed_by = v_actor.id, reviewed_at = now(), review_reason = v_reason
    where w.id = v_w.id;
    v_audit := case p_action when 'reject' then 'WORK_REJECTED' else 'WORK_CHANGES_REQUESTED' end;
    v_verb  := case p_action when 'reject' then 'Rejected'      else 'Requested changes on' end;
  else  -- cancel
    update public.work_entries w set
      verification_status = v_next, cancelled_at = now(), cancelled_by = v_actor.id, cancel_reason = v_reason
    where w.id = v_w.id;
    v_audit := 'WORK_CANCELLED';       v_verb := 'Cancelled';
  end if;

  perform public.write_audit(
    v_actor.id, v_audit, 'work_entry', v_w.id::text,
    jsonb_build_object('status', v_w.verification_status::text, 'version', v_w.version),
    jsonb_build_object('status', v_next::text, 'version', v_w.version, 'expense_amount', v_total),
    v_reason, p_request_id,
    v_verb || ' work entry ' || v_w.code || ' (' || coalesce(v_sname, '-') || ', ' || coalesce(v_site, '-')
      || case when v_total is null then '' else ', ' || public.audit_rupees(v_total) end || ')'
  );

  return jsonb_build_object('work_entry', public.work_entry_json(v_w.id, v_actor.id, false),
                            'previous_status', v_w.verification_status);
end $$;

revoke all on function public.work_entry_review(uuid, uuid, text, text, integer, text)
  from public, anon, authenticated, service_role;

-- =====================================================================================
-- 5. approve_work_entry / request_work_entry_changes / reject_work_entry / cancel_work_entry
--    Permission: main_admin or sub_admin with 'verification' (else MORAYA_FORBIDDEN).
--    approve / request_changes / reject: the entry must be pending_verification and the
--      caller must be neither its surveyor nor its assistant (MORAYA_FORBIDDEN).
--    request_changes / reject / cancel: p_reason required, 5-500 characters
--      (MORAYA_VALIDATION 'Required: reason' / 'Too short: reason' / 'Too long: reason').
--    cancel: legal from draft, pending_verification, changes_requested, verified.
--    p_version optional (assumption 4). The expense(s) follow the entry in the same
--    transaction (verified / changes_requested / rejected / cancelled).
--    Approve stores reviewed_by + reviewed_at; the entry then counts in official totals.
--    Audit: WORK_APPROVED | WORK_CHANGES_REQUESTED | WORK_REJECTED | WORK_CANCELLED.
--    Return {work_entry, previous_status}.
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND, MORAYA_INVALID_STATE, MORAYA_VALIDATION,
--            MORAYA_CONFLICT
-- =====================================================================================
create or replace function public.approve_work_entry(
  p_actor_auth_id uuid,
  p_work_entry_id uuid,
  p_version       integer default null,
  p_request_id    text    default null
) returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
  select public.work_entry_review(p_actor_auth_id, p_work_entry_id, 'approve', null, p_version, p_request_id);
$$;

create or replace function public.request_work_entry_changes(
  p_actor_auth_id uuid,
  p_work_entry_id uuid,
  p_reason        text,
  p_version       integer default null,
  p_request_id    text    default null
) returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
  select public.work_entry_review(p_actor_auth_id, p_work_entry_id, 'request_changes', p_reason, p_version, p_request_id);
$$;

create or replace function public.reject_work_entry(
  p_actor_auth_id uuid,
  p_work_entry_id uuid,
  p_reason        text,
  p_version       integer default null,
  p_request_id    text    default null
) returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
  select public.work_entry_review(p_actor_auth_id, p_work_entry_id, 'reject', p_reason, p_version, p_request_id);
$$;

create or replace function public.cancel_work_entry(
  p_actor_auth_id uuid,
  p_work_entry_id uuid,
  p_reason        text,
  p_version       integer default null,
  p_request_id    text    default null
) returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
  select public.work_entry_review(p_actor_auth_id, p_work_entry_id, 'cancel', p_reason, p_version, p_request_id);
$$;

-- =====================================================================================
-- 6. work_entries_page (INTERNAL): one list implementation behind list_work_entries_admin
--    and list_my_work.
--    p_mode 'admin' : all entries; p_employee_id matches surveyor OR assistant
--    p_mode 'mine'  : only entries where the viewer is surveyor or assistant (p_role
--                     'all' | 'surveyor' | 'assistant' narrows it); expense_amount is
--                     returned ONLY on rows where the viewer is the surveyor (else null)
--    Filters: date range (inclusive, India dates), site, status ('all' or a status name),
--    q (code, site, client, surveyor or assistant name; max 100; % _ \ are literal).
--    Sort '<field>:<asc|desc>', field in work_date, submitted_at, code, status.
--    Page size capped to 1..100. Ties always end by code desc.
--    Returns {items[], page, page_size, total, totals{<status>: count}}
--      total  = rows matching ALL filters; totals = counts per status over the same
--      filters EXCEPT the status filter (for the status tabs).
-- =====================================================================================
create or replace function public.work_entries_page(
  p_viewer_id   uuid,
  p_mode        text,
  p_date_from   date,
  p_date_to     date,
  p_employee_id uuid,
  p_site_id     uuid,
  p_status      text,
  p_role        text,
  p_q           text,
  p_sort        text,
  p_page        integer,
  p_page_size   integer
) returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_status text := lower(btrim(coalesce(p_status, 'all')));
  v_role   text := lower(btrim(coalesce(p_role, 'all')));
  v_q      text := btrim(coalesce(p_q, ''));
  v_pat    text;
  v_field  text;
  v_dir    text;
  v_order  text;
  v_emp    uuid;
  v_page   int;
  v_size   int;
  v_from   text;
  v_sql    text;
  v_total  bigint;
  v_c_draft bigint; v_c_pending bigint; v_c_verified bigint;
  v_c_changes bigint; v_c_rejected bigint; v_c_cancelled bigint;
  v_items  jsonb;
begin
  if v_status not in ('all', 'draft', 'pending_verification', 'verified', 'changes_requested', 'rejected', 'cancelled') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: status');
  end if;
  if v_role not in ('all', 'surveyor', 'assistant') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: role');
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

  v_field := lower(btrim(split_part(coalesce(p_sort, 'work_date:desc'), ':', 1)));
  v_dir   := lower(btrim(split_part(coalesce(p_sort, 'work_date:desc'), ':', 2)));
  if v_dir = '' then v_dir := 'asc'; end if;
  if v_dir not in ('asc', 'desc') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: sort');
  end if;
  v_order := case v_field
    when 'work_date'    then 'w.work_date ' || v_dir || ', w.work_time ' || v_dir
    when 'submitted_at' then 'w.submitted_at ' || v_dir || ' nulls last'
    when 'code'         then 'w.code ' || v_dir
    when 'status'       then 'w.verification_status ' || v_dir
    else null end;
  if v_order is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: sort');
  end if;
  v_order := v_order || ', w.code desc';

  v_page := greatest(1, least(coalesce(p_page, 1), 100000));
  v_size := greatest(1, least(coalesce(p_page_size, 20), 100));

  -- Whose entries: admin -> the optional employee filter ('all' roles); mine -> the viewer.
  if p_mode = 'mine' then
    v_emp := p_viewer_id;
  else
    v_emp := p_employee_id;
    v_role := 'all';
  end if;

  -- Shared FROM + filters (everything except status). $1 from, $2 to, $3 site,
  -- $4 employee, $5 role, $6 search pattern.
  v_from := $f$
      from public.work_entries w
      join public.sites s      on s.id  = w.site_id
      join public.employees su on su.id = w.surveyor_id
      left join public.employees a  on a.id  = w.assistant_id
      left join public.employees rv on rv.id = w.reviewed_by
     where ($1::date is null or w.work_date >= $1)
       and ($2::date is null or w.work_date <= $2)
       and ($3::uuid is null or w.site_id = $3)
       and ($4::uuid is null or (($5::text in ('all', 'surveyor') and w.surveyor_id = $4)
                              or ($5::text in ('all', 'assistant') and w.assistant_id = $4)))
       and ($6::text is null or w.code ilike $6 escape '\'
                             or s.site_name ilike $6 escape '\'
                             or s.client_name ilike $6 escape '\'
                             or su.name ilike $6 escape '\'
                             or a.name ilike $6 escape '\')
  $f$;

  -- Counts: total for the selected status, plus one count per status.
  v_sql := 'select count(*) filter (where $7::text = ''all'' or w.verification_status::text = $7::text),
                   count(*) filter (where w.verification_status = ''draft''),
                   count(*) filter (where w.verification_status = ''pending_verification''),
                   count(*) filter (where w.verification_status = ''verified''),
                   count(*) filter (where w.verification_status = ''changes_requested''),
                   count(*) filter (where w.verification_status = ''rejected''),
                   count(*) filter (where w.verification_status = ''cancelled'') ' || v_from;
  execute v_sql
    into v_total, v_c_draft, v_c_pending, v_c_verified, v_c_changes, v_c_rejected, v_c_cancelled
    using p_date_from, p_date_to, p_site_id, v_emp, v_role, v_pat, v_status;

  -- Page. The expense total is computed in the OUTER query, only for the page rows.
  -- $7 status, $8 limit, $9 offset, $10 admin mode, $11 viewer.
  v_sql := 'select coalesce(jsonb_agg(jsonb_build_object(
              ''id'', p.id, ''code'', p.code, ''work_date'', p.work_date,
              ''work_time'', to_char(p.work_time, ''HH24:MI''), ''remarks'', p.remarks,
              ''status'', p.verification_status, ''version'', p.version, ''submitted_at'', p.submitted_at,
              ''site'', jsonb_build_object(''id'', p.site_id, ''site_name'', p.site_name,
                                          ''site_location'', p.site_location, ''client_name'', p.client_name),
              ''surveyor'', jsonb_build_object(''id'', p.surveyor_id, ''name'', p.surveyor_name,
                                              ''employee_id'', p.surveyor_emp),
              ''assistant'', case when p.assistant_id is null then null
                                else jsonb_build_object(''id'', p.assistant_id, ''name'', p.assistant_name,
                                                        ''employee_id'', p.assistant_emp) end,
              ''is_surveyor'', (p.surveyor_id = $11),
              ''expense_amount'', case when $10 or p.surveyor_id = $11
                                       then public.work_entry_expense_total(p.id) end,
              ''reviewed_by_name'', p.reviewer_name, ''reviewed_at'', p.reviewed_at,
              ''review_reason'', p.review_reason, ''cancelled_at'', p.cancelled_at,
              ''cancel_reason'', p.cancel_reason
            ) order by p.rn), ''[]''::jsonb)
            from (
              select row_number() over (order by ' || v_order || ') as rn,
                     w.id, w.code, w.work_date, w.work_time, w.remarks, w.verification_status, w.version,
                     w.submitted_at, w.reviewed_at, w.review_reason, w.cancelled_at, w.cancel_reason,
                     w.site_id, s.site_name, s.site_location, s.client_name,
                     w.surveyor_id, su.name as surveyor_name, su.employee_id as surveyor_emp,
                     w.assistant_id, a.name as assistant_name, a.employee_id as assistant_emp,
                     rv.name as reviewer_name '
            || v_from
            || ' and ($7::text = ''all'' or w.verification_status::text = $7::text)
                 order by ' || v_order || '
                 limit $8 offset $9) p';
  execute v_sql
    into v_items
    using p_date_from, p_date_to, p_site_id, v_emp, v_role, v_pat, v_status,
          v_size, (v_page - 1) * v_size, (p_mode = 'admin'), p_viewer_id;

  return jsonb_build_object(
    'items',     v_items,
    'page',      v_page,
    'page_size', v_size,
    'total',     v_total,
    'totals',    jsonb_build_object('draft', v_c_draft, 'pending_verification', v_c_pending, 'verified', v_c_verified,
                                    'changes_requested', v_c_changes, 'rejected', v_c_rejected, 'cancelled', v_c_cancelled)
  );
end $$;

revoke all on function public.work_entries_page(uuid, text, date, date, uuid, uuid, text, text, text, text, integer, integer)
  from public, anon, authenticated, service_role;

-- =====================================================================================
-- 7. list_work_entries_admin
--    main_admin, or sub_admin with 'verification' or 'report_view'. Filters: date range
--    (work_date, inclusive), employee (surveyor OR assistant), site, status ('all' or one
--    status), q (code, site, client, surveyor or assistant name). p_sort default
--    'work_date:desc'; use 'submitted_at:asc' with status 'pending_verification' for the
--    Verification Center queue (oldest first).
--    Returns {items[], page, page_size, total, totals{status counts}, capabilities{can_review}}
--      items[]: id, code, work_date, work_time, remarks, status, version, submitted_at,
--               site{}, surveyor{}, assistant{}|null, expense_amount (paise, live expenses),
--               reviewed_by_name, reviewed_at, review_reason, cancelled_at, cancel_reason
--    Errors: MORAYA_FORBIDDEN, MORAYA_VALIDATION
-- =====================================================================================
create or replace function public.list_work_entries_admin(
  p_actor_auth_id uuid,
  p_date_from     date    default null,
  p_date_to       date    default null,
  p_employee_id   uuid    default null,
  p_site_id       uuid    default null,
  p_status        text    default 'all',
  p_q             text    default null,
  p_sort          text    default 'work_date:desc',
  p_page          integer default 1,
  p_page_size     integer default 20
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor public.employees;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, array['verification', 'report_view']);
  return public.work_entries_page(v_actor.id, 'admin', p_date_from, p_date_to, p_employee_id, p_site_id,
                                  p_status, 'all', p_q, p_sort, p_page, p_page_size)
         || jsonb_build_object('capabilities', jsonb_build_object(
              'can_review', public.work_has_perm(v_actor.id, v_actor.role, array['verification'])));
end $$;

-- =====================================================================================
-- 8. list_my_work
--    Any ACTIVE employee. Entries where the caller is the surveyor OR the assistant.
--    p_role 'all' (default) | 'surveyor' | 'assistant'. Filters: date range, site, status,
--    q. expense_amount is filled only on rows where the caller is the surveyor (null on
--    rows where they were the assistant). Same shape as list_work_entries_admin.
--    Errors: MORAYA_FORBIDDEN, MORAYA_VALIDATION
-- =====================================================================================
create or replace function public.list_my_work(
  p_actor_auth_id uuid,
  p_date_from     date    default null,
  p_date_to       date    default null,
  p_site_id       uuid    default null,
  p_status        text    default 'all',
  p_role          text    default 'all',
  p_q             text    default null,
  p_sort          text    default 'work_date:desc',
  p_page          integer default 1,
  p_page_size     integer default 20
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor public.employees;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, null);
  return public.work_entries_page(v_actor.id, 'mine', p_date_from, p_date_to, null, p_site_id,
                                  p_status, p_role, p_q, p_sort, p_page, p_page_size);
end $$;

-- =====================================================================================
-- 9. get_work_entry
--    Any ACTIVE employee who may see the entry (admin, surveyor or assistant; see "WHO SEES
--    WHAT"). Returns {work_entry} with the work history (every round and status change,
--    oldest first) and, for admin and surveyor only, expenses, expense_total and the
--    expense history. capabilities say what the screen may offer (can_resubmit, can_review,
--    can_cancel). Anyone else gets MORAYA_NOT_FOUND. Reading is not audited.
--    Errors: MORAYA_FORBIDDEN, MORAYA_NOT_FOUND
-- =====================================================================================
create or replace function public.get_work_entry(
  p_actor_auth_id uuid,
  p_work_entry_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor public.employees;
  v_json  jsonb;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, null);
  v_json  := public.work_entry_json(p_work_entry_id, v_actor.id, true);
  if v_json is null then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Work entry not found');
  end if;
  return jsonb_build_object('work_entry', v_json);
end $$;

-- =====================================================================================
-- 10. Grants: service_role only
-- =====================================================================================
revoke all on function public.submit_work_entry(uuid, uuid, date, time, uuid, bigint, text, text, text)
  from public, anon, authenticated;
revoke all on function public.resubmit_work_entry(uuid, uuid, uuid, date, time, uuid, bigint, text, text, integer, text)
  from public, anon, authenticated;
revoke all on function public.approve_work_entry(uuid, uuid, integer, text)                from public, anon, authenticated;
revoke all on function public.request_work_entry_changes(uuid, uuid, text, integer, text)  from public, anon, authenticated;
revoke all on function public.reject_work_entry(uuid, uuid, text, integer, text)           from public, anon, authenticated;
revoke all on function public.cancel_work_entry(uuid, uuid, text, integer, text)           from public, anon, authenticated;
revoke all on function public.list_work_entries_admin(uuid, date, date, uuid, uuid, text, text, text, integer, integer)
  from public, anon, authenticated;
revoke all on function public.list_my_work(uuid, date, date, uuid, text, text, text, text, integer, integer)
  from public, anon, authenticated;
revoke all on function public.get_work_entry(uuid, uuid)                                   from public, anon, authenticated;

grant execute on function public.submit_work_entry(uuid, uuid, date, time, uuid, bigint, text, text, text)  to service_role;
grant execute on function public.resubmit_work_entry(uuid, uuid, uuid, date, time, uuid, bigint, text, text, integer, text)
  to service_role;
grant execute on function public.approve_work_entry(uuid, uuid, integer, text)                to service_role;
grant execute on function public.request_work_entry_changes(uuid, uuid, text, integer, text)  to service_role;
grant execute on function public.reject_work_entry(uuid, uuid, text, integer, text)           to service_role;
grant execute on function public.cancel_work_entry(uuid, uuid, text, integer, text)           to service_role;
grant execute on function public.list_work_entries_admin(uuid, date, date, uuid, uuid, text, text, text, integer, integer)
  to service_role;
grant execute on function public.list_my_work(uuid, date, date, uuid, text, text, text, text, integer, integer)
  to service_role;
grant execute on function public.get_work_entry(uuid, uuid)                                   to service_role;