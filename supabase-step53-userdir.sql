-- TF-Tracker STEP 53 : login with only ID + password (directory).  Also inside setup.sql.

-- ################ STEP 53 : LOGIN WITH ONLY ID + PASSWORD (a directory in the DEFAULT project) ################
-- The DEFAULT project (the one in config.js, the App Creator's) keeps a directory: which login ID belongs to which Admin's project.
-- Every Admin publishes his IDs from Admin > "Login without code".  The App Creator approves the Admin once (Admin > "Admin directory").
-- The login page then finds the project by the ID, so nobody needs the workshop code.  An ID found in two approved projects cannot log in.
-- Run this file in EVERY project (it is inside setup.sql); only the DEFAULT project uses the directory tables.  Safe to run again.
create table if not exists public.ud_project (
  pid uuid primary key default gen_random_uuid(), url text not null unique, key text not null, label text not null default '',
  token_hash text not null, status text not null default 'pending' check (status in ('pending', 'approved', 'blocked')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table if not exists public.ud_login (
  login text not null, pid uuid not null references public.ud_project (pid) on delete cascade, primary key (login, pid));
create index if not exists ud_login_pid on public.ud_login (pid);
alter table public.ud_project enable row level security; alter table public.ud_login enable row level security;
revoke all on public.ud_project, public.ud_login from public, anon, authenticated;

-- (own project) the Admin's directory token, kept in his own database
create table if not exists public.ud_cfg (id int primary key default 1 check (id = 1), token text, updated_at timestamptz not null default now());
alter table public.ud_cfg enable row level security;
revoke all on public.ud_cfg from public, anon, authenticated;

create or replace function public.ud_ok() returns boolean language sql stable security definer set search_path = public as
$$ select coalesce((select p.active and p.role in ('admin', 'creator') from public.profiles p where p.user_id = auth.uid()), false) $$;
create or replace function public.ud_creator() returns boolean language sql stable security definer set search_path = public as
$$ select coalesce((select p.active and p.role = 'creator' from public.profiles p where p.user_id = auth.uid()), false) $$;

-- (own project) the login IDs of this project, and the saved token
create or replace function public.ud_logins_json() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.ud_ok() then raise exception 'Only an Admin can do this.'; end if;
  return coalesce((select jsonb_agg(distinct lower(btrim(login_id))) from public.profiles where active and coalesce(btrim(login_id), '') <> ''), '[]'::jsonb);
end $$;
create or replace function public.ud_cfg_get() returns text language plpgsql stable security definer set search_path = public as $$
begin
  if not public.ud_ok() then raise exception 'Only an Admin can do this.'; end if;
  return (select token from public.ud_cfg where id = 1);
end $$;
create or replace function public.ud_cfg_set(p_token text) returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.ud_ok() then raise exception 'Only an Admin can do this.'; end if;
  if p_token is null or p_token = '' then delete from public.ud_cfg where id = 1; return true; end if;
  if length(p_token) < 20 or length(p_token) > 100 then raise exception 'Wrong token.'; end if;
  insert into public.ud_cfg (id, token) values (1, p_token) on conflict (id) do update set token = excluded.token, updated_at = now();
  return true;
end $$;

-- (default project) an Admin publishes his IDs.  First call: p_token is null -> the project is added (status pending) and a token is returned ONCE.
create or replace function public.ud_register(p_url text, p_key text, p_label text, p_logins jsonb, p_token text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pr public.ud_project; v_tok text; v_role text; v_pl text; a text[]; l text; n int := 0; conf jsonb;
begin
  p_url := lower(btrim(coalesce(p_url, ''))); p_key := btrim(coalesce(p_key, ''));
  if p_url !~ '^https://[a-z0-9-]+\.supabase\.co$' then raise exception 'Wrong project address.'; end if;
  if length(p_key) < 20 or p_key ~* 'service_role' or p_key ~ '^sb_secret_' then raise exception 'Wrong key (only the publishable / anon key is allowed).'; end if;
  if position('.' in p_key) > 0 then
    begin
      v_pl := translate(split_part(p_key, '.', 2), '-_', '+/'); v_pl := v_pl || repeat('=', (4 - length(v_pl) % 4) % 4);
      v_role := convert_from(decode(v_pl, 'base64'), 'utf8')::jsonb ->> 'role';
    exception when others then v_role := null; end;
    if v_role is distinct from 'anon' then raise exception 'Wrong key (only the publishable / anon key is allowed).'; end if;
  end if;
  if jsonb_typeof(coalesce(p_logins, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_logins, '[]'::jsonb)) > 3000 then raise exception 'Too many IDs.'; end if;
  select * into pr from public.ud_project where url = p_url;
  if pr.pid is null then
    v_tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
    insert into public.ud_project (url, key, label, token_hash) values (p_url, p_key, left(btrim(coalesce(p_label, '')), 120), encode(sha256(convert_to(v_tok, 'utf8')), 'hex')) returning * into pr;
  else
    if p_token is null or pr.token_hash <> encode(sha256(convert_to(p_token, 'utf8')), 'hex') then raise exception 'This project is already in the directory. Use the saved token, or ask the App Creator to remove it and publish again.'; end if;
    update public.ud_project set key = p_key, label = coalesce(nullif(left(btrim(coalesce(p_label, '')), 120), ''), label), updated_at = now() where pid = pr.pid;
  end if;
  delete from public.ud_login where pid = pr.pid;
  for l in select lower(btrim(x)) from jsonb_array_elements_text(coalesce(p_logins, '[]'::jsonb)) x loop
    if l ~ '^[a-z0-9._@+-]{2,80}$' then insert into public.ud_login (login, pid) values (l, pr.pid) on conflict do nothing; n := n + 1; end if;
  end loop;
  select coalesce(jsonb_agg(distinct a.login), '[]'::jsonb) into conf from public.ud_login a join public.ud_login b on b.login = a.login and b.pid <> a.pid where a.pid = pr.pid;
  return jsonb_build_object('token', v_tok, 'status', (select status from public.ud_project where pid = pr.pid), 'count', n, 'conflicts', conf);
end $$;

-- (default project) the login page / the create-user check: which approved project has this ID?
create or replace function public.ud_find(p_login text, p_url text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l text := lower(btrim(coalesce(p_login, ''))); n int; m int; ru text; rk text;
begin
  if l !~ '^[a-z0-9._@+-]{2,80}$' then return jsonb_build_object('n', 0, 'other', 0); end if;
  select count(*) into n from public.ud_login x join public.ud_project p on p.pid = x.pid and p.status = 'approved' where x.login = l;
  select count(*) into m from public.ud_login x join public.ud_project p on p.pid = x.pid and p.status = 'approved' where x.login = l and (p_url is null or p.url <> lower(btrim(p_url)));
  if n = 1 then select p.url, p.key into ru, rk from public.ud_login x join public.ud_project p on p.pid = x.pid and p.status = 'approved' where x.login = l; end if;
  return jsonb_build_object('n', n, 'other', m, 'u', ru, 'k', rk);
end $$;

-- (default project, App Creator) the Admin directory
create or replace function public.ud_admin_list() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.ud_creator() then raise exception 'Only the App Creator can do this.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('pid', p.pid, 'label', p.label, 'url', p.url, 'status', p.status, 'ids', (select count(*) from public.ud_login x where x.pid = p.pid),
            'conf', (select count(distinct a.login) from public.ud_login a join public.ud_login b on b.login = a.login and b.pid <> a.pid where a.pid = p.pid),
            'at', to_char(p.created_at at time zone 'Asia/Kolkata', 'DD.MM.YYYY')) order by p.created_at) from public.ud_project p), '[]'::jsonb);
end $$;
create or replace function public.ud_admin_set(p_pid uuid, p_action text) returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.ud_creator() then raise exception 'Only the App Creator can do this.'; end if;
  if p_action = 'remove' then delete from public.ud_project where pid = p_pid;
  elsif p_action in ('approved', 'blocked', 'pending') then update public.ud_project set status = p_action, updated_at = now() where pid = p_pid;
  else raise exception 'Wrong action.'; end if;
  return true;
end $$;

revoke all on function public.ud_ok(), public.ud_creator(), public.ud_logins_json(), public.ud_cfg_get(), public.ud_cfg_set(text), public.ud_register(text, text, text, jsonb, text), public.ud_find(text, text), public.ud_admin_list(), public.ud_admin_set(uuid, text) from public, anon, authenticated;
grant execute on function public.ud_register(text, text, text, jsonb, text), public.ud_find(text, text) to anon, authenticated;
grant execute on function public.ud_logins_json(), public.ud_cfg_get(), public.ud_cfg_set(text), public.ud_admin_list(), public.ud_admin_set(uuid, text) to authenticated;
-- (default project) the Admin asks how his project stands (needs his token)
create or replace function public.ud_status(p_url text, p_token text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare pr public.ud_project; conf jsonb;
begin
  select * into pr from public.ud_project where url = lower(btrim(coalesce(p_url, '')));
  if pr.pid is null or p_token is null or pr.token_hash <> encode(sha256(convert_to(p_token, 'utf8')), 'hex') then return jsonb_build_object('status', 'none'); end if;
  select coalesce(jsonb_agg(distinct a.login), '[]'::jsonb) into conf from public.ud_login a join public.ud_login b on b.login = a.login and b.pid <> a.pid where a.pid = pr.pid;
  return jsonb_build_object('status', pr.status, 'count', (select count(*) from public.ud_login where pid = pr.pid), 'conflicts', conf);
end $$;
revoke all on function public.ud_status(text, text) from public, anon, authenticated;
grant execute on function public.ud_status(text, text) to anon, authenticated;
notify pgrst, 'reload schema';
