-- Cloud Island daily free cloud-coin allowance.
-- Ordinary accounts can earn at most 20 free coins per China Standard Time day.
-- Daily check-in and task rewards share the same cap. Task XP remains separate.

create or replace function public.claim_ocean_daily_reward()
returns table(
  success boolean,
  shells integer,
  xp integer,
  current_streak integer,
  level integer,
  total_shells integer,
  total_xp integer
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  uid uuid := auth.uid();
  today date := (timezone('Asia/Shanghai', now()))::date;
  cursor_day date;
  streak integer := 0;
  daily_earned integer := 0;
  award integer := 0;
  w public.ocean_wallets%rowtype;
begin
  if uid is null then raise exception '请先登录'; end if;

  insert into public.ocean_wallets(user_id)
  values(uid) on conflict(user_id) do nothing;

  select ow.* into w
  from public.ocean_wallets ow
  where ow.user_id = uid
  for update;

  if exists (
    select 1 from public.ocean_checkins c
    where c.user_id = uid and c.checkin_date = today
  ) then
    cursor_day := today;
  else
    cursor_day := today - 1;
  end if;

  loop
    exit when streak >= 365 or not exists (
      select 1 from public.ocean_checkins c
      where c.user_id = uid and c.checkin_date = cursor_day
    );
    streak := streak + 1;
    cursor_day := cursor_day - 1;
  end loop;

  if exists (
    select 1 from public.ocean_checkins c
    where c.user_id = uid and c.checkin_date = today
  ) then
    return query
    select false, 0, 0, streak,
           greatest(1, floor(w.xp / 100.0)::integer + 1),
           w.shells, w.xp;
    return;
  end if;

  select coalesce(sum(t.reward_shells), 0)::integer
    into daily_earned
  from public.ocean_task_claims t
  where t.user_id = uid and t.task_date = today;

  award := greatest(0, 20 - daily_earned);

  insert into public.ocean_checkins(
    user_id, checkin_date, reward_shells, reward_xp
  ) values(uid, today, award, 10);

  update public.ocean_wallets ow
  set shells = ow.shells + award,
      xp = ow.xp + 10,
      updated_at = now()
  where ow.user_id = uid
  returning ow.* into w;

  return query
  select true, award, 10, streak + 1,
         greatest(1, floor(w.xp / 100.0)::integer + 1),
         w.shells, w.xp;
end;
$function$;

create or replace function public.claim_ocean_daily_task(p_task_code text)
returns table(success boolean, shells integer, xp integer, total_shells integer, total_xp integer)
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  uid uuid := auth.uid();
  today date := (timezone('Asia/Shanghai', now()))::date;
  eligible boolean := false;
  daily_earned integer := 0;
  award integer := 0;
  w public.ocean_wallets%rowtype;
begin
  if uid is null then raise exception '请先登录'; end if;
  if p_task_code not in ('send_bottle', 'post_moment', 'send_message') then
    raise exception '任务不存在';
  end if;

  if p_task_code = 'send_bottle' then
    select exists(select 1 from public.bottles b
      where b.user_id = uid
      and (b.created_at at time zone 'Asia/Shanghai')::date = today)
      into eligible;
  elsif p_task_code = 'post_moment' then
    select exists(select 1 from public.community_posts p
      where p.user_id = uid
      and (p.created_at at time zone 'Asia/Shanghai')::date = today)
      into eligible;
  else
    select exists(select 1 from public.messages m
      where m.sender_id = uid
      and (m.created_at at time zone 'Asia/Shanghai')::date = today
      and coalesce(m.is_retracted, false) = false)
      into eligible;
  end if;

  if not eligible then raise exception '先完成今日任务，再来领取奖励'; end if;

  insert into public.ocean_wallets(user_id)
  values(uid) on conflict(user_id) do nothing;

  select ow.* into w
  from public.ocean_wallets ow
  where ow.user_id = uid
  for update;

  select
    coalesce((select sum(c.reward_shells) from public.ocean_checkins c
      where c.user_id = uid and c.checkin_date = today), 0)
    +
    coalesce((select sum(t.reward_shells) from public.ocean_task_claims t
      where t.user_id = uid and t.task_date = today), 0)
  into daily_earned;

  award := least(3, greatest(0, 20 - daily_earned));

  insert into public.ocean_task_claims(
    user_id, task_code, task_date, reward_shells, reward_xp
  )
  values(uid, p_task_code, today, award, 5)
  on conflict(user_id, task_code, task_date) do nothing;

  if not found then
    return query select false, 0, 0, w.shells, w.xp;
    return;
  end if;

  update public.ocean_wallets ow
  set shells = ow.shells + award,
      xp = ow.xp + 5,
      updated_at = now()
  where ow.user_id = uid
  returning ow.* into w;

  return query select true, award, 5, w.shells, w.xp;
end;
$function$;

revoke all on function public.claim_ocean_daily_reward() from public, anon;
grant execute on function public.claim_ocean_daily_reward() to authenticated;
revoke all on function public.claim_ocean_daily_task(text) from public, anon;
grant execute on function public.claim_ocean_daily_task(text) to authenticated;
