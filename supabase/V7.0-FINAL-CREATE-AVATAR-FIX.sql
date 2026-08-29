-- EMCHAT V7 FINAL: fix channel/group creation and avatars
-- Run this whole file once in Supabase SQL Editor.

alter table public.profiles add column if not exists avatar_url text;
alter table public.chats add column if not exists avatar_url text;
alter table public.chats add column if not exists description text;

create or replace function public.create_chat_v7(p_kind text,p_title text,p_description text default '') returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_code text;
begin
 if auth.uid() is null then raise exception 'Not authenticated'; end if;
 if p_kind not in ('group','channel') then raise exception 'Invalid chat type'; end if;
 if coalesce(trim(p_title),'')='' then raise exception 'Название обязательно'; end if;
 v_code:=substr(replace(gen_random_uuid()::text,'-',''),1,16);
 insert into public.chats(kind,title,description,owner_id,invite_code)
 values(p_kind,trim(p_title),coalesce(p_description,''),auth.uid(),v_code) returning id into v_id;
 insert into public.chat_members(chat_id,user_id,role,permissions)
 values(v_id,auth.uid(),'owner','{"send_messages":true,"invite":true,"pin":true,"kick":true,"ban":true,"unban":true,"mute":true,"edit_chat":true}'::jsonb);
 return v_id;
end $$;

grant execute on function public.create_chat_v7(text,text,text) to authenticated;

-- Ask PostgREST to reload RPC metadata immediately.
notify pgrst, 'reload schema';

-- V7.1 DEVICE KICK: remove a device belonging to the current user.
-- The kicked client detects the missing device row and signs out automatically.
drop function if exists public.kick_my_device(text);
create or replace function public.kick_my_device(p_device_id text)
returns boolean
language plpgsql security definer set search_path=public as $$
begin
  if p_device_id is null or length(trim(p_device_id))=0 then
    raise exception 'device id is required';
  end if;
  delete from public.devices
  where id=p_device_id and user_id=auth.uid();
  if not found then
    raise exception 'Устройство не найдено или уже отключено';
  end if;
  return true;
end;
$$;
grant execute on function public.kick_my_device(text) to authenticated;
notify pgrst, 'reload schema';
