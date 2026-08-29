-- EMCHAT PRO V6 FULL
-- Safe migration: run in Supabase SQL Editor. Existing users/chats/messages are not deleted.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 username text unique,
 display_name text not null default 'Пользователь',
 avatar_url text,
 bio text,
 last_seen timestamptz default now(),
 created_at timestamptz default now()
);
create table if not exists public.chats (
 id uuid primary key default gen_random_uuid(),
 kind text not null default 'group' check(kind in ('dm','group','channel')),
 title text,
 description text,
 avatar_url text,
 invite_code text unique,
 owner_id uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz default now()
);
create table if not exists public.chat_members (
 chat_id uuid not null references public.chats(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 role text not null default 'member' check(role in ('owner','admin','member')),
 permissions jsonb not null default '{}'::jsonb,
 muted_until timestamptz,
 joined_at timestamptz default now(),
 primary key(chat_id,user_id)
);
create table if not exists public.messages (
 id uuid primary key default gen_random_uuid(),
 chat_id uuid not null references public.chats(id) on delete cascade,
 sender_id uuid not null references auth.users(id) on delete cascade,
 content text not null default '',
 attachment_url text,
 attachment_name text,
 attachment_type text,
 reply_to_id uuid references public.messages(id) on delete set null,
 created_at timestamptz default now(),
 edited_at timestamptz
);
create table if not exists public.chat_bans (
 id uuid primary key default gen_random_uuid(),
 chat_id uuid not null references public.chats(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 banned_by uuid references auth.users(id) on delete set null,
 reason text,
 created_at timestamptz default now(),
 unique(chat_id,user_id)
);
create table if not exists public.pinned_messages (
 chat_id uuid primary key references public.chats(id) on delete cascade,
 message_id uuid not null references public.messages(id) on delete cascade,
 pinned_by uuid references auth.users(id) on delete set null,
 pinned_at timestamptz default now()
);
create table if not exists public.devices (
 id text primary key,
 user_id uuid not null references auth.users(id) on delete cascade,
 name text,
 user_agent text,
 last_seen timestamptz default now(),
 created_at timestamptz default now()
);

-- Upgrade old tables BEFORE functions reference the columns.
alter table public.chat_members add column if not exists permissions jsonb not null default '{}'::jsonb;
alter table public.chat_members add column if not exists muted_until timestamptz;
alter table public.messages add column if not exists attachment_url text;
alter table public.messages add column if not exists attachment_name text;
alter table public.messages add column if not exists attachment_type text;
alter table public.messages add column if not exists reply_to_id uuid references public.messages(id) on delete set null;
alter table public.messages add column if not exists edited_at timestamptz;
alter table public.chats add column if not exists description text;
alter table public.chats add column if not exists avatar_url text;
alter table public.chats add column if not exists invite_code text;
alter table public.profiles add column if not exists username text;
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists bio text;

-- Remove incompatible legacy return signatures before recreating the helper.
drop function if exists public.get_my_devices();

-- Devices compatibility upgrade. This keeps both fresh installs and older EMCHAT databases working.
alter table public.devices add column if not exists name text;
alter table public.devices add column if not exists device_name text;
alter table public.devices add column if not exists device_type text;
alter table public.devices add column if not exists last_seen timestamptz default now();
alter table public.devices add column if not exists last_seen_at timestamptz;
alter table public.devices add column if not exists is_current boolean not null default false;
update public.devices set name=coalesce(name,device_name,'Устройство') where name is null;
update public.devices set last_seen=coalesce(last_seen,last_seen_at,created_at,now()) where last_seen is null;

create or replace function public.get_my_devices()
returns table(id text, user_id uuid, name text, device_type text, user_agent text, last_seen timestamptz, created_at timestamptz, is_current boolean)
language sql stable security definer set search_path=public as $$
 select d.id::text,d.user_id,coalesce(d.name,d.device_name,'Устройство'),d.device_type,d.user_agent,
        coalesce(d.last_seen,d.last_seen_at,d.created_at),d.created_at,d.is_current
 from public.devices d where d.user_id=auth.uid()
 order by coalesce(d.is_current,false) desc,coalesce(d.last_seen,d.last_seen_at,d.created_at) desc
$$;

grant execute on function public.get_my_devices() to authenticated;

create unique index if not exists chats_invite_code_unique on public.chats(invite_code) where invite_code is not null;
create index if not exists messages_chat_created_idx on public.messages(chat_id,created_at);
create index if not exists members_user_idx on public.chat_members(user_id);
create index if not exists bans_chat_user_idx on public.chat_bans(chat_id,user_id);
create index if not exists devices_user_idx on public.devices(user_id);

-- Automatically create a profile for newly registered users.
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
 insert into public.profiles(id,display_name) values(new.id,coalesce(new.raw_user_meta_data->>'display_name',split_part(new.email,'@',1),'Пользователь')) on conflict(id) do nothing;
 return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

create or replace function public.is_chat_member(p_chat_id uuid,p_user_id uuid default auth.uid()) returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.chat_members where chat_id=p_chat_id and user_id=p_user_id)
$$;
create or replace function public.has_chat_permission(p_chat_id uuid,p_permission text,p_user_id uuid default auth.uid()) returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.chat_members m where m.chat_id=p_chat_id and m.user_id=p_user_id and (m.role='owner' or (m.role='admin' and coalesce((m.permissions->>p_permission)::boolean,false))))
$$;

create or replace function public.get_my_chats() returns setof public.chats language sql stable security definer set search_path=public as $$
 select c.* from public.chats c join public.chat_members m on m.chat_id=c.id where m.user_id=auth.uid() order by c.created_at desc
$$;

create or replace function public.create_chat_full(p_kind text,p_title text,p_description text default '') returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_code text;
begin
 if auth.uid() is null then raise exception 'Not authenticated'; end if;
 if p_kind not in ('group','channel') then raise exception 'Invalid chat type'; end if;
 if coalesce(trim(p_title),'')='' then raise exception 'Название обязательно'; end if;
 v_code:=substr(replace(gen_random_uuid()::text,'-',''),1,16);
 insert into public.chats(kind,title,description,owner_id,invite_code) values(p_kind,trim(p_title),coalesce(p_description,''),auth.uid(),v_code) returning id into v_id;
 insert into public.chat_members(chat_id,user_id,role,permissions) values(v_id,auth.uid(),'owner','{"send_messages":true,"invite":true,"pin":true,"kick":true,"ban":true,"unban":true,"mute":true,"edit_chat":true}'::jsonb);
 return v_id;
end $$;

create or replace function public.create_direct_chat(p_username text) returns uuid language plpgsql security definer set search_path=public as $$
declare v_other uuid; v_id uuid;
begin
 select id into v_other from public.profiles where lower(username)=lower(trim(p_username)) limit 1;
 if v_other is null then raise exception 'Пользователь не найден'; end if;
 if v_other=auth.uid() then raise exception 'Нельзя создать ЛС с собой'; end if;
 select c.id into v_id from public.chats c where c.kind='dm' and exists(select 1 from public.chat_members a where a.chat_id=c.id and a.user_id=auth.uid()) and exists(select 1 from public.chat_members b where b.chat_id=c.id and b.user_id=v_other) limit 1;
 if v_id is not null then return v_id; end if;
 insert into public.chats(kind,title,owner_id) values('dm','Диалог',auth.uid()) returning id into v_id;
 insert into public.chat_members(chat_id,user_id,role,permissions) values(v_id,auth.uid(),'owner','{}'::jsonb),(v_id,v_other,'member','{}'::jsonb);
 return v_id;
end $$;

create or replace function public.add_member_by_username(p_chat_id uuid,p_username text) returns void language plpgsql security definer set search_path=public as $$
declare v_user uuid;
begin
 if not public.has_chat_permission(p_chat_id,'invite') then raise exception 'Нет права приглашать'; end if;
 select id into v_user from public.profiles where lower(username)=lower(trim(p_username)) limit 1;
 if v_user is null then raise exception 'Пользователь не найден'; end if;
 if exists(select 1 from public.chat_bans where chat_id=p_chat_id and user_id=v_user) then raise exception 'Пользователь забанен'; end if;
 insert into public.chat_members(chat_id,user_id) values(p_chat_id,v_user) on conflict do nothing;
end $$;

create or replace function public.join_chat_by_invite(p_code text) returns uuid language plpgsql security definer set search_path=public as $$
declare v_chat uuid;
begin
 select id into v_chat from public.chats where invite_code=p_code and kind in ('group','channel') limit 1;
 if v_chat is null then raise exception 'Приглашение недействительно'; end if;
 if exists(select 1 from public.chat_bans where chat_id=v_chat and user_id=auth.uid()) then raise exception 'Вы заблокированы в этом чате'; end if;
 insert into public.chat_members(chat_id,user_id) values(v_chat,auth.uid()) on conflict do nothing;
 return v_chat;
end $$;

create or replace function public.kick_chat_member(p_chat_id uuid,p_user_id uuid) returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.has_chat_permission(p_chat_id,'kick') then raise exception 'Нет права исключать'; end if;
 if (select owner_id from public.chats where id=p_chat_id)=p_user_id then raise exception 'Нельзя исключить владельца'; end if;
 delete from public.chat_members where chat_id=p_chat_id and user_id=p_user_id;
end $$;

create or replace function public.ban_chat_member(p_chat_id uuid,p_user_id uuid,p_reason text default null) returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.has_chat_permission(p_chat_id,'ban') then raise exception 'Нет права банить'; end if;
 if (select owner_id from public.chats where id=p_chat_id)=p_user_id then raise exception 'Нельзя забанить владельца'; end if;
 insert into public.chat_bans(chat_id,user_id,banned_by,reason) values(p_chat_id,p_user_id,auth.uid(),p_reason) on conflict(chat_id,user_id) do update set banned_by=excluded.banned_by,reason=excluded.reason;
 delete from public.chat_members where chat_id=p_chat_id and user_id=p_user_id;
end $$;

create or replace function public.unban_chat_member(p_chat_id uuid,p_user_id uuid) returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.has_chat_permission(p_chat_id,'unban') and not public.has_chat_permission(p_chat_id,'ban') then raise exception 'Нет права разбанивать'; end if;
 delete from public.chat_bans where chat_id=p_chat_id and user_id=p_user_id;
end $$;

create or replace function public.get_chat_bans(p_chat_id uuid) returns table(user_id uuid,display_name text,username text,avatar_url text,reason text,created_at timestamptz) language sql stable security definer set search_path=public as $$
 select b.user_id,p.display_name,p.username,p.avatar_url,b.reason,b.created_at from public.chat_bans b left join public.profiles p on p.id=b.user_id where b.chat_id=p_chat_id and public.has_chat_permission(p_chat_id,'ban') order by b.created_at desc
$$;

create or replace function public.mute_chat_member(p_chat_id uuid,p_user_id uuid,p_minutes integer) returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.has_chat_permission(p_chat_id,'mute') then raise exception 'Нет права мутить'; end if;
 if p_minutes<1 or p_minutes>525600 then raise exception 'Неверное время мута'; end if;
 update public.chat_members set muted_until=now()+make_interval(mins=>p_minutes) where chat_id=p_chat_id and user_id=p_user_id and role<>'owner';
end $$;

create or replace function public.set_chat_member_role(p_chat_id uuid,p_user_id uuid,p_role text,p_permissions jsonb default '{}'::jsonb) returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.has_chat_permission(p_chat_id,'edit_chat') then raise exception 'Нет права управлять администраторами'; end if;
 if p_role not in ('admin','member') then raise exception 'Недопустимая роль'; end if;
 if (select owner_id from public.chats where id=p_chat_id)=p_user_id then raise exception 'Нельзя изменить владельца'; end if;
 update public.chat_members set role=p_role,permissions=coalesce(p_permissions,'{}'::jsonb) where chat_id=p_chat_id and user_id=p_user_id;
end $$;

create or replace function public.transfer_chat_owner(p_chat_id uuid,p_new_owner uuid) returns void language plpgsql security definer set search_path=public as $$
declare v_old uuid;
begin
 select owner_id into v_old from public.chats where id=p_chat_id;
 if v_old is distinct from auth.uid() then raise exception 'Только владелец может передать чат'; end if;
 if not exists(select 1 from public.chat_members where chat_id=p_chat_id and user_id=p_new_owner) then raise exception 'Новый владелец должен быть участником'; end if;
 update public.chats set owner_id=p_new_owner where id=p_chat_id;
 update public.chat_members set role='admin',permissions='{"send_messages":true,"invite":true,"pin":true,"kick":true,"ban":true,"unban":true,"mute":true,"edit_chat":true}'::jsonb where chat_id=p_chat_id and user_id=v_old;
 update public.chat_members set role='owner',permissions='{"send_messages":true,"invite":true,"pin":true,"kick":true,"ban":true,"unban":true,"mute":true,"edit_chat":true}'::jsonb where chat_id=p_chat_id and user_id=p_new_owner;
end $$;

create or replace function public.pin_chat_message(p_chat_id uuid,p_message_id uuid) returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.has_chat_permission(p_chat_id,'pin') then raise exception 'Нет права закреплять'; end if;
 if not exists(select 1 from public.messages where id=p_message_id and chat_id=p_chat_id) then raise exception 'Сообщение не найдено'; end if;
 insert into public.pinned_messages(chat_id,message_id,pinned_by) values(p_chat_id,p_message_id,auth.uid()) on conflict(chat_id) do update set message_id=excluded.message_id,pinned_by=excluded.pinned_by,pinned_at=now();
end $$;
create or replace function public.unpin_chat_message(p_chat_id uuid) returns void language plpgsql security definer set search_path=public as $$
begin if not public.has_chat_permission(p_chat_id,'pin') then raise exception 'Нет права откреплять'; end if; delete from public.pinned_messages where chat_id=p_chat_id; end $$;

-- RLS
alter table public.profiles enable row level security;
alter table public.chats enable row level security;
alter table public.chat_members enable row level security;
alter table public.messages enable row level security;
alter table public.chat_bans enable row level security;
alter table public.pinned_messages enable row level security;
alter table public.devices enable row level security;

drop policy if exists profiles_read on public.profiles; create policy profiles_read on public.profiles for select to authenticated using(true);
drop policy if exists profiles_own on public.profiles; create policy profiles_own on public.profiles for insert to authenticated with check(id=auth.uid());
drop policy if exists profiles_update_own on public.profiles; create policy profiles_update_own on public.profiles for update to authenticated using(id=auth.uid()) with check(id=auth.uid());
drop policy if exists chats_read on public.chats; create policy chats_read on public.chats for select to authenticated using(public.is_chat_member(id));
drop policy if exists chats_update on public.chats; create policy chats_update on public.chats for update to authenticated using(public.has_chat_permission(id,'edit_chat')) with check(public.has_chat_permission(id,'edit_chat'));
drop policy if exists members_read on public.chat_members; create policy members_read on public.chat_members for select to authenticated using(public.is_chat_member(chat_id));
drop policy if exists messages_read on public.messages; create policy messages_read on public.messages for select to authenticated using(public.is_chat_member(chat_id));
drop policy if exists messages_insert on public.messages; create policy messages_insert on public.messages for insert to authenticated with check(sender_id=auth.uid() and public.is_chat_member(chat_id) and not exists(select 1 from public.chat_members m where m.chat_id=messages.chat_id and m.user_id=auth.uid() and m.muted_until>now()) and not exists(select 1 from public.chats c where c.id=messages.chat_id and c.kind='channel' and not public.has_chat_permission(messages.chat_id,'send_messages')));
drop policy if exists messages_update_own on public.messages; create policy messages_update_own on public.messages for update to authenticated using(sender_id=auth.uid()) with check(sender_id=auth.uid());
drop policy if exists messages_delete on public.messages; create policy messages_delete on public.messages for delete to authenticated using(sender_id=auth.uid() or public.has_chat_permission(chat_id,'pin'));
drop policy if exists pinned_read on public.pinned_messages; create policy pinned_read on public.pinned_messages for select to authenticated using(public.is_chat_member(chat_id));
drop policy if exists devices_own on public.devices; create policy devices_own on public.devices for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());

grant execute on function public.get_my_chats() to authenticated;
grant execute on function public.create_chat_full(text,text,text) to authenticated;
grant execute on function public.create_direct_chat(text) to authenticated;
grant execute on function public.add_member_by_username(uuid,text) to authenticated;
grant execute on function public.join_chat_by_invite(text) to authenticated;
grant execute on function public.kick_chat_member(uuid,uuid) to authenticated;
grant execute on function public.ban_chat_member(uuid,uuid,text) to authenticated;
grant execute on function public.unban_chat_member(uuid,uuid) to authenticated;
grant execute on function public.get_chat_bans(uuid) to authenticated;
grant execute on function public.mute_chat_member(uuid,uuid,integer) to authenticated;
grant execute on function public.set_chat_member_role(uuid,uuid,text,jsonb) to authenticated;
grant execute on function public.transfer_chat_owner(uuid,uuid) to authenticated;
grant execute on function public.pin_chat_message(uuid,uuid) to authenticated;
grant execute on function public.unpin_chat_message(uuid) to authenticated;

do $$ begin alter publication supabase_realtime add table public.messages; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.chat_members; exception when duplicate_object then null; end $$;
