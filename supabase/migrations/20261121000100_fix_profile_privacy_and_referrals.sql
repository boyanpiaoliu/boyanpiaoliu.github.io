-- Cloud Island: repair private profile loading and referral membership grants.
-- Applied to production on 2026-11-21 and kept here for reproducibility.

create or replace function public.guard_profile_sensitive_fields()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $function$
begin
  if current_user not in ('postgres', 'service_role') then
    if new.id is distinct from old.id then
      raise exception '不允许修改账号标识';
    end if;
    if new.friend_code is distinct from old.friend_code then
      raise exception '好友ID不可自行修改';
    end if;
    if new.membership_until is distinct from old.membership_until then
      raise exception '会员状态只能由服务端更新';
    end if;
    if new.created_at is distinct from old.created_at then
      raise exception '注册时间不可修改';
    end if;
  end if;
  return new;
end;
$function$;

create or replace function public.claim_invite_code(p_code text)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_uid uuid := auth.uid();
  v_inviter uuid;
  v_rows integer;
  v_code text := trim(coalesce(p_code, ''));
begin
  if v_uid is null then
    raise exception '请先登录';
  end if;

  if v_code !~ '^[0-9]{6,12}$' then
    raise exception '邀请码格式不正确';
  end if;

  select p.id into v_inviter
  from public.profiles p
  where p.friend_code = v_code
  limit 1
  for update;

  if v_inviter is null then
    raise exception '邀请码不存在';
  end if;
  if v_inviter = v_uid then
    raise exception '不能使用自己的邀请码';
  end if;
  if exists (select 1 from public.referrals r where r.invitee_id = v_uid) then
    raise exception '你已经使用过邀请码';
  end if;

  insert into public.referrals(inviter_id, invitee_id, invite_code, reward_days)
  values (v_inviter, v_uid, v_code, 3);

  update public.profiles p
  set membership_until = case
    when p.membership_until >= timestamptz '9999-01-01 00:00:00+00'
      then p.membership_until
    else greatest(coalesce(p.membership_until, now()), now()) + interval '3 days'
  end
  where p.id in (v_inviter, v_uid);

  get diagnostics v_rows = row_count;
  if v_rows <> 2 then
    raise exception '会员奖励发放失败，请稍后重试';
  end if;

  return 3;
end;
$function$;

drop function if exists public.get_my_private_profile();
create function public.get_my_private_profile()
returns table(
  membership_until timestamptz,
  sexual_orientation text,
  sexual_orientation_visible boolean,
  location text
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null then
    raise exception '请先登录';
  end if;

  return query
  select p.membership_until,
         p.sexual_orientation,
         p.sexual_orientation_visible,
         p.location
  from public.profiles p
  where p.id = auth.uid();
end;
$function$;

revoke all on function public.get_my_private_profile() from public, anon, authenticated;
grant execute on function public.get_my_private_profile() to authenticated;
