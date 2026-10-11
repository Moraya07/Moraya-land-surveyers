-- Seed the FIRST Main Admin. Run once in the Supabase SQL editor, after migrations.
-- 1) Create the user in Supabase Dashboard > Authentication > Users (email + strong password chosen by the owner).
-- 2) Replace the four placeholders below. Email must match the Auth user's email.
-- No credentials live in this repository.
insert into public.employees (auth_user_id, employee_id, name, login_email, role, account_status)
values (
  '00000000-0000-0000-0000-000000000000',  -- <AUTH_USER_ID> from the Users table
  'EMP-0001',                               -- <EMPLOYEE_ID>
  'Replace With Name',                      -- <NAME>
  'owner@example.com',                      -- <EMAIL> (lowercase)
  'main_admin',
  'active'
);

-- Verify:
select id, employee_id, name, login_email, role, account_status from public.employees where role = 'main_admin';
