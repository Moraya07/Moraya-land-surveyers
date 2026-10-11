-- 002: employees (login subset) + Main Admin protection. Later phases add more columns.
create table if not exists public.employees (
  id               uuid primary key default gen_random_uuid(),
  auth_user_id     uuid not null unique references auth.users(id) on delete restrict,
  sr_no            bigint generated always as identity,
  employee_id      text not null unique,
  name             text not null,
  login_email      citext not null unique,
  role             public.user_role not null default 'worker',
  account_status   public.account_status not null default 'active',
  designation      text,
  date_of_birth    date,
  date_of_joining  date,
  created_by       uuid references public.employees(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint employees_login_email_lowercase check (login_email::text = lower(login_email::text))
);

drop trigger if exists employees_set_updated_at on public.employees;
create trigger employees_set_updated_at before update on public.employees
  for each row execute function public.set_updated_at();

-- login_email must equal the Supabase Auth email (checked on insert and when either column changes).
create or replace function public.employees_check_auth_email() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare v_email text;
begin
  select email into v_email from auth.users where id = new.auth_user_id;
  if v_email is null or lower(v_email) <> lower(new.login_email::text) then
    raise exception 'employees.login_email must equal the Supabase Auth email of auth_user_id';
  end if;
  return new;
end $$;

drop trigger if exists employees_check_auth_email on public.employees;
create trigger employees_check_auth_email before insert or update of login_email, auth_user_id on public.employees
  for each row execute function public.employees_check_auth_email();

-- EXACTLY ONE Main Admin can ever exist.
create unique index if not exists employees_single_main_admin
  on public.employees ((true)) where role = 'main_admin';

-- The Main Admin cannot be deleted, demoted, deactivated or revoked.
-- NOTE: transferring the Main Admin role must be a deliberate, atomic SECURITY DEFINER function
-- added in a later phase (it must change both rows in one transaction and write an audit log).
-- Until then this trigger blocks every route to removing the role. A superuser can still disable
-- triggers, which is why the Worker never gets database-owner credentials.
create or replace function public.protect_main_admin() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if old.role = 'main_admin' then
      raise exception 'The Main Admin cannot be deleted' using errcode = 'P0001';
    end if;
    return old;
  end if;
  if old.role = 'main_admin' and (new.role <> 'main_admin' or new.account_status <> 'active') then
    raise exception 'The Main Admin cannot be demoted, deactivated or revoked' using errcode = 'P0001';
  end if;
  return new;
end $$;

drop trigger if exists employees_protect_main_admin on public.employees;
create trigger employees_protect_main_admin before update or delete on public.employees
  for each row execute function public.protect_main_admin();
