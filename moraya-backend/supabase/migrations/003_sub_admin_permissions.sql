-- 003: permissions granted to sub admins. Main admin has all implicitly (no rows).
create table if not exists public.sub_admin_permissions (
  employee_id uuid not null references public.employees(id) on delete cascade,
  permission  text not null,
  created_at  timestamptz not null default now(),
  primary key (employee_id, permission),
  constraint sub_admin_permissions_valid check (permission in (
    'employee_management','site_management','verification','income_management',
    'salary_management','report_view','export'))
);

create or replace function public.sub_admin_permissions_check_role() returns trigger
language plpgsql as $$
declare v_role public.user_role;
begin
  select role into v_role from public.employees where id = new.employee_id;
  if v_role is distinct from 'sub_admin' then
    raise exception 'Permissions can only be granted to sub_admin employees';
  end if;
  return new;
end $$;

drop trigger if exists sub_admin_permissions_check_role on public.sub_admin_permissions;
create trigger sub_admin_permissions_check_role before insert or update on public.sub_admin_permissions
  for each row execute function public.sub_admin_permissions_check_role();

-- If someone stops being a sub admin, their permission rows go with it.
create or replace function public.employees_drop_permissions_on_role_change() returns trigger
language plpgsql as $$
begin
  if new.role <> 'sub_admin' then
    delete from public.sub_admin_permissions where employee_id = new.id;
  end if;
  return null;
end $$;

drop trigger if exists employees_drop_permissions on public.employees;
create trigger employees_drop_permissions after update of role on public.employees
  for each row execute function public.employees_drop_permissions_on_role_change();
