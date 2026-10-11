-- 004: append-only audit log.
create table if not exists public.audit_logs (
  id                 bigint generated always as identity primary key,
  created_at         timestamptz not null default now(),
  actor_employee_id  uuid,
  action             text not null,
  entity_type        text,
  entity_id          text,
  ip                 inet,
  user_agent         text,
  old_value          jsonb,
  new_value          jsonb,
  reason             text,
  request_id         text
);
create index if not exists audit_logs_created_at_idx on public.audit_logs (created_at desc);
create index if not exists audit_logs_actor_idx on public.audit_logs (actor_employee_id);

create or replace function public.audit_logs_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'audit_logs is append-only' using errcode = 'P0001';
end $$;

drop trigger if exists audit_logs_no_change on public.audit_logs;
create trigger audit_logs_no_change before update or delete on public.audit_logs
  for each row execute function public.audit_logs_immutable();

drop trigger if exists audit_logs_no_truncate on public.audit_logs;
create trigger audit_logs_no_truncate before truncate on public.audit_logs
  for each statement execute function public.audit_logs_immutable();

revoke update, delete, truncate on public.audit_logs from public, anon, authenticated, service_role;
