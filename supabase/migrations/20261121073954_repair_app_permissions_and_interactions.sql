-- Repair missing Data API grants while retaining the existing RLS policies.
-- Public profile columns only; private fields remain available through the
-- authenticated get_my_private_profile() RPC.

grant select (
  id, nickname, friend_code, avatar_url, created_at,
  gender, bubble_color, signature, profile_theme
) on public.profiles to authenticated;

grant update (
  nickname, avatar_url, signature, bubble_color,
  sexual_orientation, sexual_orientation_visible, gender
) on public.profiles to authenticated;

grant select, insert, delete on public.bottles to authenticated;
grant select, insert, delete on public.messages to authenticated;
grant select, insert, delete on public.favorites to authenticated;
grant select, insert, delete on public.community_posts to authenticated;
grant select, insert, delete on public.community_comments to authenticated;
grant select, insert, delete on public.community_likes to authenticated;
grant select, insert, delete on public.follows to authenticated;
grant select, insert, update, delete on public.friend_requests to authenticated;

grant select on public.community_notifications to authenticated;
grant update (is_read) on public.community_notifications to authenticated;
grant select, insert on public.content_reports to authenticated;

grant select on public.ocean_wallets to authenticated;
grant select on public.ocean_checkins to authenticated;
grant select on public.ocean_task_claims to authenticated;
grant select on public.ocean_wallet_transactions to authenticated;
grant select on public.ocean_inventory to authenticated;
grant select on public.ocean_pets to authenticated;
grant select, insert, delete on public.ocean_cottage_decor to authenticated;
grant select, delete on public.user_blocks to authenticated;

-- Prevent a recipient from rewriting the sender/receiver identity of a
-- friend request while accepting or rejecting it.
create or replace function public.guard_friend_request_update()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $function$
begin
  if new.sender_id is distinct from old.sender_id
     or new.receiver_id is distinct from old.receiver_id
     or new.created_at is distinct from old.created_at then
    raise exception '好友申请的发送方、接收方和创建时间不可修改';
  end if;

  if old.status <> 'pending'
     or new.status not in ('accepted', 'rejected') then
    raise exception '好友申请只能从待处理变更为同意或拒绝';
  end if;

  return new;
end;
$function$;

drop trigger if exists guard_friend_request_update on public.friend_requests;
create trigger guard_friend_request_update
before update on public.friend_requests
for each row execute function public.guard_friend_request_update();

-- A rejected request can be sent again. Reciprocal pending requests are
-- accepted atomically instead of producing two conflicting requests.
create or replace function public.send_friend_request(p_receiver_id uuid)
returns table(success boolean, request_status text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  uid uuid := auth.uid();
begin
  if uid is null then raise exception '请先登录'; end if;
  if p_receiver_id is null or p_receiver_id = uid then
    raise exception '不能向自己发送好友申请';
  end if;

  perform p.id
  from public.profiles p
  where p.id in (uid, p_receiver_id)
  order by p.id
  for update;

  if not exists(select 1 from public.profiles p where p.id = p_receiver_id) then
    raise exception '用户不存在';
  end if;

  if exists (
    select 1 from public.user_blocks b
    where (b.blocker_id = uid and b.blocked_id = p_receiver_id)
       or (b.blocker_id = p_receiver_id and b.blocked_id = uid)
  ) then
    raise exception '你们之间存在屏蔽关系，无法发送好友申请';
  end if;

  if exists (
    select 1 from public.friend_requests fr
    where fr.status = 'accepted'
      and ((fr.sender_id = uid and fr.receiver_id = p_receiver_id)
        or (fr.sender_id = p_receiver_id and fr.receiver_id = uid))
  ) then
    return query select false, 'accepted'::text;
    return;
  end if;

  update public.friend_requests fr
  set status = 'accepted'
  where fr.sender_id = p_receiver_id
    and fr.receiver_id = uid
    and fr.status = 'pending';

  if found then
    return query select true, 'accepted'::text;
    return;
  end if;

  if exists (
    select 1 from public.friend_requests fr
    where fr.sender_id = uid
      and fr.receiver_id = p_receiver_id
      and fr.status = 'pending'
  ) then
    return query select false, 'pending'::text;
    return;
  end if;

  -- Remove stale rejected rows in either direction so the pair can try again.
  delete from public.friend_requests fr
  where fr.status = 'rejected'
    and ((fr.sender_id = uid and fr.receiver_id = p_receiver_id)
      or (fr.sender_id = p_receiver_id and fr.receiver_id = uid));

  insert into public.friend_requests(sender_id, receiver_id, status)
  values(uid, p_receiver_id, 'pending');

  return query select true, 'pending'::text;
end;
$function$;

revoke all on function public.send_friend_request(uuid) from public, anon;
grant execute on function public.send_friend_request(uuid) to authenticated;

-- Return the same safe public profile fields expected by the friends UI.
drop function if exists public.search_profile_by_id(uuid);
create function public.search_profile_by_id(p_id uuid)
returns table(id uuid, nickname text, friend_code text, avatar_url text)
language plpgsql
stable
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null then raise exception '请先登录'; end if;

  return query
  select p.id,
         coalesce(p.nickname, '漂流者')::text,
         p.friend_code,
         p.avatar_url
  from public.profiles p
  where p.id = p_id and p.id <> auth.uid()
  limit 1;
end;
$function$;

revoke all on function public.search_profile_by_id(uuid) from public, anon;
grant execute on function public.search_profile_by_id(uuid) to authenticated;

drop function if exists public.get_my_friends();
create function public.get_my_friends()
returns table(id uuid, nickname text, friend_code text, avatar_url text)
language sql
stable
security definer
set search_path = pg_catalog, public
as $function$
  select
    case when fr.sender_id = auth.uid() then p2.id else p1.id end,
    coalesce(case when fr.sender_id = auth.uid() then p2.nickname else p1.nickname end, '漂流者')::text,
    case when fr.sender_id = auth.uid() then p2.friend_code else p1.friend_code end,
    case when fr.sender_id = auth.uid() then p2.avatar_url else p1.avatar_url end
  from public.friend_requests fr
  join public.profiles p1 on p1.id = fr.sender_id
  join public.profiles p2 on p2.id = fr.receiver_id
  where fr.status = 'accepted'
    and auth.uid() in (fr.sender_id, fr.receiver_id);
$function$;

revoke all on function public.get_my_friends() from public, anon;
grant execute on function public.get_my_friends() to authenticated;

-- A bottle is claimed on the server at the moment the user picks it up.
-- The block check is enforced here, not just in the browser's candidate list.
create or replace function public.pickup_bottle(p_bottle_id uuid)
returns setof public.bottles
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then raise exception '请先登录'; end if;

  return query
  update public.bottles b
  set status = 'picked_up',
      picked_up_by = v_user_id,
      picked_up_at = now()
  where b.id = p_bottle_id
    and b.user_id <> v_user_id
    and b.is_public = true
    and b.status = 'floating'
    and not exists (
      select 1 from public.user_blocks ub
      where (ub.blocker_id = v_user_id and ub.blocked_id = b.user_id)
         or (ub.blocker_id = b.user_id and ub.blocked_id = v_user_id)
    )
  returning b.*;

  if not found then
    raise exception '这只云朵已被捡走、不可捡取或与你存在屏蔽关系';
  end if;
end;
$function$;

revoke all on function public.pickup_bottle(uuid) from public, anon;
grant execute on function public.pickup_bottle(uuid) to authenticated;
