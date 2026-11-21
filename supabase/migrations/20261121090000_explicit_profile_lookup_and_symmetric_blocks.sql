-- Remove overloaded PostgREST RPC names and enforce symmetric blocking.

drop function if exists public.search_profile_by_id(text);
drop function if exists public.search_profile_by_id(uuid);

create or replace function public.search_profile_by_friend_code(p_friend_code text)
returns table(id uuid,nickname text,friend_code text,avatar_url text)
language plpgsql stable security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null then raise exception '请先登录'; end if;
  if p_friend_code is null or trim(p_friend_code) !~ '^[0-9]{6,8}$' then
    raise exception '好友 ID 格式不正确';
  end if;
  return query
  select p.id,coalesce(p.nickname,'漂流者')::text,p.friend_code,p.avatar_url
  from public.profiles p
  where p.friend_code=trim(p_friend_code) and p.id<>auth.uid()
  limit 1;
end;
$function$;

create or replace function public.search_profile_by_uuid(p_user_id uuid)
returns table(id uuid,nickname text,friend_code text,avatar_url text)
language plpgsql stable security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null then raise exception '请先登录'; end if;
  if p_user_id is null or p_user_id=auth.uid() then return; end if;
  return query
  select p.id,coalesce(p.nickname,'漂流者')::text,p.friend_code,p.avatar_url
  from public.profiles p
  where p.id=p_user_id
    and not exists(
      select 1 from public.user_blocks b
      where (b.blocker_id=auth.uid() and b.blocked_id=p.id)
         or (b.blocker_id=p.id and b.blocked_id=auth.uid())
    )
  limit 1;
end;
$function$;

revoke all on function public.search_profile_by_friend_code(text) from public,anon;
grant execute on function public.search_profile_by_friend_code(text) to authenticated;
revoke all on function public.search_profile_by_uuid(uuid) from public,anon;
grant execute on function public.search_profile_by_uuid(uuid) to authenticated;

drop policy if exists "查看漂流瓶" on public.bottles;
create policy "查看漂流瓶" on public.bottles
for select to authenticated
using (
  user_id=auth.uid()
  or picked_up_by=auth.uid()
  or (
    is_public=true and status='floating'
    and not exists(
      select 1 from public.user_blocks b
      where (b.blocker_id=auth.uid() and b.blocked_id=bottles.user_id)
         or (b.blocker_id=bottles.user_id and b.blocked_id=auth.uid())
    )
  )
);

drop policy if exists "查看自己的消息" on public.messages;
create policy "查看自己的消息" on public.messages
for select to authenticated
using (
  (sender_id=auth.uid() or receiver_id=auth.uid())
  and not exists(
    select 1 from public.user_blocks b
    where (b.blocker_id=auth.uid() and b.blocked_id=
      case when sender_id=auth.uid() then receiver_id else sender_id end)
       or (b.blocked_id=auth.uid() and b.blocker_id=
      case when sender_id=auth.uid() then receiver_id else sender_id end)
  )
);

drop policy if exists "Users manage their own blocks" on public.user_blocks;
create policy "Users can view blocks involving themselves" on public.user_blocks
for select to authenticated
using(blocker_id=auth.uid() or blocked_id=auth.uid());
create policy "Users can create their own blocks" on public.user_blocks
for insert to authenticated
with check(blocker_id=auth.uid() and blocked_id<>auth.uid());
create policy "Users can remove their own blocks" on public.user_blocks
for delete to authenticated
using(blocker_id=auth.uid());

create or replace function public.block_user(p_user_id uuid)
returns void language plpgsql security definer
set search_path=pg_catalog,public
as $function$
declare uid uuid:=auth.uid();
begin
  if uid is null then raise exception '请先登录'; end if;
  if p_user_id is null or p_user_id=uid then raise exception '不能拉黑自己'; end if;
  if not exists(select 1 from public.profiles where id=p_user_id) then raise exception '用户不存在'; end if;
  insert into public.user_blocks(blocker_id,blocked_id)
  values(uid,p_user_id) on conflict(blocker_id,blocked_id) do nothing;
  delete from public.friend_requests
  where (sender_id=uid and receiver_id=p_user_id)
     or (sender_id=p_user_id and receiver_id=uid);
  delete from public.follows
  where (follower_id=uid and following_id=p_user_id)
     or (follower_id=p_user_id and following_id=uid);
end;
$function$;
revoke all on function public.block_user(uuid) from public,anon;
grant execute on function public.block_user(uuid) to authenticated;

drop policy if exists "Conversation participants read message media" on storage.objects;
create policy "Conversation participants read message media" on storage.objects
for select to authenticated
using (
  bucket_id='message-media'
  and exists(
    select 1 from public.messages m
    where m.media_path=objects.name
      and (m.sender_id=auth.uid() or m.receiver_id=auth.uid())
      and not exists(
        select 1 from public.user_blocks b
        where (b.blocker_id=auth.uid() and b.blocked_id=
          case when m.sender_id=auth.uid() then m.receiver_id else m.sender_id end)
           or (b.blocked_id=auth.uid() and b.blocker_id=
          case when m.sender_id=auth.uid() then m.receiver_id else m.sender_id end)
      )
      and (
        m.message_type<>'flash_image'
        or m.sender_id=auth.uid()
        or (m.receiver_id=auth.uid() and m.flash_opened_at is not null
            and m.flash_opened_at>=now()-interval '60 seconds')
      )
  )
);


-- Prevent read receipts, chat profile lookups, and flash opening after a block.
create or replace function public.mark_conversation_read(p_peer uuid)
returns void language plpgsql security definer
set search_path=pg_catalog,public
as $function$
begin
  if auth.uid() is null then raise exception '请先登录'; end if;
  if p_peer is null or p_peer=auth.uid() then return; end if;
  if exists(select 1 from public.user_blocks b
    where (b.blocker_id=auth.uid() and b.blocked_id=p_peer)
       or (b.blocker_id=p_peer and b.blocked_id=auth.uid())) then return; end if;
  update public.messages set is_read=true
  where sender_id=p_peer and receiver_id=auth.uid() and is_read=false;
end;
$function$;

create or replace function public.mark_message_read(p_message_id uuid)
returns boolean language plpgsql security definer
set search_path=''
as $function$
declare v_count integer;
begin
  if auth.uid() is null then raise exception '请先登录'; end if;
  update public.messages m set is_read=true
  where m.id=p_message_id and m.receiver_id=auth.uid()
    and not exists(select 1 from public.user_blocks b
      where (b.blocker_id=auth.uid() and b.blocked_id=m.sender_id)
         or (b.blocker_id=m.sender_id and b.blocked_id=auth.uid()));
  get diagnostics v_count=row_count;
  return v_count>0;
end;
$function$;

create or replace function public.open_flash_message(p_message_id uuid)
returns boolean language plpgsql security definer
set search_path=pg_catalog,public
as $function$
declare changed integer;
begin
  if auth.uid() is null then raise exception '请先登录'; end if;
  update public.messages m set flash_opened_at=now()
  where m.id=p_message_id and m.receiver_id=auth.uid()
    and m.message_type='flash_image' and m.flash_opened_at is null
    and not exists(select 1 from public.user_blocks b
      where (b.blocker_id=auth.uid() and b.blocked_id=m.sender_id)
         or (b.blocker_id=m.sender_id and b.blocked_id=auth.uid()));
  get diagnostics changed=row_count;
  return changed=1;
end;
$function$;

create or replace function public.get_chat_profiles(p_peer_ids uuid[])
returns table(id uuid,nickname text,friend_code text,avatar_url text,gender text)
language sql stable security definer
set search_path=pg_catalog,public
as $function$
  select p.id,coalesce(nullif(p.nickname,''),'用户')::text,p.friend_code,p.avatar_url,p.gender
  from public.profiles p
  where p.id=any(coalesce(p_peer_ids,'{}'::uuid[]))
    and exists(select 1 from public.messages m
      where (m.sender_id=auth.uid() and m.receiver_id=p.id)
         or (m.receiver_id=auth.uid() and m.sender_id=p.id))
    and not exists(select 1 from public.user_blocks b
      where (b.blocker_id=auth.uid() and b.blocked_id=p.id)
         or (b.blocker_id=p.id and b.blocked_id=auth.uid()));
$function$;

create or replace function public.view_friend_profile(p_id uuid)
returns table(
 id uuid,nickname text,friend_code text,avatar_url text,gender text,
 bubble_color text,signature text,recent_activity text,
 recent_activity_at timestamptz,sexual_orientation text,
 sexual_orientation_visible boolean
)
language sql stable security definer
set search_path=pg_catalog,public
as $function$
  select p.id,coalesce(p.nickname,'漂流者')::text,p.friend_code,p.avatar_url,p.gender,p.bubble_color,
         coalesce(p.signature,''),b.content,b.created_at,
         case when p.id=auth.uid() or p.sexual_orientation_visible then p.sexual_orientation else null end,
         case when p.id=auth.uid() then p.sexual_orientation_visible else false end
  from public.profiles p
  left join lateral(select bt.content,bt.created_at from public.bottles bt
    where bt.user_id=p.id and bt.is_public=true
    order by bt.created_at desc limit 1) b on true
  where p.id=p_id and (
    p.id=auth.uid() or (
      exists(select 1 from public.friend_requests fr
        where fr.status='accepted'
          and ((fr.sender_id=auth.uid() and fr.receiver_id=p.id)
            or (fr.receiver_id=auth.uid() and fr.sender_id=p.id)))
      and not exists(select 1 from public.user_blocks ub
        where (ub.blocker_id=auth.uid() and ub.blocked_id=p.id)
           or (ub.blocker_id=p.id and ub.blocked_id=auth.uid()))
    )
  )
  limit 1;
$function$;

revoke all on function public.mark_conversation_read(uuid) from public,anon;
grant execute on function public.mark_conversation_read(uuid) to authenticated;
revoke all on function public.mark_message_read(uuid) from public,anon;
grant execute on function public.mark_message_read(uuid) to authenticated;
revoke all on function public.open_flash_message(uuid) from public,anon;
grant execute on function public.open_flash_message(uuid) to authenticated;
revoke all on function public.get_chat_profiles(uuid[]) from public,anon;
grant execute on function public.get_chat_profiles(uuid[]) to authenticated;
revoke all on function public.view_friend_profile(uuid) from public,anon;
grant execute on function public.view_friend_profile(uuid) to authenticated;
