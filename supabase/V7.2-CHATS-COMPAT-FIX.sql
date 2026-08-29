-- EMCHAT V7.2 FINAL COMPATIBILITY FIX
-- Fixes: column "kind" of relation "chats" does not exist
-- Safe to run on an existing EMCHAT database. Does not delete chats or users.

create extension if not exists pgcrypto;

-- 1) Bring legacy chats table to the schema expected by EMCHAT V7.
alter table public.chats add column if not exists kind text;
alter table public.chats add column if not exists title text;
alter table public.chats add column if not exists description text;
alter table public.chats add column if not exists avatar_url text;
alter table public.chats add column if not exists invite_code text;
alter table public.chats add column if not exists owner_id uuid;
alter table public.chats add column if not exists created_at timestamptz default now();

-- If an older database used a different type column, copy it when available.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='chats' and column_name='type'
  ) then
    execute $$update public.chats set kind=coalesce(kind, type::text) where kind is null$$;
  end if;
end $$;

update public.chats
set kind='group'
where kind is null or kind not in ('dm','group','channel');

alter table public.chats alter column kind set default 'group';

-- 2) Make legacy member/profile tables compatible with the RPCs.
alter table public.chat_members add column if not exists role text default 'member';
alter table public.chat_members add column if not exists permissions jsonb not null default '{}'::jsonb;
alter table public.chat_members add column if not exists muted_until timestamptz;
alter table public.chat_members add column if not exists joined_at timestamptz default now();

alter table public.profiles add column if not exists username text;
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists bio text;
update public.profiles set display_name=coalesce(display_name,username,'Пользователь') where display_name is null;

create unique index if not exists chats_invite_code_unique
  on public.chats(invite_code) where invite_code is not null;

-- 3) Recreate chat creation RPC with a fresh signature and no stale cache dependency.
drop function if exists public.create_chat_v7(text,text,text);
create function public.create_chat_v7(
  p_kind text,
  p_title text,
  p_description text default ''
) returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  v_id uuid;
  v_code text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if p_kind not in ('group','channel') then
    raise exception 'Invalid chat type';
  end if;

  if coalesce(trim(p_title),'')='' then
    raise exception 'Название обязательно';
  end if;

  v_code := substr(replace(gen_random_uuid()::text,'-',''),1,16);

  insert into public.chats(kind,title,description,owner_id,invite_code)
  values(p_kind,trim(p_title),coalesce(p_description,''),auth.uid(),v_code)
  returning id into v_id;

  insert into public.chat_members(chat_id,user_id,role,permissions)
  values(
    v_id,
    auth.uid(),
    'owner',
    '{"send_messages":true,"invite":true,"pin":true,"kick":true,"ban":true,"unban":true,"mute":true,"edit_chat":true}'::jsonb
  )
  on conflict(chat_id,user_id) do update
    set role='owner', permissions=excluded.permissions;

  return v_id;
end;
$$;

grant execute on function public.create_chat_v7(text,text,text) to authenticated;

-- 4) Keep direct messages compatible too.
drop function if exists public.create_direct_chat(text);
create function public.create_direct_chat(p_username text)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare v_other uuid; v_id uuid;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  select id into v_other
  from public.profiles
  where lower(coalesce(username,''))=lower(trim(replace(p_username,'@','')))
  limit 1;
  if v_other is null then raise exception 'Пользователь не найден'; end if;
  if v_other=auth.uid() then raise exception 'Нельзя создать ЛС с собой'; end if;

  select c.id into v_id
  from public.chats c
  where c.kind='dm'
    and exists(select 1 from public.chat_members a where a.chat_id=c.id and a.user_id=auth.uid())
    and exists(select 1 from public.chat_members b where b.chat_id=c.id and b.user_id=v_other)
  limit 1;
  if v_id is not null then return v_id; end if;

  insert into public.chats(kind,title,owner_id)
  values('dm','Диалог',auth.uid())
  returning id into v_id;

  insert into public.chat_members(chat_id,user_id,role,permissions)
  values(v_id,auth.uid(),'owner','{}'::jsonb),(v_id,v_other,'member','{}'::jsonb)
  on conflict(chat_id,user_id) do nothing;

  return v_id;
end;
$$;
grant execute on function public.create_direct_chat(text) to authenticated;

-- Reload PostgREST metadata so the new columns/RPCs are visible immediately.
notify pgrst, 'reload schema';
