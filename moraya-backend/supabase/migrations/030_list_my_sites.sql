-- 030_list_my_sites.sql
-- PURPOSE   : "My Sites" for the worker: the sites the caller has worked on, with counts (RPC list_my_sites).
-- DEPENDS ON: 008 (moraya_require_actor, moraya_fail), 014 (sites), 015 (work_entries).
-- ROLLBACK  : drop function public.list_my_sites(uuid, text, text, text, integer, integer);
--
-- WHO MAY CALL : any ACTIVE employee. Only sites where the caller is the surveyor OR the assistant of at
--   least one work entry. Never returns rate_per_visit, site_date or any money.
-- WHAT IS COUNTED (the caller's own entries at that site; cancelled and rejected entries are left out, as
--   everywhere else in the system):
--   entry_count          work entries in draft, pending_verification, changes_requested or verified
--   verified_entry_count of those, the verified ones
--   visit_count          COUNT(DISTINCT work_date) over the caller's VERIFIED entries at the site
--                        (same definition as fin_visit_count in 020: two entries on one day = one visit)
--   last_work_date       latest work_date among the counted entries
--   A site whose entries are all cancelled or rejected does not appear.
-- FILTERS      : status ('all' | 'active' | 'completed' | 'inactive'), q (site name, location, client; max 100).
-- SORT         : '<field>:<asc|desc>', field one of site_name, client_name, last_work_date, entry_count,
--                visit_count. Default 'last_work_date:desc'. Ties by site_name, then id.
-- PAGING       : page 1..100000, page_size capped to 1..100 (default 20).
-- RESPONSE     : {items[], page, page_size, total}
--   items[]: id, site_name, site_location, client_name, status, entry_count, verified_entry_count,
--            visit_count, last_work_date
-- ERRORS       : MORAYA_FORBIDDEN, MORAYA_VALIDATION ('Invalid: status', 'Invalid: sort', 'Too long: q').
create or replace function public.list_my_sites(
  p_actor_auth_id uuid,
  p_q             text    default null,
  p_status        text    default 'all',
  p_sort          text    default 'last_work_date:desc',
  p_page          integer default 1,
  p_page_size     integer default 20
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  public.employees;
  v_status text := lower(btrim(coalesce(p_status, 'all')));
  v_q      text := btrim(coalesce(p_q, ''));
  v_pat    text;
  v_field  text;
  v_dir    text;
  v_order  text;
  v_page   int;
  v_size   int;
  v_base   text;
  v_total  bigint;
  v_items  jsonb;
begin
  v_actor := public.moraya_require_actor(p_actor_auth_id, false, null);

  if v_status not in ('all', 'active', 'completed', 'inactive') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: status');
  end if;
  if char_length(v_q) > 100 then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Too long: q');
  end if;
  if v_q <> '' then
    v_pat := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  v_field := lower(btrim(split_part(coalesce(p_sort, 'last_work_date:desc'), ':', 1)));
  v_dir   := lower(btrim(split_part(coalesce(p_sort, 'last_work_date:desc'), ':', 2)));
  if v_dir = '' then v_dir := 'asc'; end if;
  if v_dir not in ('asc', 'desc') then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: sort');
  end if;
  -- Only these literal fragments and v_dir (asc or desc) are spliced into the SQL text.
  v_order := case v_field
    when 'site_name'      then 'g.site_name ' || v_dir
    when 'client_name'    then 'g.client_name ' || v_dir
    when 'last_work_date' then 'g.last_work_date ' || v_dir
    when 'entry_count'    then 'g.entry_count ' || v_dir
    when 'visit_count'    then 'g.visit_count ' || v_dir
    else null end;
  if v_order is null then
    perform public.moraya_fail('MORAYA_VALIDATION', 'Invalid: sort');
  end if;
  v_order := v_order || ', g.site_name, g.id';

  v_page := greatest(1, least(coalesce(p_page, 1), 100000));
  v_size := greatest(1, least(coalesce(p_page_size, 20), 100));

  -- One row per site. s.id is the primary key of sites, so the other s columns may be selected.
  -- $1 caller, $2 status, $3 search pattern.
  v_base := $b$
    select s.id, s.site_name, s.site_location, s.client_name, s.status,
           count(*)                                                              as entry_count,
           count(*) filter (where w.verification_status = 'verified')            as verified_entry_count,
           count(distinct w.work_date) filter (where w.verification_status = 'verified') as visit_count,
           max(w.work_date)                                                      as last_work_date
      from public.work_entries w
      join public.sites s on s.id = w.site_id
     where (w.surveyor_id = $1 or w.assistant_id = $1)
       and w.verification_status not in ('cancelled', 'rejected')
       and ($2::text = 'all' or s.status::text = $2)
       and ($3::text is null or s.site_name ilike $3 escape '\'
                             or s.site_location ilike $3 escape '\'
                             or s.client_name ilike $3 escape '\')
     group by s.id
  $b$;

  execute 'select count(*) from (' || v_base || ') g'
    into v_total
    using v_actor.id, v_status, v_pat;

  -- $4 limit, $5 offset
  execute 'select coalesce(jsonb_agg(jsonb_build_object(
                    ''id'', x.id, ''site_name'', x.site_name, ''site_location'', x.site_location,
                    ''client_name'', x.client_name, ''status'', x.status,
                    ''entry_count'', x.entry_count, ''verified_entry_count'', x.verified_entry_count,
                    ''visit_count'', x.visit_count, ''last_work_date'', x.last_work_date)
                  order by x.rn), ''[]''::jsonb)
            from (
              select row_number() over (order by ' || v_order || ') as rn, g.*
                from (' || v_base || ') g
               order by ' || v_order || '
               limit $4 offset $5) x'
    into v_items
    using v_actor.id, v_status, v_pat, v_size, (v_page - 1) * v_size;

  return jsonb_build_object('items', v_items, 'page', v_page, 'page_size', v_size, 'total', v_total);
end $$;

revoke all on function public.list_my_sites(uuid, text, text, text, integer, integer) from public, anon, authenticated;
grant execute on function public.list_my_sites(uuid, text, text, text, integer, integer) to service_role;