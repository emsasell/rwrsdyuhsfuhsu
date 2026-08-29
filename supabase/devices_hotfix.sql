-- EMCHAT V6.1 DEVICES HOTFIX
-- Run this if your existing database was created with an older EMCHAT schema.
create extension if not exists pgcrypto;

create table if not exists public.devices (
 id text primary key,
 user_id uuid not null references auth.users(id) on delete cascade,
 name text,
 user_agent text,
 last_seen timestamptz default now(),
 created_at timestamptz default now()
);

alter table public.devices add column if not exists name text;
alter table public.devices add column if not exists device_name text;
alter table public.devices add column if not exists device_type text;
alter table public.devices add column if not exists last_seen timestamptz default now();
alter table public.devices add column if not exists last_seen_at timestamptz;
alter table public.devices add column if not exists is_current boolean not null default false;

update public.devices
set name=coalesce(name,device_name,'Устройство')
where name is null;

update public.devices
set last_seen=coalesce(last_seen,last_seen_at,created_at,now())
where last_seen is null;

create index if not exists devices_user_idx on public.devices(user_id);
create index if not exists devices_last_seen_idx on public.devices(last_seen desc);

alter table public.devices enable row level security;

drop policy if exists devices_own on public.devices;
create policy devices_own on public.devices
for all to authenticated
using (user_id=auth.uid())
with check (user_id=auth.uid());

-- Remove incompatible legacy return signatures before recreating the helper.
drop function if exists public.get_my_devices();

-- Optional helper for checking the current account's devices.
create or replace function public.get_my_devices()
returns table(
 id text,
 user_id uuid,
 name text,
 device_type text,
 user_agent text,
 last_seen timestamptz,
 created_at timestamptz,
 is_current boolean
)
language sql stable security definer set search_path=public as $$
 select d.id::text,d.user_id,coalesce(d.name,d.device_name,'Устройство'),d.device_type,d.user_agent,
        coalesce(d.last_seen,d.last_seen_at,d.created_at),d.created_at,d.is_current
 from public.devices d
 where d.user_id=auth.uid()
 order by coalesce(d.is_current,false) desc,coalesce(d.last_seen,d.last_seen_at,d.created_at) desc
$$;

grant execute on function public.get_my_devices() to authenticated;

-- V7.1: kick another device from the current account.
drop function if exists public.kick_my_device(text);
create or replace function public.kick_my_device(p_device_id text)
returns boolean language plpgsql security definer set search_path=public as $$
begin
 delete from public.devices where id=p_device_id and user_id=auth.uid();
 if not found then raise exception 'Устройство не найдено или уже отключено'; end if;
 return true;
end; $$;
grant execute on function public.kick_my_device(text) to authenticated;
notify pgrst, 'reload schema';
