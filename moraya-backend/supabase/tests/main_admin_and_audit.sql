-- Manual SQL test: run in the Supabase SQL editor (as postgres). Everything is rolled back.
-- Each block prints NOTICE 'PASS ...' or raises on failure.
begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'main@test.local'),
  ('22222222-2222-2222-2222-222222222222', 'second@test.local');

insert into public.employees (auth_user_id, employee_id, name, login_email, role)
values ('11111111-1111-1111-1111-111111111111', 'T-1', 'Main', 'main@test.local', 'main_admin');

do $$ begin  -- second main admin
  begin
    insert into public.employees (auth_user_id, employee_id, name, login_email, role)
    values ('22222222-2222-2222-2222-222222222222', 'T-2', 'Second', 'second@test.local', 'main_admin');
    raise exception 'FAIL: second main admin was inserted';
  exception when unique_violation then raise notice 'PASS second main admin rejected'; end;
end $$;

do $$ begin  -- delete
  begin delete from public.employees where employee_id = 'T-1'; raise exception 'FAIL: delete allowed';
  exception when sqlstate 'P0001' then raise notice 'PASS delete rejected'; end;
end $$;

do $$ begin  -- demote
  begin update public.employees set role = 'worker' where employee_id = 'T-1'; raise exception 'FAIL: demote allowed';
  exception when sqlstate 'P0001' then raise notice 'PASS demote rejected'; end;
end $$;

do $$ begin  -- deactivate
  begin update public.employees set account_status = 'inactive' where employee_id = 'T-1'; raise exception 'FAIL: deactivate allowed';
  exception when sqlstate 'P0001' then raise notice 'PASS deactivate rejected'; end;
end $$;

do $$ begin  -- revoke
  begin update public.employees set account_status = 'revoked' where employee_id = 'T-1'; raise exception 'FAIL: revoke allowed';
  exception when sqlstate 'P0001' then raise notice 'PASS revoke rejected'; end;
end $$;

do $$ begin  -- permissions only for sub_admin
  begin
    insert into public.sub_admin_permissions (employee_id, permission)
    select id, 'export' from public.employees where employee_id = 'T-1';
    raise exception 'FAIL: permission granted to non-sub_admin';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS permission on non-sub_admin rejected';
  end;
end $$;

insert into public.audit_logs (action) values ('TEST');

do $$ begin
  begin update public.audit_logs set action = 'X' where action = 'TEST'; raise exception 'FAIL: audit update allowed';
  exception when sqlstate 'P0001' then raise notice 'PASS audit update rejected'; end;
  begin delete from public.audit_logs where action = 'TEST'; raise exception 'FAIL: audit delete allowed';
  exception when sqlstate 'P0001' then raise notice 'PASS audit delete rejected'; end;
  begin truncate public.audit_logs; raise exception 'FAIL: audit truncate allowed';
  exception when sqlstate 'P0001' then raise notice 'PASS audit truncate rejected'; end;
end $$;

rollback;
