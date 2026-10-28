-- 027_rls_coverage_check.sql
-- PURPOSE   : READ-ONLY verification script (NOT a migration). Run it after migrations 001-026 and
--             again after every later migration. It changes nothing: one SELECT, no DDL, no DML.
--             It reports four lists for the public schema:
--               1. tables with row level security NOT enabled
--               2. tables with NO row level security policy at all
--               3. functions that anon or authenticated can execute
--               4. financial tables where anyone other than the owner holds DELETE (or TRUNCATE)
-- DEPENDS ON: nothing at run time (reads pg_catalog only). Meant for 001-026.
-- ROLLBACK  : nothing to roll back.
-- HOW TO RUN: Supabase SQL editor (runs as postgres) or `psql -f`. Keep it OUT of supabase/migrations/
--             so `supabase db push` never treats it as a migration (it lives in supabase/checks/).
--
-- HOW TO READ THE OUTPUT (one result set, sorted):
--   row_type SUMMARY : one row per check with the number of findings and PASS or FAIL.
--                      check_no 0 is the overall verdict (PASS only when checks 1-4 are all PASS).
--   row_type FINDING : one row per offending object, directly under its check. "object" is the table
--                      or function; "detail" says what is wrong and what to do.
--   Expected: every SUMMARY row says PASS and there are no FINDING rows.
--
-- WHAT COUNTS AS WHAT
--   * Scope: schema public only. Tables and partitioned tables; extension-owned objects (citext,
--     pgcrypto) are ignored. Views are not tables and are not listed (the 020 views use
--     security_invoker = true, so they follow the RLS of the tables underneath).
--   * Check 1: pg_class.relrowsecurity = false.
--   * Check 2: no row in pg_policy for the table. With RLS on and no policy, clients are denied
--     everything, so this is safe, but it is listed so the intent is explicit (see the note under
--     "If check 2 is not empty" below).
--   * Check 3: has_function_privilege('anon' / 'authenticated', oid, 'EXECUTE') is true. That already
--     counts a grant to PUBLIC, because every role inherits PUBLIC. Only functions in public are
--     checked, and only the roles anon and authenticated (skipped if a role does not exist).
--   * Check 4: "financial" = the named tables below, PLUS any other public table that has a bigint
--     column called amount, received_amount, paid_amount, rate or rate_per_visit (so a new money
--     table is picked up automatically). A privilege counts when it is granted to PUBLIC or to any
--     role other than the table owner (this includes service_role). TRUNCATE is listed together with
--     DELETE because it deletes every row in one go; 026 revokes both.
--
-- IF A CHECK FAILS
--   1. Run `alter table public.<t> enable row level security;` in a new migration, then add policies
--      or revoke client grants (007 pattern).
--   3. `revoke all on function <signature> from public, anon, authenticated;` then
--      `grant execute on function <signature> to service_role;` in a new migration.
--   4. `revoke delete, truncate on public.<t> from public, anon, authenticated, service_role;` and make
--      sure the table has the BEFORE DELETE / BEFORE TRUNCATE blocker trigger (see 026).
--   Do not edit old migrations; fix forward with a new numbered file.
--
-- IF CHECK 2 IS NOT EMPTY (expected with the current design)
--   The design in 007 is "RLS on, no client policy, service_role only": clients have no table grants
--   either, so the table is closed twice. Only employees, sub_admin_permissions (own-row select) and
--   app_settings (explicit deny policy, migration 010) have a policy. Every other table will therefore
--   show up in check 2. To turn check 2 green, add an explicit deny-all policy per table in a new
--   migration, the way 010 does for app_settings:
--     create policy <t>_no_client_access on public.<t> for all to anon, authenticated
--       using (false) with check (false);
--   Until then, read check 2 as "closed by default deny, no explicit policy written".

with
client_roles as (
  select oid, rolname
  from pg_roles
  where rolname in ('anon', 'authenticated')
),

-- Ordinary and partitioned tables in public, minus extension-owned ones.
app_tables as (
  select c.oid, c.relname, c.relrowsecurity, c.relowner, c.relacl
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind in ('r', 'p')
    and not c.relispartition
    and not exists (select 1 from pg_depend d
                     where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'e')
),

-- Financial tables: named list + any table with a money-looking bigint column.
financial_tables as (
  select t.oid, t.relname, t.relowner, t.relacl
  from app_tables t
  where t.relname in ('work_entries', 'expenses', 'income_transactions', 'salary_records',
                      'client_bills', 'work_entry_history', 'expense_history', 'salary_history')
     or exists (select 1 from pg_attribute a
                 where a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped
                   and a.atttypid = 'bigint'::regtype
                   and a.attname in ('amount', 'received_amount', 'paid_amount', 'rate', 'rate_per_visit'))
),

findings as (
  -- 1. RLS not enabled
  select 1 as check_no,
         t.relname::text as object,
         'row level security is OFF: run alter table ... enable row level security' as detail
  from app_tables t
  where not t.relrowsecurity

  union all

  -- 2. no policy at all
  select 2,
         t.relname::text,
         case when t.relrowsecurity
              then 'RLS is on but there is no policy (default deny; add an explicit deny-all policy to make the intent visible)'
              else 'no policy and RLS is off' end
  from app_tables t
  where not exists (select 1 from pg_policy p where p.polrelid = t.oid)

  union all

  -- 3. functions executable by anon / authenticated
  select 3,
         p.oid::regprocedure::text,
         'executable by: ' || string_agg(r.rolname, ', ' order by r.rolname)
           || case when p.prosecdef then ' (SECURITY DEFINER)' else '' end
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  cross join client_roles r
  where n.nspname = 'public'
    and p.prokind in ('f', 'p')
    and not exists (select 1 from pg_depend d
                     where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
    and has_function_privilege(r.oid, p.oid, 'EXECUTE')
  group by p.oid, p.prosecdef

  union all

  -- 4. DELETE / TRUNCATE granted on a financial table (anyone but the owner)
  select 4,
         t.relname::text,
         string_agg(distinct x.privilege_type || ' granted to '
                      || case when x.grantee = 0 then 'PUBLIC' else x.grantee::regrole::text end,
                    '; ')
  from financial_tables t
  cross join lateral aclexplode(t.relacl) x
  where x.privilege_type in ('DELETE', 'TRUNCATE')
    and x.grantee <> t.relowner
  group by t.oid, t.relname
),

checks(check_no, check_name) as (
  values (1, 'Tables without row level security'),
         (2, 'Tables without any policy'),
         (3, 'Functions executable by anon or authenticated'),
         (4, 'Financial tables with a DELETE/TRUNCATE grant')
),

summary as (
  select c.check_no,
         c.check_name,
         count(f.check_no) as findings
  from checks c
  left join findings f using (check_no)
  group by c.check_no, c.check_name
)

select check_no, row_type, check_name, object, detail, result
from (
  -- overall verdict
  select 0 as check_no, 'SUMMARY' as row_type, 'OVERALL (checks 1-4)' as check_name,
         (select count(*) from findings)::text || ' finding(s)' as object,
         null::text as detail,
         case when (select count(*) from findings) = 0 then 'PASS' else 'FAIL' end as result,
         0 as sort_key
  union all
  -- one row per check
  select s.check_no, 'SUMMARY', s.check_name,
         s.findings::text || ' finding(s)', null,
         case when s.findings = 0 then 'PASS' else 'FAIL' end, 0
  from summary s
  union all
  -- the offending objects
  select f.check_no, 'FINDING', c.check_name, f.object, f.detail, null, 1
  from findings f
  join checks c using (check_no)
) q
order by check_no, sort_key, object;