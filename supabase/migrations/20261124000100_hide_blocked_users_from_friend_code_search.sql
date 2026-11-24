-- A blocked account must not be discoverable through the numeric friend-code lookup.
create or replace function public.search_profile_by_friend_code(p_friend_code text)
returns table(id uuid,nickname text,friend_code text,avatar_url text)
language plpgsql
stable
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null then raise exception '请先登录'; end if;
  if p_friend_code is null or trim(p_friend_code) !~ '^[0-9]{6,8}$' then
    raise exception '好友 ID 格式不正确';
  end if;

  return query
  select p.id, coalesce(p.nickname, '漂流者')::text, p.friend_code, p.avatar_url
  from public.profiles p
  where p.friend_code = trim(p_friend_code)
    and p.id <> auth.uid()
    and not exists (
      select 1 from public.user_blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = p.id)
         or (b.blocker_id = p.id and b.blocked_id = auth.uid())
    )
  limit 1;
end;
$function$;

revoke all on function public.search_profile_by_friend_code(text) from public, anon;
grant execute on function public.search_profile_by_friend_code(text) to authenticated;
