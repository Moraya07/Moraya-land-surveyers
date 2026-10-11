-- 007: RLS (default deny) and grants. RLS is defense in depth; the Worker is the primary control.
alter table public.employees            enable row level security;
alter table public.sub_admin_permissions enable row level security;
alter table public.audit_logs           enable row level security;
alter table public.auth_login_attempts  enable row level security;

drop policy if exists employees_select_own on public.employees;
create policy employees_select_own on public.employees
  for select to authenticated using (auth_user_id = (select auth.uid()));

drop policy if exists sub_admin_permissions_select_own on public.sub_admin_permissions;
create policy sub_admin_permissions_select_own on public.sub_admin_permissions
  for select to authenticated using (
    employee_id in (select id from public.employees where auth_user_id = (select auth.uid())));

-- audit_logs and auth_login_attempts: no policies for anon/authenticated (service role only).

revoke all on public.employees, public.sub_admin_permissions, public.audit_logs, public.auth_login_attempts
  from anon, authenticated;
grant select on public.employees, public.sub_admin_permissions to authenticated;

-- Functions: callable by service_role only.
revoke all on function public.get_auth_profile(uuid) from public, anon, authenticated;
revoke all on function public.login_profile_and_audit(uuid, inet, text, text, text, text) from public, anon, authenticated;
revoke all on function public.auth_throttle_hit(text[], int[], int, text, inet, text, text, text) from public, anon, authenticated;
grant execute on function public.get_auth_profile(uuid) to service_role;
grant execute on function public.login_profile_and_audit(uuid, inet, text, text, text, text) to service_role;
grant execute on function public.auth_throttle_hit(text[], int[], int, text, inet, text, text, text) to service_role;
