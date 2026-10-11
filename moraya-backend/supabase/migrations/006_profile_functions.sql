-- 006: profile lookup RPCs (service_role only).
create or replace function public.get_auth_profile(p_auth_user_id uuid)
returns table (
  id uuid, auth_user_id uuid, employee_id text, name text, login_email text,
  role public.user_role, account_status public.account_status, permissions text[]
)
language sql stable security definer set search_path = public as $$
  select e.id, e.auth_user_id, e.employee_id, e.name, e.login_email::text, e.role, e.account_status,
         coalesce((select array_agg(p.permission order by p.permission)
                   from public.sub_admin_permissions p where p.employee_id = e.id), '{}'::text[])
  from public.employees e
  where e.auth_user_id = p_auth_user_id;
$$;

-- Login-only wrapper: profile lookup + audit row (+ throttle reset on success) in ONE round trip,
-- which keeps a successful login at 3 subrequests (throttle, password grant, this).
-- Returns the profile as jsonb, or null when there is no employee row.
create or replace function public.login_profile_and_audit(
  p_auth_user_id uuid, p_ip inet, p_user_agent text, p_request_id text,
  p_email_masked text, p_reset_key text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v_action text; v_reason text;
begin
  select * into r from public.get_auth_profile(p_auth_user_id);

  if not found then
    insert into public.audit_logs (action, entity_type, entity_id, ip, user_agent, reason, request_id, new_value)
    values ('LOGIN_FAILED', 'auth_user', p_auth_user_id::text, p_ip, p_user_agent,
            'NO_EMPLOYEE_RECORD', p_request_id, jsonb_build_object('email_masked', p_email_masked));
    return null;
  end if;

  if r.account_status = 'active' then
    v_action := 'LOGIN_SUCCESS'; v_reason := null;
    delete from public.auth_login_attempts where key = p_reset_key;
  else
    v_action := 'LOGIN_FAILED'; v_reason := 'ACCOUNT_' || upper(r.account_status::text);
  end if;

  insert into public.audit_logs (actor_employee_id, action, entity_type, entity_id, ip, user_agent, reason, request_id, new_value)
  values (r.id, v_action, 'employee', r.id::text, p_ip, p_user_agent, v_reason, p_request_id,
          jsonb_build_object('email_masked', p_email_masked));

  return to_jsonb(r);
end $$;
