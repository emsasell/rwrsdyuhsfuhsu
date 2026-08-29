create extension if not exists pgcrypto;

create table if not exists public.profiles(
 id uuid primary key references auth.users(id) on delete cascade,
 username text unique not null check(length(username)>=2),
 display_name text,
 bio text,
 avatar_url text,
 created_at timestamptz default now()
);
create table if not exists public.chats(
 id uuid primary key default gen_random_uuid(),
 name text,
 description text,
 kind text not null default 'group' check(kind in ('direct','group','channel')),
 created_by uuid not null references auth.users(id) on delete cascade,
 avatar_url text,
 created_at timestamptz default now()
);
create table if not exists public.chat_members(
 chat_id uuid references public.chats(id) on delete cascade,
 user_id uuid references auth.users(id) on delete cascade,
 role text not null default 'member' check(role in ('owner','admin','member')),
 muted_until timestamptz,
 joined_at timestamptz default now(),
 primary key(chat_id,user_id)
);
alter table public.chat_members add column if not exists muted_until timestamptz;

create table if not exists public.chat_bans(
 chat_id uuid references public.chats(id) on delete cascade,
 user_id uuid references auth.users(id) on delete cascade,
 banned_by uuid references auth.users(id) on delete set null,
 reason text,
 created_at timestamptz default now(),
 primary key(chat_id,user_id)
);

create table if not exists public.messages(
 id uuid primary key default gen_random_uuid(),
 chat_id uuid not null references public.chats(id) on delete cascade,
 sender_id uuid not null references auth.users(id) on delete cascade,
 content text,
 attachment_url text,
 attachment_name text,
 attachment_type text,
 edited_at timestamptz,
 created_at timestamptz default now(),
 check(content is not null or attachment_url is not null)
);
create table if not exists public.invites(
 code text primary key,
 chat_id uuid not null references public.chats(id) on delete cascade,
 created_by uuid not null references auth.users(id) on delete cascade,
 expires_at timestamptz,
 max_uses integer,
 uses integer not null default 0,
 created_at timestamptz default now()
);
create table if not exists public.devices(
 id uuid primary key,
 user_id uuid not null references auth.users(id) on delete cascade,
 name text not null,
 user_agent text,
 last_seen_at timestamptz default now(),
 created_at timestamptz default now()
);

alter table public.profiles enable row level security;
alter table public.chats enable row level security;
alter table public.chat_members enable row level security;
alter table public.chat_bans enable row level security;
alter table public.messages enable row level security;
alter table public.invites enable row level security;
alter table public.devices enable row level security;

drop policy if exists "profiles readable" on public.profiles;
create policy "profiles readable" on public.profiles for select to authenticated using(true);
drop policy if exists "profile own update" on public.profiles;
create policy "profile own update" on public.profiles for update to authenticated using(auth.uid()=id) with check(auth.uid()=id);
drop policy if exists "profile own insert" on public.profiles;
create policy "profile own insert" on public.profiles for insert to authenticated with check(auth.uid()=id);

drop policy if exists "members read own" on public.chat_members;
drop policy if exists "members read chat" on public.chat_members;
create policy "members read chat" on public.chat_members for select to authenticated using(
 exists(select 1 from public.chat_members mine where mine.chat_id=chat_members.chat_id and mine.user_id=auth.uid())
);
drop policy if exists "members insert own new chat" on public.chat_members;
create policy "members insert own new chat" on public.chat_members for insert to authenticated with check(user_id=auth.uid());

drop policy if exists "chats members read" on public.chats;
create policy "chats members read" on public.chats for select to authenticated using(exists(select 1 from public.chat_members m where m.chat_id=id and m.user_id=auth.uid()));
drop policy if exists "chats create own" on public.chats;
create policy "chats create own" on public.chats for insert to authenticated with check(created_by=auth.uid());

drop policy if exists "messages read member" on public.messages;
create policy "messages read member" on public.messages for select to authenticated using(exists(select 1 from public.chat_members m where m.chat_id=messages.chat_id and m.user_id=auth.uid()));
drop policy if exists "messages insert member" on public.messages;
create policy "messages insert member" on public.messages for insert to authenticated with check(
 sender_id=auth.uid()
 and exists(select 1 from public.chat_members m where m.chat_id=messages.chat_id and m.user_id=auth.uid() and (m.muted_until is null or m.muted_until <= now()))
 and not exists(select 1 from public.chat_bans b where b.chat_id=messages.chat_id and b.user_id=auth.uid())
);
drop policy if exists "messages update own" on public.messages;
create policy "messages update own" on public.messages for update to authenticated using(sender_id=auth.uid()) with check(sender_id=auth.uid());
drop policy if exists "messages delete own" on public.messages;
create policy "messages delete own" on public.messages for delete to authenticated using(sender_id=auth.uid());

drop policy if exists "invites read member" on public.invites;
create policy "invites read member" on public.invites for select to authenticated using(exists(select 1 from public.chat_members m where m.chat_id=invites.chat_id and m.user_id=auth.uid()));
drop policy if exists "devices own" on public.devices;
create policy "devices own" on public.devices for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists "bans no direct access" on public.chat_bans;
create policy "bans no direct access" on public.chat_bans for select to authenticated using(false);

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
 insert into public.profiles(id,username,display_name)
 values(new.id,coalesce(new.raw_user_meta_data->>'username',split_part(new.email,'@',1)),coalesce(new.raw_user_meta_data->>'username',split_part(new.email,'@',1)))
 on conflict(id) do nothing;
 return new;
end;$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

create or replace function public.get_or_create_direct(other_user uuid) returns uuid language plpgsql security definer set search_path=public as $$
declare cid uuid; begin
 select c.id into cid from chats c where c.kind='direct'
 and exists(select 1 from chat_members a where a.chat_id=c.id and a.user_id=auth.uid())
 and exists(select 1 from chat_members b where b.chat_id=c.id and b.user_id=other_user) limit 1;
 if cid is null then
  insert into chats(name,kind,created_by) values(null,'direct',auth.uid()) returning id into cid;
  insert into chat_members(chat_id,user_id,role) values(cid,auth.uid(),'owner'),(cid,other_user,'member');
 end if; return cid;
end;$$;

create or replace function public.create_invite(target_chat uuid) returns text language plpgsql security definer set search_path=public as $$
declare c text; begin
 if not exists(select 1 from chat_members where chat_id=target_chat and user_id=auth.uid() and role in ('owner','admin')) then raise exception 'Нет прав на приглашение'; end if;
 c:=encode(gen_random_bytes(9),'hex');
 insert into invites(code,chat_id,created_by) values(c,target_chat,auth.uid()); return c;
end;$$;

create or replace function public.join_by_invite(invite_code text) returns uuid language plpgsql security definer set search_path=public as $$
declare i invites%rowtype; begin
 select * into i from invites where code=invite_code for update;
 if not found then raise exception 'Приглашение не найдено'; end if;
 if exists(select 1 from chat_bans b where b.chat_id=i.chat_id and b.user_id=auth.uid()) then raise exception 'Вы заблокированы в этом чате'; end if;
 if i.expires_at is not null and i.expires_at<now() then raise exception 'Ссылка истекла'; end if;
 if i.max_uses is not null and i.uses>=i.max_uses then raise exception 'Лимит приглашения исчерпан'; end if;
 insert into chat_members(chat_id,user_id) values(i.chat_id,auth.uid()) on conflict do nothing;
 update invites set uses=uses+1 where code=i.code; return i.chat_id;
end;$$;

-- Изменение аватара, названия и описания группы/канала.
create or replace function public.update_chat_info(target_chat uuid, new_name text, new_description text, new_avatar_url text)
returns void language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from chat_members where chat_id=target_chat and user_id=auth.uid() and role in ('owner','admin')) then
  raise exception 'Нет прав администратора';
 end if;
 update chats set name=coalesce(new_name,name), description=new_description, avatar_url=new_avatar_url where id=target_chat and kind in ('group','channel');
end;$$;

-- kick | ban | unban | mute | unmute | admin | member
create or replace function public.moderate_chat_member(target_chat uuid, target_user uuid, action text, mute_minutes integer default 60)
returns void language plpgsql security definer set search_path=public as $$
declare my_role text; target_role text;
begin
 select role into my_role from chat_members where chat_id=target_chat and user_id=auth.uid();
 if my_role not in ('owner','admin') then raise exception 'Нет прав администратора'; end if;
 select role into target_role from chat_members where chat_id=target_chat and user_id=target_user;
 if target_role='owner' and my_role<>'owner' then raise exception 'Нельзя управлять владельцем'; end if;
 if target_role='admin' and my_role<>'owner' then raise exception 'Только владелец может управлять администратором'; end if;

 case action
 when 'kick' then delete from chat_members where chat_id=target_chat and user_id=target_user and role<>'owner';
 when 'ban' then
   delete from chat_members where chat_id=target_chat and user_id=target_user and role<>'owner';
   insert into chat_bans(chat_id,user_id,banned_by) values(target_chat,target_user,auth.uid()) on conflict(chat_id,user_id) do update set banned_by=auth.uid(),created_at=now();
 when 'unban' then
   if my_role<>'owner' then raise exception 'Разбанивать может владелец'; end if;
   delete from chat_bans where chat_id=target_chat and user_id=target_user;
 when 'mute' then update chat_members set muted_until=now()+make_interval(mins=>greatest(1,coalesce(mute_minutes,60))) where chat_id=target_chat and user_id=target_user and role<>'owner';
 when 'unmute' then update chat_members set muted_until=null where chat_id=target_chat and user_id=target_user;
 when 'admin' then
   if my_role<>'owner' then raise exception 'Назначать администраторов может владелец'; end if;
   update chat_members set role='admin' where chat_id=target_chat and user_id=target_user and role='member';
 when 'member' then
   if my_role<>'owner' then raise exception 'Снимать администратора может владелец'; end if;
   update chat_members set role='member' where chat_id=target_chat and user_id=target_user and role='admin';
 else raise exception 'Неизвестное действие';
 end case;
end;$$;

grant execute on function public.get_or_create_direct(uuid) to authenticated;
grant execute on function public.create_invite(uuid) to authenticated;
grant execute on function public.join_by_invite(text) to authenticated;
grant execute on function public.update_chat_info(uuid,text,text,text) to authenticated;
grant execute on function public.moderate_chat_member(uuid,uuid,text,integer) to authenticated;

do $$
begin
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='messages') then
  alter publication supabase_realtime add table public.messages;
 end if;
end $$;


-- ================= EMCHAT V4: granular admin permissions, pins, bans, owner transfer =================
alter table public.chat_members add column if not exists permissions jsonb not null default '[]'::jsonb;

create table if not exists public.pinned_messages(
 chat_id uuid primary key references public.chats(id) on delete cascade,
 message_id uuid not null references public.messages(id) on delete cascade,
 pinned_by uuid references auth.users(id) on delete set null,
 pinned_at timestamptz default now()
);
alter table public.pinned_messages enable row level security;
drop policy if exists "pins read member" on public.pinned_messages;
create policy "pins read member" on public.pinned_messages for select to authenticated using(exists(select 1 from public.chat_members m where m.chat_id=pinned_messages.chat_id and m.user_id=auth.uid()));

create or replace function public.has_chat_permission(target_chat uuid, perm text) returns boolean
language plpgsql security definer set search_path=public as $$
declare r text; perms jsonb;
begin
 select role,permissions into r,perms from public.chat_members where chat_id=target_chat and user_id=auth.uid();
 if r='owner' then return true; end if;
 if r<>'admin' then return false; end if;
 return coalesce(perms,'[]'::jsonb) ? perm;
end;$$;

-- Safe defaults for old administrators.
update public.chat_members set permissions='["manage_members","ban_members","mute_members","manage_info","invite_users","pin_messages","send_messages"]'::jsonb
where role='admin' and (permissions is null or permissions='[]'::jsonb);

create or replace function public.update_admin_permissions(target_chat uuid,target_user uuid,new_permissions jsonb)
returns void language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from public.chat_members where chat_id=target_chat and user_id=auth.uid() and role='owner') then raise exception 'Только владелец может менять права администратора'; end if;
 if not exists(select 1 from public.chat_members where chat_id=target_chat and user_id=target_user and role='admin') then raise exception 'Пользователь не является администратором'; end if;
 update public.chat_members set permissions=coalesce(new_permissions,'[]'::jsonb) where chat_id=target_chat and user_id=target_user;
end;$$;

create or replace function public.transfer_chat_owner(target_chat uuid,new_owner uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from public.chat_members where chat_id=target_chat and user_id=auth.uid() and role='owner') then raise exception 'Только текущий владелец может передать владение'; end if;
 if not exists(select 1 from public.chat_members where chat_id=target_chat and user_id=new_owner) then raise exception 'Новый владелец должен быть участником'; end if;
 if new_owner=auth.uid() then raise exception 'Это уже владелец'; end if;
 update public.chat_members set role='admin',permissions='["manage_members","ban_members","mute_members","manage_info","invite_users","pin_messages","send_messages"]'::jsonb where chat_id=target_chat and user_id=auth.uid();
 update public.chat_members set role='owner',permissions='[]'::jsonb where chat_id=target_chat and user_id=new_owner;
 update public.chats set created_by=new_owner where id=target_chat;
end;$$;

create or replace function public.pin_chat_message(target_chat uuid,target_message uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.has_chat_permission(target_chat,'pin_messages') then raise exception 'Нет права закреплять сообщения'; end if;
 if not exists(select 1 from public.messages where id=target_message and chat_id=target_chat) then raise exception 'Сообщение не найдено в этом чате'; end if;
 insert into public.pinned_messages(chat_id,message_id,pinned_by) values(target_chat,target_message,auth.uid())
 on conflict(chat_id) do update set message_id=excluded.message_id,pinned_by=auth.uid(),pinned_at=now();
end;$$;

create or replace function public.unpin_chat_message(target_chat uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.has_chat_permission(target_chat,'pin_messages') then raise exception 'Нет права откреплять сообщения'; end if;
 delete from public.pinned_messages where chat_id=target_chat;
end;$$;

create or replace function public.get_pinned_message(target_chat uuid)
returns table(id uuid,content text,attachment_url text,attachment_name text,sender_id uuid,created_at timestamptz,pinned_at timestamptz)
language sql security definer set search_path=public as $$
 select m.id,m.content,m.attachment_url,m.attachment_name,m.sender_id,m.created_at,p.pinned_at
 from public.pinned_messages p join public.messages m on m.id=p.message_id
 where p.chat_id=target_chat and exists(select 1 from public.chat_members cm where cm.chat_id=target_chat and cm.user_id=auth.uid());
$$;

create or replace function public.get_chat_bans(target_chat uuid)
returns table(user_id uuid,banned_by uuid,created_at timestamptz,username text,display_name text,avatar_url text)
language sql security definer set search_path=public as $$
 select b.user_id,b.banned_by,b.created_at,p.username,p.display_name,p.avatar_url
 from public.chat_bans b left join public.profiles p on p.id=b.user_id
 where b.chat_id=target_chat and public.has_chat_permission(target_chat,'ban_members');
$$;

-- Replace moderation with granular permissions.
create or replace function public.moderate_chat_member(target_chat uuid, target_user uuid, action text, mute_minutes integer default 60)
returns void language plpgsql security definer set search_path=public as $$
declare my_role text; target_role text;
begin
 select role into my_role from public.chat_members where chat_id=target_chat and user_id=auth.uid();
 if my_role is null then raise exception 'Вы не участник'; end if;
 select role into target_role from public.chat_members where chat_id=target_chat and user_id=target_user;
 if target_role='owner' then raise exception 'Нельзя управлять владельцем'; end if;
 if target_role='admin' and my_role<>'owner' then raise exception 'Администратор не может управлять другим администратором'; end if;
 case action
 when 'kick' then
   if not public.has_chat_permission(target_chat,'manage_members') then raise exception 'Нет права кикать участников'; end if;
   delete from public.chat_members where chat_id=target_chat and user_id=target_user and role<>'owner';
 when 'ban' then
   if not public.has_chat_permission(target_chat,'ban_members') then raise exception 'Нет права банить'; end if;
   delete from public.chat_members where chat_id=target_chat and user_id=target_user and role<>'owner';
   insert into public.chat_bans(chat_id,user_id,banned_by) values(target_chat,target_user,auth.uid()) on conflict(chat_id,user_id) do update set banned_by=auth.uid(),created_at=now();
 when 'unban' then
   if not public.has_chat_permission(target_chat,'ban_members') then raise exception 'Нет права разбанивать'; end if;
   delete from public.chat_bans where chat_id=target_chat and user_id=target_user;
 when 'mute' then
   if not public.has_chat_permission(target_chat,'mute_members') then raise exception 'Нет права мутить'; end if;
   update public.chat_members set muted_until=now()+make_interval(mins=>greatest(1,coalesce(mute_minutes,60))) where chat_id=target_chat and user_id=target_user and role<>'owner';
 when 'unmute' then
   if not public.has_chat_permission(target_chat,'mute_members') then raise exception 'Нет права размучивать'; end if;
   update public.chat_members set muted_until=null where chat_id=target_chat and user_id=target_user;
 when 'admin' then
   if my_role<>'owner' then raise exception 'Только владелец назначает администраторов'; end if;
   update public.chat_members set role='admin',permissions='["manage_members","ban_members","mute_members","manage_info","invite_users","pin_messages","send_messages"]'::jsonb where chat_id=target_chat and user_id=target_user and role='member';
 when 'member' then
   if my_role<>'owner' then raise exception 'Только владелец снимает администратора'; end if;
   update public.chat_members set role='member',permissions='[]'::jsonb where chat_id=target_chat and user_id=target_user and role='admin';
 else raise exception 'Неизвестное действие';
 end case;
end;$$;

create or replace function public.update_chat_info(target_chat uuid, new_name text, new_description text, new_avatar_url text)
returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.has_chat_permission(target_chat,'manage_info') then raise exception 'Нет права изменять информацию'; end if;
 update public.chats set name=coalesce(new_name,name),description=new_description,avatar_url=new_avatar_url where id=target_chat and kind in ('group','channel');
end;$$;

create or replace function public.create_invite(target_chat uuid) returns text language plpgsql security definer set search_path=public as $$
declare c text; begin
 if not public.has_chat_permission(target_chat,'invite_users') then raise exception 'Нет права создавать приглашения'; end if;
 c:=encode(gen_random_bytes(9),'hex'); insert into public.invites(code,chat_id,created_by) values(c,target_chat,auth.uid()); return c;
end;$$;

-- Enforce granular send permission for channels and muted members.
drop policy if exists "messages insert member" on public.messages;
create policy "messages insert member" on public.messages for insert to authenticated with check(
 sender_id=auth.uid()
 and exists(select 1 from public.chat_members m where m.chat_id=messages.chat_id and m.user_id=auth.uid() and (m.muted_until is null or m.muted_until<=now()))
 and not exists(select 1 from public.chat_bans b where b.chat_id=messages.chat_id and b.user_id=auth.uid())
 and (not exists(select 1 from public.chats c where c.id=messages.chat_id and c.kind='channel') or public.has_chat_permission(messages.chat_id,'send_messages'))
);

grant execute on function public.has_chat_permission(uuid,text) to authenticated;
grant execute on function public.update_admin_permissions(uuid,uuid,jsonb) to authenticated;
grant execute on function public.transfer_chat_owner(uuid,uuid) to authenticated;
grant execute on function public.pin_chat_message(uuid,uuid) to authenticated;
grant execute on function public.unpin_chat_message(uuid) to authenticated;
grant execute on function public.get_pinned_message(uuid) to authenticated;
grant execute on function public.get_chat_bans(uuid) to authenticated;
