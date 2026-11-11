-- TF-Tracker STEP 51 : R&R keeps 3 years (see purge_if_full in setup.sql) + M&R archive to Google Drive.  Already inside setup.sql; run this file ONLY if you do not re-run setup.sql.

-- ################ STEP 51 : R&R keeps 3 years + M&R (Repair, Testing Register) archive to Google Drive ################
-- Run ONCE in Supabase > SQL Editor (it is already inside setup.sql).  Safe to run again.
--  * R&R (table "data"): when the storage is 90% full, the OLDEST 12 months of PRs are deleted every Sunday - but NEVER a PR newer than 3 years.
--  * M&R Repair (rr_entry) and Testing Register (test_reg) are NOT touched by that job.  When R&R is down to 3 years and the storage is still full,
--    the Admin tab has the box "Google Drive archive": it saves the OLDEST month to Google Drive, and only after Drive confirms every row, deletes it here.
create table if not exists public.arch_cfg (id int primary key default 1 check (id = 1), url text, token text, updated_at timestamptz not null default now());
alter table public.arch_cfg enable row level security;
revoke all on public.arch_cfg from public, anon, authenticated;
create table if not exists public.arch_log (id bigserial primary key, at timestamptz not null default now(), month text, rr_rows int, tr_rows int, by_login text, note text);
alter table public.arch_log enable row level security;
revoke all on public.arch_log from public, anon, authenticated;

create or replace function public.arch_ok() returns boolean language sql stable security definer set search_path = public as
$$ select coalesce((select p.active and p.role in ('admin', 'creator') from public.profiles p where p.user_id = auth.uid()), false) $$;

create or replace function public.arch_cfg_get() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c record;
begin
  if not public.arch_ok() then raise exception 'Only an Admin can do this.'; end if;
  select * into c from public.arch_cfg where id = 1;
  return jsonb_build_object('url', coalesce(c.url, ''), 'token', coalesce(c.token, ''));
end $$;

create or replace function public.arch_cfg_set(p_url text, p_token text) returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.arch_ok() then raise exception 'Only an Admin can do this.'; end if;
  p_url := btrim(coalesce(p_url, '')); p_token := btrim(coalesce(p_token, ''));
  if p_url !~ '^https://script\.google\.com/macros/s/[A-Za-z0-9_-]+/exec$' then raise exception 'The link must look like https://script.google.com/macros/s/.../exec'; end if;
  if length(p_token) < 8 or length(p_token) > 100 then raise exception 'The secret code must be 8 to 100 characters.'; end if;
  insert into public.arch_cfg (id, url, token) values (1, p_url, p_token)
    on conflict (id) do update set url = excluded.url, token = excluded.token, updated_at = now();
  return true;
end $$;

-- the months that may be archived: older than 12 months.  R&R floor = no PR older than 3 years is left
create or replace function public.arch_status_json() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare sz numeric := pg_database_size(current_database()) / 1048576.0; lim date := date_trunc('month', current_date - interval '12 months')::date; mw text[] := coalesce(public.my_workshops(), '{}');
begin
  if not public.arch_ok() then raise exception 'Only an Admin can do this.'; end if;
  return jsonb_build_object('mb', round(sz, 1), 'limit_mb', 500, 'pct', round(sz * 100 / 500, 0),
    'rr_old', (select count(*) from public.data where pr_date is not null and pr_date < (current_date - interval '36 months')::date),
    'months', coalesce((select jsonb_agg(jsonb_build_object('m', m, 'rr', rr, 'tr', tr) order by m) from (
        select m, sum(rr)::int rr, sum(tr)::int tr from (
          select to_char(day, 'YYYY-MM') m, count(*) rr, 0 tr from public.rr_entry where day < lim and workshop = any (mw) group by 1
          union all
          select to_char(coalesce(test_date, created_at::date), 'YYYY-MM'), 0, count(*) from public.test_reg
            where coalesce(test_date, created_at::date) < lim and workshop = any (mw) group by 1) u
        group by m order by m limit 40) z), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object('at', to_char(at at time zone 'Asia/Kolkata', 'DD.MM.YYYY HH24:MI'), 'month', month, 'rr', rr_rows, 'tr', tr_rows) order by id desc) from (select * from public.arch_log order by id desc limit 5) l), '[]'::jsonb));
end $$;

-- every Repair and Testing Register row of one month (to be saved to Drive)
create or replace function public.arch_month_json(p_month text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d0 date; d1 date; lim date := date_trunc('month', current_date - interval '12 months')::date; mw text[] := coalesce(public.my_workshops(), '{}');
begin
  if not public.arch_ok() then raise exception 'Only an Admin can do this.'; end if;
  if p_month !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'Wrong month.'; end if;
  d0 := (p_month || '-01')::date; d1 := (d0 + interval '1 month')::date;
  if d1 > lim then raise exception 'Only a month older than 12 months can be archived.'; end if;
  return jsonb_build_object('month', p_month,
    'rr', coalesce((select jsonb_agg(jsonb_build_array(workshop, day, block, firm, cap, qty, by_login, to_char(at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI')) order by workshop, day, block, firm, cap)
                    from public.rr_entry where day >= d0 and day < d1 and workshop = any (mw)), '[]'::jsonb),
    'tr', coalesce((select jsonb_agg(jsonb_build_array(id, workshop, firm, cap, job_no, test_date, tr_r, tr_y, tr_b, meg_hve, meg_lve, meg_hvlv, dvdf, hv, nll, fll, remark, by_login, to_char(created_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI')) order by workshop, test_date, id)
                    from public.test_reg where coalesce(test_date, created_at::date) >= d0 and coalesce(test_date, created_at::date) < d1 and workshop = any (mw)), '[]'::jsonb));
end $$;

-- delete EXACTLY the rows that Drive has confirmed (the app sends their keys), nothing else
create or replace function public.arch_delete(p_month text, p_rr jsonb, p_tr jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare d0 date; d1 date; lim date := date_trunc('month', current_date - interval '12 months')::date; mw text[] := coalesce(public.my_workshops(), '{}'); a int; b int; me text;
begin
  if not public.arch_ok() then raise exception 'Only an Admin can do this.'; end if;
  if p_month !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'Wrong month.'; end if;
  d0 := (p_month || '-01')::date; d1 := (d0 + interval '1 month')::date;
  if d1 > lim then raise exception 'Only a month older than 12 months can be archived.'; end if;
  delete from public.rr_entry e using jsonb_array_elements(coalesce(p_rr, '[]'::jsonb)) x(v)
   where e.workshop = x.v->>0 and e.day = (x.v->>1)::date and e.block = x.v->>2 and e.firm = x.v->>3 and e.cap = x.v->>4
     and e.day >= d0 and e.day < d1 and e.workshop = any (mw);
  get diagnostics a = row_count;
  delete from public.test_reg t where t.id in (select (jsonb_array_elements_text(coalesce(p_tr, '[]'::jsonb)))::bigint)
     and coalesce(t.test_date, t.created_at::date) >= d0 and coalesce(t.test_date, t.created_at::date) < d1 and t.workshop = any (mw);
  get diagnostics b = row_count;
  select login_id into me from public.profiles where user_id = auth.uid();
  insert into public.arch_log (month, rr_rows, tr_rows, by_login, note) values (p_month, a, b, me, 'Saved to Google Drive, then deleted here.');
  return jsonb_build_object('rr', a, 'tr', b);
end $$;

revoke all on function public.arch_ok(), public.arch_cfg_get(), public.arch_cfg_set(text, text), public.arch_status_json(), public.arch_month_json(text), public.arch_delete(text, jsonb, jsonb) from public, anon;
grant execute on function public.arch_ok(), public.arch_cfg_get(), public.arch_cfg_set(text, text), public.arch_status_json(), public.arch_month_json(text), public.arch_delete(text, jsonb, jsonb) to authenticated;

-- give the space of the M&R tables back after a delete (Sunday, after the R&R job)
do $$
begin
  begin perform cron.unschedule('tf-shrink-rr'); exception when others then null; end;
  begin perform cron.unschedule('tf-shrink-test'); exception when others then null; end;
  perform cron.schedule('tf-shrink-rr',   '40 21 * * 6', 'VACUUM FULL public.rr_entry');
  perform cron.schedule('tf-shrink-test', '50 21 * * 6', 'VACUUM FULL public.test_reg');
exception when others then
  raise notice 'pg_cron is not available: the shrink jobs of the M&R tables were NOT created (%).', sqlerrm;
end $$;
create or replace function public.arch_cfg_clear() returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.arch_ok() then raise exception 'Only an Admin can do this.'; end if;
  delete from public.arch_cfg where id = 1;
  return true;
end $$;
revoke all on function public.arch_cfg_clear() from public, anon;
grant execute on function public.arch_cfg_clear() to authenticated;
notify pgrst, 'reload schema';
