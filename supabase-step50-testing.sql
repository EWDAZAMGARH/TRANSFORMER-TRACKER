-- Step 50: Testing Register - same job no may be entered many times (coloured by count), one turn ratio / megger value. Safe to run again.
drop index if exists public.test_reg_job;
create index if not exists test_reg_job_n on public.test_reg (workshop, upper(job_no)) where coalesce(job_no, '') <> '';
create or replace function public.test_list_json(p_from date, p_to date, p_ws text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare ed text[]; tot int;
begin
  if not public.mr_ok() then raise exception 'No access to the M&R dashboard.'; end if;
  if p_from is null or p_to is null or p_from > p_to then raise exception 'Choose the From and To dates.'; end if;
  select coalesce(array_agg(w), '{}') into ed from unnest(public.my_workshops()) w where public.mr_edit_ok(w);
  select count(*) into tot from public.test_reg t where t.workshop = any (public.my_workshops()) and t.test_date between p_from and p_to and (coalesce(p_ws, '') = '' or t.workshop = p_ws);
  return jsonb_build_object('total', tot, 'rows', coalesce((
    select jsonb_agg(jsonb_build_array(z.id, z.workshop, z.firm, z.cap, z.job_no, to_char(z.test_date, 'DD.MM.YYYY'), z.tr_r, z.tr_y, z.tr_b, z.meg_hve, z.meg_lve, z.meg_hvlv, z.dvdf, z.hv, z.nll, z.fll, z.remark,
                                         case when z.workshop = any (ed) then 1 else 0 end,
                                         (select count(*) from public.test_reg q where q.workshop = z.workshop and upper(q.job_no) = upper(z.job_no))) order by z.test_date, z.id)
      from (select t.* from public.test_reg t where t.workshop = any (public.my_workshops()) and t.test_date between p_from and p_to and (coalesce(p_ws, '') = '' or t.workshop = p_ws)
             order by t.test_date, t.id limit 3000) z), '[]'::jsonb));
end $$;

-- save one or more rows. A row is {id?, workshop, firm, cap, job_no, test_date (YYYY-MM-DD), tr_r, tr_y, tr_b, meg_hve, meg_lve, meg_hvlv, dvdf, hv, nll, fll, remark}
-- ONE turn ratio and ONE megger value per test (stored in all three columns). If left empty, one value is picked at random between 43.5-44.5 (turn ratio) and 2000-5000 (megger).
-- Returns [{i, id, tr, mg, cnt}] for every saved row (cnt = how many times this job no is now in the register of the workshop).
create or replace function public.test_save(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e jsonb; i int := 0; rid bigint; outj jsonb := '[]'::jsonb; c public.profiles := public.tf_caller(); w text; trv text; mgv text; jn text; cn int;
begin
  if not public.mr_ok() then raise exception 'No access to the M&R dashboard.'; end if;
  for e in select * from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    w := e->>'workshop'; jn := btrim(e->>'job_no');
    if not public.mr_edit_ok(w) then raise exception 'You cannot change the register of %.', w; end if;
    if coalesce(jn, '') = '' then raise exception 'Job no / unique no is needed.'; end if;
    if (e->>'cap')::int not in (10, 16, 25, 63, 100, 160, 250, 400, 630, 1000) then raise exception 'Choose the capacity.'; end if;
    trv := coalesce(nullif(btrim(e->>'tr_r'), ''), nullif(btrim(e->>'tr_y'), ''), nullif(btrim(e->>'tr_b'), ''), round((43.5 + random())::numeric, 1)::text);
    mgv := coalesce(nullif(btrim(e->>'meg_hve'), ''), nullif(btrim(e->>'meg_lve'), ''), nullif(btrim(e->>'meg_hvlv'), ''), (round((2000 + random() * 3000)::numeric, -1)::bigint)::text || 'M-ohm');
    if nullif(e->>'id', '') is not null then
      update public.test_reg set workshop = w, firm = nullif(upper(btrim(e->>'firm')), ''), cap = (e->>'cap')::int, job_no = jn, test_date = nullif(e->>'test_date', '')::date,
             tr_r = trv, tr_y = trv, tr_b = trv, meg_hve = mgv, meg_lve = mgv, meg_hvlv = mgv,
             dvdf = nullif(btrim(e->>'dvdf'), ''), hv = nullif(btrim(e->>'hv'), ''), nll = nullif(e->>'nll', '')::numeric, fll = nullif(e->>'fll', '')::numeric,
             remark = nullif(btrim(e->>'remark'), ''), by_login = c.login_id, updated_at = now()
       where id = (e->>'id')::bigint and workshop = any (public.my_workshops()) returning id into rid;
      if rid is null then raise exception 'This row was not found.'; end if;
    else
      insert into public.test_reg (workshop, firm, cap, job_no, test_date, tr_r, tr_y, tr_b, meg_hve, meg_lve, meg_hvlv, dvdf, hv, nll, fll, remark, by_login)
      values (w, nullif(upper(btrim(e->>'firm')), ''), (e->>'cap')::int, jn, nullif(e->>'test_date', '')::date, trv, trv, trv, mgv, mgv, mgv,
              nullif(btrim(e->>'dvdf'), ''), nullif(btrim(e->>'hv'), ''), nullif(e->>'nll', '')::numeric, nullif(e->>'fll', '')::numeric, nullif(btrim(e->>'remark'), ''), c.login_id)
      returning id into rid;
    end if;
    select count(*) into cn from public.test_reg q where q.workshop = w and upper(q.job_no) = upper(jn);
    outj := outj || jsonb_build_array(jsonb_build_object('i', i, 'id', rid, 'tr', trv, 'mg', mgv, 'cnt', cn));
    i := i + 1;
  end loop;
  return outj;
end $$;
grant execute on function public.test_list_json(date, date, text), public.test_save(jsonb) to authenticated;
notify pgrst, 'reload schema';
