-- 001: extensions, enums, shared trigger function. Safe to re-run.
create extension if not exists citext;
create extension if not exists pgcrypto;

do $$ begin
  create type public.user_role as enum ('main_admin', 'sub_admin', 'worker');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.account_status as enum ('active', 'inactive', 'revoked');
exception when duplicate_object then null; end $$;

create or replace function public.set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
