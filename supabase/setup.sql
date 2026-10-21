-- Turno: secure team membership and QR time tracking for Supabase.
-- Apply once to the linked project. All application writes use authenticated RPCs.

create schema if not exists app_private;
revoke all on schema app_private from public;
grant usage on schema app_private to authenticated;

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 2 and 100),
  owner_id uuid not null unique references auth.users(id) on delete cascade,
  join_code uuid not null unique default gen_random_uuid(),
  created_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null check (char_length(btrim(full_name)) between 1 and 100),
  organization_id uuid references public.organizations(id) on delete set null,
  role text not null default 'employee' check (role in ('manager','employee')),
  created_at timestamptz not null default now(),
  check (role = 'employee' or organization_id is not null)
);

alter table public.organizations
  add constraint organizations_owner_profile_fk
  foreign key (owner_id) references public.profiles(id) deferrable initially deferred;

create table public.attendance_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  event_type text not null check (event_type in ('check_in','check_out')),
  recorded_at timestamptz not null default now()
);

create table public.qr_sessions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.qr_session_uses (
  qr_session_id uuid not null references public.qr_sessions(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  used_at timestamptz not null default now(),
  primary key (qr_session_id, profile_id)
);

create index profiles_organization_idx on public.profiles (organization_id, full_name);
create index attendance_org_time_idx on public.attendance_events (organization_id, recorded_at desc);
create index attendance_profile_time_idx on public.attendance_events (profile_id, recorded_at desc);
create index qr_sessions_expiry_idx on public.qr_sessions (expires_at);

alter table public.organizations enable row level security;
alter table public.profiles enable row level security;
alter table public.attendance_events enable row level security;
alter table public.qr_sessions enable row level security;
alter table public.qr_session_uses enable row level security;

create or replace function app_private.is_org_member(target_org uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.organization_id = target_org
  );
$$;

create or replace function app_private.is_org_manager(target_org uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid())
      and p.organization_id = target_org
      and p.role = 'manager'
  );
$$;

revoke all on function app_private.is_org_member(uuid) from public, anon;
revoke all on function app_private.is_org_manager(uuid) from public, anon;
grant execute on function app_private.is_org_member(uuid) to authenticated;
grant execute on function app_private.is_org_manager(uuid) to authenticated;

create policy "Members can read their organization"
on public.organizations for select to authenticated
using (app_private.is_org_member(id));

create policy "Users can read their profile and managers can read their team"
on public.profiles for select to authenticated
using (id = (select auth.uid()) or app_private.is_org_manager(organization_id));

create policy "Users can update their own name"
on public.profiles for update to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

create policy "Employees can read their own events and managers can read team events"
on public.attendance_events for select to authenticated
using (profile_id = (select auth.uid()) or app_private.is_org_manager(organization_id));

create policy "Managers can inspect temporary QR sessions"
on public.qr_sessions for select to authenticated
using (app_private.is_org_manager(organization_id));

revoke all on public.organizations, public.profiles, public.attendance_events from anon, authenticated, public;
grant select on public.organizations, public.profiles, public.attendance_events to authenticated;
revoke select on public.organizations from authenticated;
grant select (id, name, owner_id, created_at) on public.organizations to authenticated;
grant update (full_name) on public.profiles to authenticated;
revoke insert, update, delete on public.organizations from anon, authenticated;
revoke insert, update, delete on public.profiles from anon, authenticated;
revoke insert, update, delete on public.attendance_events from anon, authenticated;
revoke all on public.qr_sessions, public.qr_session_uses from anon, authenticated, public;

create or replace function app_private.create_profile_for_auth_user()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name)
  values (
    new.id,
    coalesce(nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''), 'Utilizador')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

revoke all on function app_private.create_profile_for_auth_user() from public, anon, authenticated;
create trigger on_auth_user_created_profile
after insert on auth.users
for each row execute function app_private.create_profile_for_auth_user();

create or replace function public.create_team(p_name text)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_profile public.profiles%rowtype;
  v_org uuid;
begin
  if v_user is null then raise exception 'Inicia sessão para criar uma equipa.'; end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 2 and 100 then
    raise exception 'O nome da equipa deve ter entre 2 e 100 caracteres.';
  end if;
  select * into v_profile from public.profiles where id = v_user for update;
  if not found then raise exception 'Não foi encontrado o perfil da conta.'; end if;
  if v_profile.organization_id is not null then raise exception 'Esta conta já pertence a uma equipa.'; end if;
  insert into public.organizations (name, owner_id) values (btrim(p_name), v_user) returning id into v_org;
  update public.profiles set organization_id = v_org, role = 'manager' where id = v_user;
  return v_org;
end;
$$;

create or replace function public.join_team(p_code uuid)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_profile public.profiles%rowtype;
  v_org uuid;
begin
  if v_user is null then raise exception 'Inicia sessão para entrar numa equipa.'; end if;
  select * into v_profile from public.profiles where id = v_user for update;
  if not found then raise exception 'Não foi encontrado o perfil da conta.'; end if;
  if v_profile.organization_id is not null then raise exception 'Esta conta já pertence a uma equipa.'; end if;
  select id into v_org from public.organizations where join_code = p_code;
  if v_org is null then raise exception 'Código de equipa inválido.'; end if;
  update public.profiles set organization_id = v_org, role = 'employee' where id = v_user;
  return v_org;
end;
$$;

create or replace function public.rotate_team_join_code()
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_org uuid;
  v_code uuid := gen_random_uuid();
begin
  select organization_id into v_org from public.profiles
  where id = (select auth.uid()) and role = 'manager';
  if v_org is null then raise exception 'Só o responsável da equipa pode renovar o código.'; end if;
  update public.organizations set join_code = v_code where id = v_org;
  return v_code;
end;
$$;

create or replace function public.get_team_join_code()
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_code uuid;
begin
  select o.join_code into v_code
  from public.organizations o
  join public.profiles p on p.organization_id = o.id
  where p.id = (select auth.uid()) and p.role = 'manager';
  if v_code is null then raise exception 'Só o responsável da equipa pode consultar o código.'; end if;
  return v_code;
end;
$$;

create or replace function public.create_qr_session(p_token uuid)
returns timestamptz
language plpgsql security definer
set search_path = ''
as $$
declare
  v_org uuid;
  v_expiry timestamptz := now() + interval '2 minutes';
begin
  select organization_id into v_org from public.profiles
  where id = (select auth.uid()) and role = 'manager';
  if v_org is null then raise exception 'Só o responsável da equipa pode criar um QR.'; end if;
  delete from public.qr_sessions
  where organization_id = v_org and expires_at < now() - interval '1 day';
  insert into public.qr_sessions (organization_id, token_hash, expires_at, created_by)
  values (
    v_org,
    encode(sha256(convert_to(p_token::text, 'UTF8')), 'hex'),
    v_expiry,
    (select auth.uid())
  );
  return v_expiry;
end;
$$;

create or replace function public.record_attendance(p_token uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_profile public.profiles%rowtype;
  v_session public.qr_sessions%rowtype;
  v_previous text;
  v_type text;
  v_recorded_at timestamptz;
begin
  if v_user is null then raise exception 'Inicia sessão antes de registar o ponto.'; end if;
  select * into v_profile from public.profiles where id = v_user for update;
  if not found or v_profile.organization_id is null then
    raise exception 'A tua conta ainda não pertence a uma equipa.';
  end if;
  select * into v_session from public.qr_sessions
  where token_hash = encode(sha256(convert_to(p_token::text, 'UTF8')), 'hex')
    and organization_id = v_profile.organization_id
    and expires_at > now()
  limit 1;
  if not found then raise exception 'Este QR expirou ou não pertence à tua equipa. Pede um novo código.'; end if;

  insert into public.qr_session_uses (qr_session_id, profile_id)
  values (v_session.id, v_user)
  on conflict do nothing;
  if not found then raise exception 'Este QR já foi utilizado. Pede ao responsável que atualize o código.'; end if;

  select event_type into v_previous
  from public.attendance_events
  where profile_id = v_user
    and recorded_at >= (date_trunc('day', now() at time zone 'Europe/Lisbon') at time zone 'Europe/Lisbon')
  order by recorded_at desc
  limit 1;

  v_type := case when v_previous = 'check_in' then 'check_out' else 'check_in' end;
  insert into public.attendance_events (organization_id, profile_id, event_type)
  values (v_profile.organization_id, v_user, v_type)
  returning recorded_at into v_recorded_at;

  return jsonb_build_object('event_type', v_type, 'recorded_at', v_recorded_at);
end;
$$;

revoke all on function public.create_team(text) from public, anon;
revoke all on function public.join_team(uuid) from public, anon;
revoke all on function public.rotate_team_join_code() from public, anon;
revoke all on function public.get_team_join_code() from public, anon;
revoke all on function public.create_qr_session(uuid) from public, anon;
revoke all on function public.record_attendance(uuid) from public, anon;
grant execute on function public.create_team(text) to authenticated;
grant execute on function public.join_team(uuid) to authenticated;
grant execute on function public.rotate_team_join_code() to authenticated;
grant execute on function public.get_team_join_code() to authenticated;
grant execute on function public.create_qr_session(uuid) to authenticated;
grant execute on function public.record_attendance(uuid) to authenticated;


