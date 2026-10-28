-- Test for 012_employee_columns_and_aadhaar.sql. Run in the Supabase SQL editor (as postgres).
-- Needs 008, 009, 010, 011 and 012 applied. Everything is rolled back.
-- Expect only NOTICE lines starting with PASS; any FAIL stops the script with an error.
-- Fake data only. The "key" below is a throw-away test value, not a real secret.
--
-- Valid fake Aadhaar-style numbers (they pass the Verhoeff check):
--   234567890124   345678901238   456789012341   987654321096   271828182847
begin;

create function pg_temp.expect(p_name text, p_sql text, p_message text default null, p_sqlstate text default null)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if (p_message is null or sqlerrm = p_message) and (p_sqlstate is null or sqlstate = p_sqlstate) then
      raise notice 'PASS %', p_name;
      return;
    end if;
    raise exception 'FAIL %: got % / %', p_name, sqlstate, sqlerrm;
  end;
  raise exception 'FAIL %: no error raised', p_name;
end $$;

create function pg_temp.assert_true(p_name text, p_ok boolean) returns void language plpgsql as $$
begin
  if p_ok then raise notice 'PASS %', p_name;
  else raise exception 'FAIL %', p_name; end if;
end $$;

insert into auth.users (id, email) values
  ('ffffffff-0000-0000-0000-000000000001', 'm@test.local'),
  ('ffffffff-0000-0000-0000-000000000002', 'sub@test.local'),
  ('ffffffff-0000-0000-0000-000000000003', 'w1@test.local'),
  ('ffffffff-0000-0000-0000-000000000004', 'w2@test.local'),
  ('ffffffff-0000-0000-0000-000000000005', 'off@test.local'),
  ('ffffffff-0000-0000-0000-000000000006', 'dup@test.local');

insert into public.employees
  (auth_user_id, employee_id, name, login_email, role, account_status, date_of_birth, date_of_joining) values
  ('ffffffff-0000-0000-0000-000000000001', 'M-1',   'Main',     'm@test.local',   'main_admin', 'active',   null, null),
  ('ffffffff-0000-0000-0000-000000000002', 'SUB-1', 'Sub',      'sub@test.local', 'sub_admin',  'active',   null, null),
  ('ffffffff-0000-0000-0000-000000000003', 'W-1',   'Worker 1', 'w1@test.local',  'worker',     'active',   '1995-05-05', '2022-01-10'),
  ('ffffffff-0000-0000-0000-000000000004', 'W-2',   'Worker 2', 'w2@test.local',  'worker',     'active',   null, null),
  ('ffffffff-0000-0000-0000-000000000005', 'OFF-1', 'Inactive', 'off@test.local', 'worker',     'inactive', null, null);

insert into public.sub_admin_permissions (employee_id, permission)
select id, 'employee_management' from public.employees where employee_id = 'SUB-1';

-- =====================================================================================
-- 1. Employee columns and constraints
-- =====================================================================================
select pg_temp.expect('employee_id is unique ignoring case',
  $q$ insert into public.employees (auth_user_id, employee_id, name, login_email)
      values ('ffffffff-0000-0000-0000-000000000006', 'w-1', 'Dup', 'dup@test.local') $q$, null, '23505');
select pg_temp.expect('employee_id with spaces rejected',
  $q$ update public.employees set employee_id = ' W-9 ' where employee_id = 'W-2' $q$, null, '23514');
select pg_temp.expect('blank name rejected',
  $q$ update public.employees set name = '   ' where employee_id = 'W-2' $q$, null, '23514');
select pg_temp.expect('joining before birth rejected',
  $q$ update public.employees set date_of_joining = '1990-01-01' where employee_id = 'W-1' $q$, null, '23514');
select pg_temp.expect('birth date before 1900 rejected',
  $q$ update public.employees set date_of_birth = '1850-01-01' where employee_id = 'W-2' $q$, null, '23514');
select pg_temp.expect('sr_no cannot be set by hand',
  $q$ update public.employees set sr_no = 999 where employee_id = 'W-2' $q$, null, '428C9');
select pg_temp.assert_true('sr_no values are unique and filled',
  (select count(*) = count(distinct sr_no) and bool_and(sr_no is not null) from public.employees));

-- =====================================================================================
-- 2. Normalisation and validation
-- =====================================================================================
select pg_temp.assert_true('plain 12 digits accepted',
  public.aadhaar_normalize('234567890124') = '234567890124');
select pg_temp.assert_true('spaces accepted',
  public.aadhaar_normalize(' 2345 6789 0124 ') = '234567890124');
select pg_temp.assert_true('hyphens accepted',
  public.aadhaar_normalize('2345-6789-0124') = '234567890124');
select pg_temp.assert_true('stray single letter prefix removed (sample sheet style)',
  public.aadhaar_normalize('A 234567890124') = '234567890124'
  and public.aadhaar_normalize('a234567890124') = '234567890124');

select pg_temp.expect('null rejected',        $q$ select public.aadhaar_normalize(null) $q$,            'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('blank rejected',       $q$ select public.aadhaar_normalize('   ') $q$,           'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('11 digits rejected',   $q$ select public.aadhaar_normalize('23456789012') $q$,    'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('13 digits rejected',   $q$ select public.aadhaar_normalize('2345678901245') $q$,  'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('letter inside rejected', $q$ select public.aadhaar_normalize('2345A6789012') $q$, 'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('two letter prefix rejected', $q$ select public.aadhaar_normalize('AB 234567890124') $q$, 'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('first digit 0 rejected', $q$ select public.aadhaar_normalize('034567890124') $q$, 'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('first digit 1 rejected', $q$ select public.aadhaar_normalize('134567890124') $q$, 'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('wrong check digit rejected', $q$ select public.aadhaar_normalize('234567890125') $q$, 'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('dots rejected',        $q$ select public.aadhaar_normalize('2345.6789.0124') $q$, 'MORAYA_VALIDATION', 'P0001');

-- the error never repeats what was typed
do $$
declare v_msg text; v_detail text;
begin
  begin
    perform public.aadhaar_normalize('234567890125');
  exception when others then
    get stacked diagnostics v_detail = pg_exception_detail;
    v_msg := sqlerrm;
  end;
  perform pg_temp.assert_true('validation error does not echo the number',
    coalesce(v_msg, '') !~ '234567890125' and coalesce(v_detail, '') !~ '234567890125');
end $$;

select pg_temp.assert_true('verhoeff true for the five fake numbers',
  public.aadhaar_verhoeff_ok('234567890124') and public.aadhaar_verhoeff_ok('345678901238')
  and public.aadhaar_verhoeff_ok('456789012341') and public.aadhaar_verhoeff_ok('987654321096')
  and public.aadhaar_verhoeff_ok('271828182847'));
select pg_temp.assert_true('verhoeff false when any single digit is changed',
  not public.aadhaar_verhoeff_ok('234567890123') and not public.aadhaar_verhoeff_ok('334567890124'));

-- =====================================================================================
-- 3. Masking
-- =====================================================================================
select pg_temp.assert_true('mask_aadhaar from last4',      public.mask_aadhaar('4321') = 'XXXX XXXX 4321');
select pg_temp.assert_true('mask_aadhaar from full number', public.mask_aadhaar('234567890124') = 'XXXX XXXX 0124');
select pg_temp.assert_true('mask_aadhaar shows nothing else',
  public.mask_aadhaar('234567890124') !~ '2345|6789');
select pg_temp.assert_true('mask_aadhaar null and junk give null',
  public.mask_aadhaar(null) is null and public.mask_aadhaar('ab') is null and public.mask_aadhaar('123') is null);

-- =====================================================================================
-- 4. Storing (set_employee_aadhaar)
-- =====================================================================================
select pg_temp.expect('missing key refused',
  $q$ select public.set_employee_aadhaar((select id from public.employees where employee_id = 'W-1'), '234567890124', null) $q$,
  'MORAYA_INVALID_STATE', 'P0001');
select pg_temp.expect('short key refused',
  $q$ select public.set_employee_aadhaar((select id from public.employees where employee_id = 'W-1'), '234567890124', 'short') $q$,
  'MORAYA_INVALID_STATE', 'P0001');
select pg_temp.expect('bad number refused before anything is stored',
  $q$ select public.set_employee_aadhaar((select id from public.employees where employee_id = 'W-1'), '234567890125',
        'test-key-0123456789-0123456789-0123456789') $q$, 'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('unknown employee refused',
  $q$ select public.set_employee_aadhaar('00000000-0000-0000-0000-00000000dead', '234567890124',
        'test-key-0123456789-0123456789-0123456789') $q$, 'MORAYA_NOT_FOUND', 'P0001');

do $$
declare
  k  constant text := 'test-key-0123456789-0123456789-0123456789';
  v_w1 uuid := (select id from public.employees where employee_id = 'W-1');
  v_w2 uuid := (select id from public.employees where employee_id = 'W-2');
  v_last4 text; e public.employees; c1 bytea;
begin
  v_last4 := public.set_employee_aadhaar(v_w1, 'A 2345 6789 0124', k);
  perform pg_temp.assert_true('stored; last 4 returned', v_last4 = '0124');

  select * into e from public.employees where id = v_w1;
  perform pg_temp.assert_true('last4, hash, key version, timestamp filled',
    e.aadhaar_last4 = '0124' and length(e.aadhaar_hash) = 32 and e.aadhaar_key_version = 1
    and e.aadhaar_updated_at is not null and e.aadhaar_encrypted is not null);
  perform pg_temp.assert_true('ciphertext does not contain the number',
    position('234567890124'::bytea in e.aadhaar_encrypted) = 0);
  perform pg_temp.assert_true('hash does not contain the number',
    encode(e.aadhaar_hash, 'hex') !~ '234567890124');

  -- same number again for the same employee: allowed, new random ciphertext
  c1 := e.aadhaar_encrypted;
  perform public.set_employee_aadhaar(v_w1, '234567890124', k);
  select * into e from public.employees where id = v_w1;
  perform pg_temp.assert_true('re-saving same number works, ciphertext differs (random salt)',
    e.aadhaar_encrypted <> c1 and e.aadhaar_last4 = '0124');

  begin
    perform public.set_employee_aadhaar(v_w2, '234567890124', k);
    raise exception 'FAIL duplicate Aadhaar on another employee: no error raised';
  exception when others then
    perform pg_temp.assert_true('duplicate Aadhaar on another employee refused (MORAYA_CONFLICT)',
      sqlerrm = 'MORAYA_CONFLICT' and sqlstate = 'P0001');
    perform pg_temp.assert_true('conflict message does not name the other employee',
      sqlerrm not like '%W-1%');
  end;

  perform public.set_employee_aadhaar(v_w1, '271828182847', k);
  select * into e from public.employees where id = v_w1;
  perform pg_temp.assert_true('changing the number updates last 4', e.aadhaar_last4 = '2847');
  perform public.set_employee_aadhaar(v_w2, '234567890124', k);
  perform pg_temp.assert_true('old number is free again once replaced', true);
end $$;

-- table-level protection of the three-columns-together rule
select pg_temp.expect('last4 alone cannot be set',
  $q$ update public.employees set aadhaar_last4 = '1111' where employee_id = 'SUB-1' $q$, null, '23514');
select pg_temp.expect('last4 must be 4 digits',
  $q$ update public.employees set aadhaar_last4 = 'abcd' where employee_id = 'W-1' $q$, null, '23514');

-- =====================================================================================
-- 5. Masked reads
-- =====================================================================================
do $$
declare v jsonb; m record;
begin
  select * into m from public.employees_masked where employee_id = 'W-1';
  perform pg_temp.assert_true('employees_masked shows masked Aadhaar only',
    m.aadhaar_masked = 'XXXX XXXX 2847');
  perform pg_temp.assert_true('employees_masked has no encrypted or hash column',
    not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'employees_masked'
                   and (column_name like 'aadhaar_encrypted' or column_name like 'aadhaar_hash'
                        or column_name = 'aadhaar_last4')));

  v := public.get_own_profile('ffffffff-0000-0000-0000-000000000003');
  perform pg_temp.assert_true('011 profile shows masked Aadhaar now that 012 exists',
    v ->> 'aadhaar_masked' = 'XXXX XXXX 2847');
  perform pg_temp.assert_true('011 profile never holds the full number',
    v::text !~ '[0-9]{12}');
end $$;

-- =====================================================================================
-- 6. reveal_aadhaar
-- =====================================================================================
select pg_temp.expect('sub admin cannot reveal (even with employee_management)',
  $q$ select public.reveal_aadhaar('ffffffff-0000-0000-0000-000000000002',
        (select id from public.employees where employee_id = 'W-1'), 'checking records',
        'test-key-0123456789-0123456789-0123456789') $q$, 'MORAYA_FORBIDDEN', 'P0001');
select pg_temp.expect('worker cannot reveal',
  $q$ select public.reveal_aadhaar('ffffffff-0000-0000-0000-000000000003',
        (select id from public.employees where employee_id = 'W-1'), 'checking records',
        'test-key-0123456789-0123456789-0123456789') $q$, 'MORAYA_FORBIDDEN', 'P0001');
select pg_temp.expect('inactive user cannot reveal',
  $q$ select public.reveal_aadhaar('ffffffff-0000-0000-0000-000000000005',
        (select id from public.employees where employee_id = 'W-1'), 'checking records',
        'test-key-0123456789-0123456789-0123456789') $q$, 'MORAYA_FORBIDDEN', 'P0001');
select pg_temp.expect('unknown caller cannot reveal',
  $q$ select public.reveal_aadhaar('ffffffff-0000-0000-0000-0000000000aa',
        (select id from public.employees where employee_id = 'W-1'), 'checking records',
        'test-key-0123456789-0123456789-0123456789') $q$, 'MORAYA_FORBIDDEN', 'P0001');

select pg_temp.expect('reason required (null)',
  $q$ select public.reveal_aadhaar('ffffffff-0000-0000-0000-000000000001',
        (select id from public.employees where employee_id = 'W-1'), null,
        'test-key-0123456789-0123456789-0123456789') $q$, 'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('reason too short',
  $q$ select public.reveal_aadhaar('ffffffff-0000-0000-0000-000000000001',
        (select id from public.employees where employee_id = 'W-1'), 'ok',
        'test-key-0123456789-0123456789-0123456789') $q$, 'MORAYA_VALIDATION', 'P0001');
select pg_temp.expect('missing key',
  $q$ select public.reveal_aadhaar('ffffffff-0000-0000-0000-000000000001',
        (select id from public.employees where employee_id = 'W-1'), 'checking records', null) $q$,
  'MORAYA_INVALID_STATE', 'P0001');
select pg_temp.expect('wrong key',
  $q$ select public.reveal_aadhaar('ffffffff-0000-0000-0000-000000000001',
        (select id from public.employees where employee_id = 'W-1'), 'checking records',
        'another-key-9876543210-9876543210-9876543210') $q$, 'MORAYA_INVALID_STATE', 'P0001');
select pg_temp.expect('employee with no Aadhaar on file',
  $q$ select public.reveal_aadhaar('ffffffff-0000-0000-0000-000000000001',
        (select id from public.employees where employee_id = 'SUB-1'), 'checking records',
        'test-key-0123456789-0123456789-0123456789') $q$, 'MORAYA_NOT_FOUND', 'P0001');
select pg_temp.expect('unknown employee',
  $q$ select public.reveal_aadhaar('ffffffff-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-00000000dead', 'checking records',
        'test-key-0123456789-0123456789-0123456789') $q$, 'MORAYA_NOT_FOUND', 'P0001');

select pg_temp.assert_true('no reveal was audited by any refused or failed call',
  (select count(*) from public.audit_logs where action = 'AADHAAR_REVEALED') = 0);

do $$
declare v jsonb; a record;
begin
  v := public.reveal_aadhaar('ffffffff-0000-0000-0000-000000000001',
         (select id from public.employees where employee_id = 'W-1'),
         '  Verifying documents for bank  ',
         'test-key-0123456789-0123456789-0123456789', 'req-reveal-1');
  perform pg_temp.assert_true('main admin gets the full number',
    v ->> 'aadhaar' = '271828182847' and v ->> 'aadhaar_formatted' = '2718 2818 2847'
    and v ->> 'employee_id' = 'W-1' and v ->> 'name' = 'Worker 1');

  select * into a from public.audit_logs where action = 'AADHAAR_REVEALED' and request_id = 'req-reveal-1';
  perform pg_temp.assert_true('reveal is audited with actor, target and trimmed reason',
    a.actor_employee_id = (select id from public.employees where employee_id = 'M-1')
    and a.entity_type = 'employee' and a.entity_id = (select id::text from public.employees where employee_id = 'W-1')
    and a.reason = 'Verifying documents for bank');
  perform pg_temp.assert_true('audit row holds only the masked number',
    a.new_value ->> 'aadhaar_masked' = 'XXXX XXXX 2847'
    and coalesce(a.new_value::text, '') !~ '[0-9]{12}'
    and coalesce(a.summary, '') !~ '[0-9]{12}' and coalesce(a.reason, '') !~ '[0-9]{12}'
    and coalesce(a.old_value::text, '') !~ '[0-9]{12}');
  perform pg_temp.assert_true('audit row never contains the key',
    a::text not like '%test-key%');
end $$;

-- =====================================================================================
-- 7. Keys never show up in errors
-- =====================================================================================
do $$
declare v_msg text; v_detail text; v_ctx text;
begin
  begin
    perform public.reveal_aadhaar('ffffffff-0000-0000-0000-000000000001',
      (select id from public.employees where employee_id = 'W-1'), 'checking records',
      'another-key-9876543210-9876543210-9876543210');
  exception when others then
    get stacked diagnostics v_detail = pg_exception_detail, v_ctx = pg_exception_context;
    v_msg := sqlerrm;
  end;
  perform pg_temp.assert_true('wrong-key error does not contain the key',
    coalesce(v_msg, '') || coalesce(v_detail, '') || coalesce(v_ctx, '') not like '%another-key%');
end $$;

-- =====================================================================================
-- 8. Grants
-- =====================================================================================
select pg_temp.assert_true('anon and authenticated cannot execute any 012 function',
  not exists (
    select 1
      from unnest(array[
        'public.aadhaar_checksum_required()', 'public.aadhaar_verhoeff_ok(text)',
        'public.aadhaar_normalize(text)', 'public.aadhaar_require_key(text)',
        'public.aadhaar_encrypt(text,text)', 'public.aadhaar_blind_index(text,text)',
        'public.set_employee_aadhaar(uuid,text,text)', 'public.mask_aadhaar(text)',
        'public.reveal_aadhaar(uuid,uuid,text,text,text)']) f
     where has_function_privilege('anon', f, 'execute')
        or has_function_privilege('authenticated', f, 'execute')));
select pg_temp.assert_true('key-handling functions and set_employee_aadhaar are not callable by service_role',
  not has_function_privilege('service_role', 'public.set_employee_aadhaar(uuid,text,text)', 'execute')
  and not has_function_privilege('service_role', 'public.aadhaar_encrypt(text,text)', 'execute')
  and not has_function_privilege('service_role', 'public.aadhaar_blind_index(text,text)', 'execute'));
select pg_temp.assert_true('service_role can call reveal_aadhaar and mask_aadhaar',
  has_function_privilege('service_role', 'public.reveal_aadhaar(uuid,uuid,text,text,text)', 'execute')
  and has_function_privilege('service_role', 'public.mask_aadhaar(text)', 'execute'));
select pg_temp.assert_true('service_role cannot read encrypted Aadhaar or its hash',
  not has_column_privilege('service_role', 'public.employees', 'aadhaar_encrypted', 'select')
  and not has_column_privilege('service_role', 'public.employees', 'aadhaar_hash', 'select'));
select pg_temp.assert_true('service_role can still read last4 and normal columns',
  has_column_privilege('service_role', 'public.employees', 'aadhaar_last4', 'select')
  and has_column_privilege('service_role', 'public.employees', 'name', 'select')
  and has_column_privilege('service_role', 'public.employees', 'phone', 'select'));
select pg_temp.assert_true('clients have no access to employees or the view',
  not has_table_privilege('anon', 'public.employees', 'select')
  and not has_table_privilege('authenticated', 'public.employees', 'select')
  and not has_table_privilege('authenticated', 'public.employees_masked', 'select')
  and not has_column_privilege('authenticated', 'public.employees', 'aadhaar_encrypted', 'select'));

rollback;