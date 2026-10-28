-- 012_employee_columns_and_aadhaar.sql
-- PURPOSE   : 1. Finish the employees table: constraints, uniqueness, sanity checks.
--             2. Protect Aadhaar: encrypted at rest, a separate last-4 column, a keyed
--                duplicate check, masked output by default, and an audited reveal that
--                only the Main Admin can use.
-- DEPENDS ON: 001, 002 (employees), 008 (write_audit, moraya_require_actor, moraya_fail,
--             AADHAAR_REVEALED in the audit catalogue), 011 (employees.phone, and the
--             profile functions that read aadhaar_last4).
-- ROLLBACK  : drop view     public.employees_masked;
--             drop function public.reveal_aadhaar(uuid,uuid,text,text,text);
--             drop function public.set_employee_aadhaar(uuid,text,text);
--             drop function public.aadhaar_blind_index(text,text);
--             drop function public.aadhaar_encrypt(text,text);
--             drop function public.aadhaar_require_key(text);
--             drop function public.aadhaar_normalize(text);
--             drop function public.aadhaar_verhoeff_ok(text);
--             drop function public.aadhaar_checksum_required();
--             drop function public.mask_aadhaar(text);
--             drop index if exists employees_aadhaar_hash_key, employees_sr_no_key,
--                                  employees_employee_id_ci_key;
--             alter table public.employees
--               drop constraint if exists employees_aadhaar_all_or_none,
--               drop constraint if exists employees_aadhaar_last4_format,
--               drop constraint if exists employees_employee_id_trimmed,
--               drop constraint if exists employees_name_len,
--               drop constraint if exists employees_designation_len,
--               drop constraint if exists employees_dob_range,
--               drop constraint if exists employees_joining_after_birth,
--               drop column if exists aadhaar_encrypted, drop column if exists aadhaar_last4,
--               drop column if exists aadhaar_hash, drop column if exists aadhaar_key_version,
--               drop column if exists aadhaar_updated_at;          -- DESTROYS stored Aadhaar
--             grant select on public.employees to service_role;    -- undo the column grants
--
-- COLUMNS THE PROMPT LISTED, AND WHAT ALREADY EXISTS (nothing is added twice)
--   employee_name     -> already employees.name (002). Kept; no duplicate column.
--   designation, date_of_birth, date_of_joining, created_by -> already in 002.
--   sr_no             -> already a GENERATED ALWAYS identity (002). Added here: a unique index.
--   employee_id       -> already UNIQUE (002). Added here: unique ignoring case and a
--                        "no leading or trailing spaces" check, so 'emp-1' and 'EMP-1'
--                        cannot both exist.
--   login_email       -> already UNIQUE citext + lowercase check (002).
--   Added here: length checks on name and designation, a date-of-birth range check and
--   "joining is not before birth" (the frontend already enforces the same rule).
--
-- AADHAAR DESIGN (decision and reasons)
--   Choice: pgcrypto pgp_sym_encrypt (AES-256) with a key the Worker passes on every
--   call. The key is a Cloudflare secret (suggested name AADHAAR_ENC_KEY: 32 random
--   bytes, base64, 44 characters; generate once, keep an offline copy).
--   Why not the alternatives:
--     * Supabase Vault keeps the key INSIDE the database. Anyone who can read the
--       database (a leaked service key, a backup, a misconfigured role) can read the key
--       and the ciphertext together. A per-call key means a database copy alone
--       reveals nothing.
--     * A key stored in a table, setting or this file is exactly what must not exist.
--   Trade-off accepted: the key travels in the RPC request (over TLS) and is visible
--   for the duration of the call in the database session. It is never stored, never put
--   in an error message by this file, and never written to audit. Keep
--   log_statement = none (the Supabase default) and do not enable parameter logging.
--   Lose the key and every stored Aadhaar is unrecoverable (it can be re-entered).
--   Stored per employee:
--     aadhaar_encrypted   bytea   pgp_sym_encrypt(12 digits). A new random salt on every
--                                 write, so equal numbers produce different ciphertext.
--     aadhaar_last4       text    shown in masked form ("XXXX XXXX 1234").
--     aadhaar_hash        bytea   HMAC-SHA256 of the digits, keyed from the same secret
--                                 (a "blind index"). Used only to refuse the same Aadhaar
--                                 on two employees. Without the key it cannot be
--                                 brute-forced even though the number space is small.
--     aadhaar_key_version smallint  1 today. Lets a future key rotation move rows in
--                                 batches (rotation needs old and new key together and
--                                 recomputes the ciphertext AND the hash).
--     aadhaar_updated_at  timestamptz
--   Input rule (aadhaar_normalize): trim; drop ONE leading letter (the sample sheet has
--   "A 123412341234"); drop spaces and hyphens; what is left must be exactly 12 ASCII
--   digits, first digit 2-9, and pass the Verhoeff check digit. This matches the
--   frontend (formSchemas.ts / aadhaar.ts). To accept any 12 digits, redefine
--   aadhaar_checksum_required() to return false (matches ENFORCE_AADHAAR_CHECKSUM).
--   Errors never contain the number that was typed.
--   Reading: the table can be read only through column grants (see section 6): the
--   service role cannot select aadhaar_encrypted or aadhaar_hash directly. Everyone gets
--   the masked value; only reveal_aadhaar returns the full number.
--   A duplicate Aadhaar is refused with MORAYA_CONFLICT. The message does not say
--   whose it is. A person who left and comes back is reactivated, not created again.

-- =====================================================================================
-- 1. employees: sanity constraints and uniqueness
-- =====================================================================================
do $$ begin
  alter table public.employees add constraint employees_employee_id_trimmed
    check (employee_id = btrim(employee_id) and employee_id <> '');
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.employees add constraint employees_name_len
    check (char_length(btrim(name)) between 1 and 100);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.employees add constraint employees_designation_len
    check (designation is null or char_length(btrim(designation)) between 1 and 60);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.employees add constraint employees_dob_range
    check (date_of_birth is null or date_of_birth >= date '1900-01-01');
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.employees add constraint employees_joining_after_birth
    check (date_of_joining is null or date_of_birth is null or date_of_joining >= date_of_birth);
exception when duplicate_object then null; end $$;

create unique index if not exists employees_sr_no_key on public.employees (sr_no);
create unique index if not exists employees_employee_id_ci_key on public.employees (upper(employee_id));

-- =====================================================================================
-- 2. employees: Aadhaar columns
-- =====================================================================================
alter table public.employees
  add column if not exists aadhaar_encrypted   bytea,
  add column if not exists aadhaar_last4       text,
  add column if not exists aadhaar_hash        bytea,
  add column if not exists aadhaar_key_version smallint not null default 1,
  add column if not exists aadhaar_updated_at  timestamptz;

do $$ begin
  alter table public.employees add constraint employees_aadhaar_last4_format
    check (aadhaar_last4 is null or aadhaar_last4 ~ '^[0-9]{4}$');
exception when duplicate_object then null; end $$;

-- All three Aadhaar values exist together or not at all.
do $$ begin
  alter table public.employees add constraint employees_aadhaar_all_or_none
    check ((aadhaar_encrypted is null) = (aadhaar_last4 is null)
       and (aadhaar_encrypted is null) = (aadhaar_hash is null));
exception when duplicate_object then null; end $$;

create unique index if not exists employees_aadhaar_hash_key
  on public.employees (aadhaar_hash) where aadhaar_hash is not null;

-- =====================================================================================
-- 3. Pure helpers (no secrets)
-- =====================================================================================

-- Product rule switch, same meaning as ENFORCE_AADHAAR_CHECKSUM in the frontend.
create or replace function public.aadhaar_checksum_required() returns boolean
language sql
stable
set search_path = public, pg_temp
as $$ select true $$;

-- Verhoeff check (same tables as moraya-frontend/.../aadhaar.ts). True when valid.
create or replace function public.aadhaar_verhoeff_ok(p_digits text) returns boolean
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  d int[] := array[
    [0,1,2,3,4,5,6,7,8,9],
    [1,2,3,4,0,6,7,8,9,5],
    [2,3,4,0,1,7,8,9,5,6],
    [3,4,0,1,2,8,9,5,6,7],
    [4,0,1,2,3,9,5,6,7,8],
    [5,9,8,7,6,0,4,3,2,1],
    [6,5,9,8,7,1,0,4,3,2],
    [7,6,5,9,8,2,1,0,4,3],
    [8,7,6,5,9,3,2,1,0,4],
    [9,8,7,6,5,4,3,2,1,0]];
  p int[] := array[
    [0,1,2,3,4,5,6,7,8,9],
    [1,5,7,6,2,8,3,0,9,4],
    [5,8,0,3,7,9,6,1,4,2],
    [8,9,1,6,0,4,3,5,2,7],
    [9,4,5,3,1,2,6,8,7,0],
    [4,2,8,6,5,7,3,9,0,1],
    [2,7,9,3,8,0,6,4,1,5],
    [7,0,4,6,9,1,3,2,5,8]];
  c int := 0;
  n int;
  i int;
begin
  if p_digits is null or p_digits !~ '^[0-9]{2,}$' then return false; end if;
  n := char_length(p_digits);
  for i in 0 .. n - 1 loop
    c := d[c + 1][ p[(i % 8) + 1][ substr(p_digits, n - i, 1)::int + 1 ] + 1 ];
  end loop;
  return c = 0;
end $$;

-- Any accepted spelling -> exactly 12 digits, or MORAYA_VALIDATION.
-- "A 2345 6789 0124", "2345-6789-0124" and "234567890124" all give the same result.
create or replace function public.aadhaar_normalize(p_input text) returns text
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v text;
begin
  if p_input is null or btrim(p_input) = '' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Aadhaar is required');
  end if;

  v := btrim(p_input);
  v := regexp_replace(v, '^[A-Za-z]\s*', '');      -- one stray leading letter
  v := regexp_replace(v, '[\s-]', '', 'g');        -- spaces and hyphens

  if v !~ '^[2-9][0-9]{11}$' then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Aadhaar must be 12 digits and cannot start with 0 or 1');
  end if;
  if public.aadhaar_checksum_required() and not public.aadhaar_verhoeff_ok(v) then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Aadhaar check digit is wrong');
  end if;
  return v;
end $$;

-- "XXXX XXXX 1234". Accepts the last-4 value or a full number (only the last 4 digits
-- are ever used). Anything with fewer than 4 digits gives null.
create or replace function public.mask_aadhaar(p_value text) returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case
    when char_length(regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g')) < 4 then null
    else 'XXXX XXXX ' || right(regexp_replace(p_value, '[^0-9]', '', 'g'), 4)
  end;
$$;

-- =====================================================================================
-- 4. Key-handling helpers (internal: no client and no service_role access)
--    pgcrypto may live in "extensions" (Supabase) or "public"; both are on the path.
-- =====================================================================================

-- A missing key is a deployment fault, not bad user input, hence INVALID_STATE.
-- The message never includes the key or its length.
create or replace function public.aadhaar_require_key(p_key text) returns void
language plpgsql
set search_path = extensions, public, pg_temp
as $$
begin
  if p_key is null or char_length(p_key) < 32 then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'Aadhaar encryption key is not configured');
  end if;
end $$;

create or replace function public.aadhaar_encrypt(p_digits text, p_key text) returns bytea
language plpgsql
set search_path = extensions, public, pg_temp
as $$
begin
  perform public.aadhaar_require_key(p_key);
  return pgp_sym_encrypt(p_digits, p_key, 'cipher-algo=aes256, compress-algo=0, s2k-digest-algo=sha256');
end $$;

-- HMAC-SHA256(digits) under a key derived from the secret. For duplicate detection only.
create or replace function public.aadhaar_blind_index(p_digits text, p_key text) returns bytea
language plpgsql
set search_path = extensions, public, pg_temp
as $$
begin
  perform public.aadhaar_require_key(p_key);
  return hmac(convert_to(p_digits, 'UTF8'),
              hmac(convert_to('moraya-aadhaar-blind-index-v1', 'UTF8'), convert_to(p_key, 'UTF8'), 'sha256'),
              'sha256');
end $$;

-- =====================================================================================
-- 5. set_employee_aadhaar : INTERNAL, called by the 013 employee functions
--    (create_employee, update_employee) inside their own transaction, after they have
--    checked the caller's permission. Not callable from the Worker or any client.
--    Normalises, encrypts, stores last 4, blind index, key version and timestamp.
--    Does not write audit (the caller writes USER_CREATED or USER_AADHAAR_CHANGED and
--    must not put the number in it). Returns the last 4 digits.
--    Errors: MORAYA_VALIDATION (bad number), MORAYA_INVALID_STATE (no key),
--            MORAYA_NOT_FOUND (no such employee), MORAYA_CONFLICT (already registered)
-- =====================================================================================
create or replace function public.set_employee_aadhaar(
  p_employee_id uuid,
  p_aadhaar     text,
  p_key         text
) returns text
language plpgsql
security definer
set search_path = extensions, public, pg_temp
as $$
declare
  v_digits text;
  v_last4  text;
begin
  v_digits := public.aadhaar_normalize(p_aadhaar);
  perform public.aadhaar_require_key(p_key);
  v_last4 := right(v_digits, 4);

  begin
    update public.employees e set
      aadhaar_encrypted   = public.aadhaar_encrypt(v_digits, p_key),
      aadhaar_last4       = v_last4,
      aadhaar_hash        = public.aadhaar_blind_index(v_digits, p_key),
      aadhaar_key_version = 1,
      aadhaar_updated_at  = now()
    where e.id = p_employee_id;
  exception when unique_violation then
    perform public.moraya_fail('MORAYA_CONFLICT', 'This Aadhaar is already registered');
  end;

  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Employee not found');
  end if;
  return v_last4;
end $$;

-- =====================================================================================
-- 6. reveal_aadhaar : main_admin only, reason required, always audited
--    Returns {employee_id (the text code), name, aadhaar (12 digits),
--             aadhaar_formatted ("1234 5678 9012")}.
--    The Worker must send it with Cache-Control: no-store and must never log or store it.
--    Audit AADHAAR_REVEALED holds the reason and the MASKED number only. A refused or
--    failed reveal rolls back with the call, so no AADHAAR_REVEALED row exists unless
--    the number was actually returned; the Worker records refusals as ACCESS_DENIED.
--    Errors: MORAYA_FORBIDDEN (not an active main_admin), MORAYA_VALIDATION (reason not
--            5 to 500 characters), MORAYA_INVALID_STATE (no key, wrong key, damaged
--            data), MORAYA_NOT_FOUND (no such employee, or none on file)
-- =====================================================================================
create or replace function public.reveal_aadhaar(
  p_actor_auth_id uuid,
  p_employee_id   uuid,
  p_reason        text,
  p_key           text,
  p_request_id    text default null
) returns jsonb
language plpgsql
security definer
set search_path = extensions, public, pg_temp
as $$
declare
  v_actor  public.employees;
  v_emp    public.employees;
  v_reason text;
  v_plain  text;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, true, null);

  v_reason := btrim(coalesce(p_reason, ''));
  if char_length(v_reason) < 5 or char_length(v_reason) > 500 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'A reason of 5 to 500 characters is required');
  end if;

  perform public.aadhaar_require_key(p_key);

  select * into v_emp from public.employees e where e.id = p_employee_id;
  if not found then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'Employee not found');
  end if;
  if v_emp.aadhaar_encrypted is null then
    perform public.moraya_fail('MORAYA_NOT_FOUND', 'No Aadhaar on file');
  end if;

  begin
    v_plain := pgp_sym_decrypt(v_emp.aadhaar_encrypted, p_key);
  exception when others then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'Could not decrypt Aadhaar');
  end;

  -- Integrity: what came out must be a 12-digit number matching the stored last 4.
  if v_plain is null or v_plain !~ '^[0-9]{12}$' or right(v_plain, 4) <> v_emp.aadhaar_last4 then
    perform public.moraya_fail('MORAYA_INVALID_STATE', 'Stored Aadhaar is damaged');
  end if;

  perform public.write_audit(
    v_actor.id, 'AADHAAR_REVEALED', 'employee', v_emp.id::text,
    null,
    jsonb_build_object('employee_code', v_emp.employee_id, 'aadhaar_masked', public.mask_aadhaar(v_emp.aadhaar_last4)),
    v_reason, p_request_id,
    'Revealed Aadhaar of ' || v_emp.employee_id || ' (' || v_emp.name || ')'
  );

  return jsonb_build_object(
    'employee_id',       v_emp.employee_id,
    'name',              v_emp.name,
    'aadhaar',           v_plain,
    'aadhaar_formatted', substr(v_plain, 1, 4) || ' ' || substr(v_plain, 5, 4) || ' ' || substr(v_plain, 9, 4)
  );
end $$;

-- =====================================================================================
-- 7. Masked view (the default way to read employees from SQL)
--    Never exposes aadhaar_encrypted or aadhaar_hash. security_invoker: the caller's own
--    column grants apply, so it cannot widen access.
-- =====================================================================================
create or replace view public.employees_masked
with (security_invoker = true) as
select e.id, e.sr_no, e.employee_id, e.name, e.login_email, e.role, e.account_status,
       e.designation, e.date_of_birth, e.date_of_joining, e.phone,
       public.mask_aadhaar(e.aadhaar_last4) as aadhaar_masked,
       e.created_by, e.created_at, e.updated_at
  from public.employees e;

-- =====================================================================================
-- 8. Grants
-- =====================================================================================

-- 8a. The service role (the Worker's key) may read every employees column EXCEPT the
--     encrypted Aadhaar and its blind index. Fail-closed side effect: a column added to
--     employees later is not selectable by service_role until it is granted here or in
--     the migration that adds it. SECURITY DEFINER functions are not affected.
revoke select on public.employees from service_role;
grant select (id, auth_user_id, sr_no, employee_id, name, login_email, role, account_status,
              designation, date_of_birth, date_of_joining, created_by, created_at, updated_at,
              phone, aadhaar_last4, aadhaar_key_version, aadhaar_updated_at)
  on public.employees to service_role;

-- 8b. Functions. Internal ones (key handling, set_employee_aadhaar, helpers) have no
--     grant at all; only the two below are callable by the service role.
revoke all on function public.aadhaar_checksum_required()                    from public, anon, authenticated, service_role;
revoke all on function public.aadhaar_verhoeff_ok(text)                      from public, anon, authenticated, service_role;
revoke all on function public.aadhaar_normalize(text)                        from public, anon, authenticated, service_role;
revoke all on function public.aadhaar_require_key(text)                      from public, anon, authenticated, service_role;
revoke all on function public.aadhaar_encrypt(text, text)                    from public, anon, authenticated, service_role;
revoke all on function public.aadhaar_blind_index(text, text)                from public, anon, authenticated, service_role;
revoke all on function public.set_employee_aadhaar(uuid, text, text)         from public, anon, authenticated, service_role;
revoke all on function public.mask_aadhaar(text)                             from public, anon, authenticated;
revoke all on function public.reveal_aadhaar(uuid, uuid, text, text, text)   from public, anon, authenticated;

grant execute on function public.mask_aadhaar(text)                           to service_role;
grant execute on function public.reveal_aadhaar(uuid, uuid, text, text, text) to service_role;

-- 8c. The view
revoke all on public.employees_masked from public, anon, authenticated;
grant select on public.employees_masked to service_role;