-- 005: login/forgot-password throttling in Postgres (see README for why not the Workers binding).
create table if not exists public.auth_login_attempts (
  key          text primary key,
  window_start timestamptz not null,
  attempts     int not null
);
create index if not exists auth_login_attempts_window_idx on public.auth_login_attempts (window_start);

-- One atomic call: increments every key (fixed window), reports whether any is over its limit,
-- and writes ONE audit row the first time a key crosses its limit in a window (no log flooding).
create or replace function public.auth_throttle_hit(
  p_keys text[], p_limits int[], p_window_seconds int,
  p_audit_action text default null, p_ip inet default null, p_user_agent text default null,
  p_request_id text default null, p_email_masked text default null
) returns table (blocked boolean, retry_after_seconds int)
language plpgsql security definer set search_path = public as $$
declare
  i int; v_attempts int; v_start timestamptz; v_retry int;
  v_blocked boolean := false; v_max_retry int := 0; v_first boolean := false;
begin
  if cardinality(p_keys) <> cardinality(p_limits) then
    raise exception 'keys and limits must have the same length';
  end if;

  for i in 1 .. cardinality(p_keys) loop
    insert into public.auth_login_attempts as a (key, window_start, attempts)
    values (p_keys[i], now(), 1)
    on conflict (key) do update set
      attempts = case when a.window_start <= now() - make_interval(secs => p_window_seconds)
                      then 1 else a.attempts + 1 end,
      window_start = case when a.window_start <= now() - make_interval(secs => p_window_seconds)
                          then now() else a.window_start end
    returning a.attempts, a.window_start into v_attempts, v_start;

    if v_attempts > p_limits[i] then
      v_blocked := true;
      v_retry := greatest(1, ceil(extract(epoch from (v_start + make_interval(secs => p_window_seconds) - now())))::int);
      v_max_retry := greatest(v_max_retry, v_retry);
      if v_attempts = p_limits[i] + 1 then v_first := true; end if;
    end if;
  end loop;

  if v_first and p_audit_action is not null then
    insert into public.audit_logs (action, ip, user_agent, request_id, new_value)
    values (p_audit_action, p_ip, p_user_agent, p_request_id, jsonb_build_object('email_masked', p_email_masked));
  end if;

  -- Opportunistic cleanup of long-dead rows (about 1% of calls).
  if random() < 0.01 then
    delete from public.auth_login_attempts where window_start < now() - interval '1 day';
  end if;

  return query select v_blocked, v_max_retry;
end $$;
