-- TF-Tracker STEP 52 : M&R Summary shows Repair.  (Also inside setup.sql.)

-- ################ STEP 52 : M&R Summary also shows REPAIR (Repair tab, REPAIR block; 250 AL + 250 CU = 250) ################
-- today, till date (From-To) and capacity wise.  Run ONCE (already inside setup.sql).  Safe to run again.
create or replace function public.mr_repair_json(p_date date, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare mw text[] := coalesce(public.my_workshops(), '{}'); r jsonb;
begin
  if not public.mr_ok() then raise exception 'No access to the M&R dashboard.'; end if;
  with e as (select workshop, day, nullif(regexp_replace(cap, '\D', '', 'g'), '')::int cap, qty from public.rr_entry
              where block = 'REPAIR' and workshop = any (mw) and (day = p_date or day between p_from and p_to))
  select jsonb_build_object(
    'ws',  coalesce((select jsonb_agg(jsonb_build_array(workshop, today, tot) order by workshop)
                       from (select workshop, coalesce(sum(qty) filter (where day = p_date), 0)::int today, coalesce(sum(qty) filter (where day between p_from and p_to), 0)::int tot from e group by workshop) a), '[]'::jsonb),
    'cap', coalesce((select jsonb_agg(jsonb_build_array(workshop, cap, n) order by workshop, cap)
                       from (select workshop, coalesce(cap, 0) cap, sum(qty)::int n from e where day between p_from and p_to group by workshop, coalesce(cap, 0) having sum(qty) > 0) b), '[]'::jsonb))
    into r;
  return r;
end $$;
revoke all on function public.mr_repair_json(date, date, date) from public, anon;
grant execute on function public.mr_repair_json(date, date, date) to authenticated;
notify pgrst, 'reload schema';
