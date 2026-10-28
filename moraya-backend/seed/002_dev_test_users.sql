-- seed/002_dev_test_users.sql
-- *** LOCAL / DEV TESTING ONLY. NEVER RUN THIS ON PRODUCTION. ***
-- It creates fake people, sites, work entries, expenses, income and salary rows so every screen has data.
-- It REPLACES seed/001_main_admin.sql on a dev database (it creates its own Main Admin): run one or the other.
--
-- BEFORE RUNNING (the seed cannot create Supabase Auth users)
--   Supabase Dashboard > Authentication > Users > Add user (tick "Auto confirm user"), four users,
--   each with a password you choose (dev only, never reused anywhere):
--       dev-main@moraya.test      -> becomes the Main Admin  (EMP-D001)
--       dev-sub@moraya.test       -> becomes a Sub Admin     (EMP-D002) with site_management, verification,
--                                    income_management, report_view
--       dev-worker1@moraya.test   -> Worker One              (EMP-D003)
--       dev-worker2@moraya.test   -> Worker Two              (EMP-D004)
--   The seed finds each Auth user by email and stops with a clear message if one is missing.
--
-- RUN: migrations 001-026 first, then this file once, in the SQL editor (runs as postgres).
--      It aborts if public.employees already has rows. To start over: reset the dev database.
--
-- WHAT YOU GET (money in paise; dates are relative to today in India, so they are always in the past)
--   Sites : Dev Site Alpha (active, Rs 1000/visit), Dev Site Beta (active, Rs 1500/visit), Dev Site Gamma (completed, no rate)
--   Work  : verified (x3, one with two people), pending, rejected, changes requested, cancelled
--   Income: pending, partially received, received, cancelled
--   Salary: paid, partially paid, pending
--   Fake Aadhaar numbers (pass the check digit, belong to nobody): W1 2345 6789 0124, W2 3456 7890 1238
--   Fake Aadhaar encryption key used here: dev-only-aadhaar-key-0123456789abcdef0123456789
--     (use the same value as AADHAAR_ENC_KEY in .dev.vars so reveal works locally; never reuse it in production)
-- ROLLBACK: none needed; to remove everything reset the dev database.

do $$
declare
  c_key  constant text := 'dev-only-aadhaar-key-0123456789abcdef0123456789';
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_pm_start date := (date_trunc('month', v_today) - interval '1 month')::date;
  v_pm_end   date := (date_trunc('month', v_today) - interval '1 day')::date;
  v_ppm_start date := (date_trunc('month', v_today) - interval '2 months')::date;
  v_ppm_end   date := (date_trunc('month', v_today) - interval '1 month' - interval '1 day')::date;
  u_main uuid; u_sub uuid; u_w1 uuid; u_w2 uuid;
  e_main uuid; e_sub uuid; e_w1 uuid; e_w2 uuid;
  a uuid; b uuid; g uuid;
  w uuid; i uuid;
  v_missing text := '';
begin
  if exists (select 1 from public.employees) then
    raise exception 'STOP: public.employees already has rows. This seed is for an empty DEV database only.';
  end if;

  select id into u_main from auth.users where lower(email) = 'dev-main@moraya.test';
  select id into u_sub  from auth.users where lower(email) = 'dev-sub@moraya.test';
  select id into u_w1   from auth.users where lower(email) = 'dev-worker1@moraya.test';
  select id into u_w2   from auth.users where lower(email) = 'dev-worker2@moraya.test';
  if u_main is null then v_missing := v_missing || ' dev-main@moraya.test'; end if;
  if u_sub  is null then v_missing := v_missing || ' dev-sub@moraya.test'; end if;
  if u_w1   is null then v_missing := v_missing || ' dev-worker1@moraya.test'; end if;
  if u_w2   is null then v_missing := v_missing || ' dev-worker2@moraya.test'; end if;
  if v_missing <> '' then
    raise exception 'Create these users first in Authentication > Users:%', v_missing;
  end if;

  -- People ---------------------------------------------------------------------------------------
  insert into public.employees (auth_user_id, employee_id, name, login_email, role, designation, date_of_birth, date_of_joining)
  values (u_main, 'EMP-D001', 'Dev Main Admin', 'dev-main@moraya.test', 'main_admin', 'Director', date '1980-01-15', date '2015-04-01')
  returning id into e_main;
  insert into public.employees (auth_user_id, employee_id, name, login_email, role, designation, date_of_birth, date_of_joining, created_by)
  values (u_sub, 'EMP-D002', 'Dev Sub Admin', 'dev-sub@moraya.test', 'sub_admin', 'Office Manager', date '1988-06-20', date '2018-07-01', e_main)
  returning id into e_sub;
  insert into public.employees (auth_user_id, employee_id, name, login_email, role, designation, date_of_birth, date_of_joining, created_by)
  values (u_w1, 'EMP-D003', 'Dev Worker One', 'dev-worker1@moraya.test', 'worker', 'Surveyor', date '1992-03-10', date '2020-01-06', e_main)
  returning id into e_w1;
  insert into public.employees (auth_user_id, employee_id, name, login_email, role, designation, date_of_birth, date_of_joining, created_by)
  values (u_w2, 'EMP-D004', 'Dev Worker Two', 'dev-worker2@moraya.test', 'worker', 'Assistant', date '1995-11-02', date '2021-09-15', e_main)
  returning id into e_w2;

  insert into public.sub_admin_permissions (employee_id, permission) values
    (e_sub, 'site_management'), (e_sub, 'verification'), (e_sub, 'income_management'), (e_sub, 'report_view');

  perform public.set_employee_aadhaar(e_w1, '234567890124', c_key);
  perform public.set_employee_aadhaar(e_w2, '345678901238', c_key);

  -- Sites (created by the sub admin, who has site_management) ------------------------------------------
  a := (public.create_site(u_sub, 'Dev Site Alpha', 'Dev Client One', 'Dev Location Alpha', v_today - 40, 100000) -> 'site' ->> 'id')::uuid;
  b := (public.create_site(u_sub, 'Dev Site Beta',  'Dev Client Two', 'Dev Location Beta',  v_today - 35, 150000) -> 'site' ->> 'id')::uuid;
  g := (public.create_site(u_sub, 'Dev Site Gamma', 'Dev Client One', 'Dev Location Gamma', v_today - 60, null)   -> 'site' ->> 'id')::uuid;

  -- Work entries (submitted by the workers, reviewed by the sub admin) -----------------------------------
  -- 1. verified, two people, expense Rs 500
  w := (public.submit_work_entry(u_w1, a, v_today - 12, time '10:00', e_w2, 50000, 'travel', 'Boundary survey') -> 'work_entry' ->> 'id')::uuid;
  perform public.approve_work_entry(u_sub, w);
  -- 2. verified, same site and day as #1 (one visit, two entries), expense Rs 300
  w := (public.submit_work_entry(u_w2, a, v_today - 12, time '11:00', null, 30000, 'food', null) -> 'work_entry' ->> 'id')::uuid;
  perform public.approve_work_entry(u_sub, w);
  -- 3. verified, site Gamma (completed afterwards), no expense
  w := (public.submit_work_entry(u_w1, g, v_today - 11, time '09:30', null, null, null, 'Final measurements') -> 'work_entry' ->> 'id')::uuid;
  perform public.approve_work_entry(u_sub, w);
  -- 4. pending, Beta, expense Rs 200
  perform public.submit_work_entry(u_w1, b, v_today - 5, time '09:00', null, 20000, 'transport', null);
  -- 5. rejected, Alpha, expense Rs 700
  w := (public.submit_work_entry(u_w1, a, v_today - 7, time '09:30', null, 70000, 'travel', null) -> 'work_entry' ->> 'id')::uuid;
  perform public.reject_work_entry(u_sub, w, 'Wrong site recorded');
  -- 6. changes requested, Beta, expense Rs 100
  w := (public.submit_work_entry(u_w2, b, v_today - 4, time '09:30', null, 10000, 'food', null) -> 'work_entry' ->> 'id')::uuid;
  perform public.request_work_entry_changes(u_sub, w, 'Please correct the time');
  -- 7. verified then cancelled, Alpha, expense Rs 900
  w := (public.submit_work_entry(u_w2, a, v_today - 9, time '09:30', null, 90000, 'travel', null) -> 'work_entry' ->> 'id')::uuid;
  perform public.approve_work_entry(u_sub, w);
  perform public.cancel_work_entry(u_sub, w, 'Entered by mistake');

  perform public.set_site_status(u_sub, g, 'completed', 'Work finished');

  -- Income (sub admin has income_management) ------------------------------------------------------------
  perform public.create_income(u_sub, a, v_today - 10, 500000, 'Alpha stage 1 bill', 500000);           -- received
  perform public.create_income(u_sub, a, v_today - 8,  300000, 'Alpha stage 2 bill', 100000);           -- partially received
  perform public.create_income(u_sub, b, v_today - 6,  400000, 'Beta advance bill',  0);                -- pending
  i := (public.create_income(u_sub, b, v_today - 3, 99900, 'Duplicate entry', 0) -> 'income' ->> 'id')::uuid;
  perform public.cancel_income(u_main, i, null, 'Duplicate entry');                                      -- cancelled

  -- Salary (main admin: the sub admin above has no salary_management) -----------------------------------
  perform public.create_salary(u_main, e_w1, v_pm_start,  v_pm_end,  400000, 400000, least(v_pm_end + 1, v_today)); -- paid
  perform public.create_salary(u_main, e_w2, v_pm_start,  v_pm_end,  300000, 100000, least(v_pm_end + 2, v_today)); -- partially paid
  perform public.create_salary(u_main, e_w1, v_ppm_start, v_ppm_end, 380000, 0,      null);                         -- pending

  raise notice 'Dev seed done: 4 people, 3 sites, 7 work entries, 4 income rows, 3 salary rows.';
end $$;

-- Quick look
select employee_id, name, login_email, role, account_status from public.employees order by employee_id;