-- EMCHAT V7.4 FINAL: fixes sending, presence/online, devices and compatibility.
-- Safe additive migration for an existing project.
create extension if not exists pgcrypto;

-- Required compatibility columns.
alter table public.profiles add column if not exists last_seen timestamptz;
alter table public.chats add column if not exists kind text;
alter table public.chats add column if not exists title text;
alter table public.chats add column if not exists description text;
alter table public.chats add column if not exists avatar_url text;
alter table public.chats add column if not exists invite_code text;
alter table public.chats add column if not exists owner_id uuid;
alter table public.chat_members add column if not exists role text default 'member';
alter table public.chat_members add column if not exists permissions jsonb not null default '{}'::jsonb;
alter table public.chat_members add column if not exists muted_until timestamptz;
alter table public.chat_members add column if not exists joined_at timestamptz default now();
alter table public.devices add column if not exists name text;
alter table public.devices add column if not exists device_type text;
alter table public.devices add column if not exists user_agent text;
alter table public.devices add column if not exists last_seen timestamptz default now();
alter table public.devices add column if not exists is_current boolean default false;

-- One stable RPC for sending messages. The client falls back to insert only if needed.
drop function if exists public.send_chat_message(uuid,text,uuid,text,text,text);
create function public.send_chat_message(
  p_chat_id uuid,
  p_content text default '',
  p_reply_to_id uuid default null,
  p_attachment_url text default null,
  p_attachment_name text default null,
  p_attachment_type text default null
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare v_id uuid; v_muted timestamptz;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  select muted_until into v_muted from public.chat_members
    where chat_id=p_chat_id and user_id=auth.uid();
  if not found then raise exception 'Вы не состоите в этом чате'; end if;
  if v_muted is not null and v_muted>now() then raise exception 'Вы временно не можете отправлять сообщения'; end if;
  if coalesce(trim(p_content),'')='' and p_attachment_url is null then raise exception 'Сообщение пустое'; end if;
  insert into public.messages(chat_id,sender_id,content,reply_to_id,attachment_url,attachment_name,attachment_type)
  values(p_chat_id,auth.uid(),coalesce(trim(p_content),''),p_reply_to_id,p_attachment_url,p_attachment_name,p_attachment_type)
  returning id into v_id;
  update public.profiles set last_seen=now() where id=auth.uid();
  return v_id;
end;
$$;
grant execute on function public.send_chat_message(uuid,text,uuid,text,text,text) to authenticated;

-- Devices: stable listing and kick RPCs.
drop function if exists public.get_my_devices();
create function public.get_my_devices()
returns table(id uuid,user_id uuid,name text,device_name text,device_type text,user_agent text,last_seen timestamptz,last_seen_at timestamptz,created_at timestamptz,is_current boolean)
language sql stable security definer set search_path=public as $$
  select d.id,d.user_id,d.name,
         case when exists(select 1 from information_schema.columns where table_schema='public' and table_name='devices' and column_name='device_name') then null::text else null::text end,
         d.device_type,d.user_agent,d.last_seen,null::timestamptz,d.created_at,d.is_current
  from public.devices d where d.user_id=auth.uid()
  order by d.last_seen desc nulls last,d.created_at desc;
$$;
grant execute on function public.get_my_devices() to authenticated;

drop function if exists public.kick_my_device(uuid);
create function public.kick_my_device(p_device_id uuid) returns void
language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null then raise exception 'Not authenticated'; end if;
 delete from public.devices where id=p_device_id and user_id=auth.uid();
 if not found then raise exception 'Устройство не найдено'; end if;
end;
$$;
grant execute on function public.kick_my_device(uuid) to authenticated;

-- Presence helper (online = seen during last 45 seconds).
drop function if exists public.touch_presence();
create function public.touch_presence() returns timestamptz
language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null then raise exception 'Not authenticated'; end if;
 update public.profiles set last_seen=now() where id=auth.uid();
 return now();
end;
$$;
grant execute on function public.touch_presence() to authenticated;

-- Reload PostgREST schema cache.
notify pgrst, 'reload schema';
