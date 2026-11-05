-- 漂流瓶：好友系统数据库迁移
-- 在 Supabase Dashboard -> SQL Editor 中整段执行一次。

create table if not exists public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  receiver_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending','accepted','rejected')),
  created_at timestamptz not null default now(),
  constraint friend_requests_no_self check (sender_id <> receiver_id),
  constraint friend_requests_unique_pair unique (sender_id, receiver_id)
);

create index if not exists friend_requests_receiver_status_idx
  on public.friend_requests(receiver_id, status);
create index if not exists friend_requests_sender_status_idx
  on public.friend_requests(sender_id, status);

alter table public.friend_requests enable row level security;

drop policy if exists "Users can view their own friend requests" on public.friend_requests;
create policy "Users can view their own friend requests"
on public.friend_requests for select to authenticated
using (auth.uid() = sender_id or auth.uid() = receiver_id);

drop policy if exists "Users can send friend requests" on public.friend_requests;
create policy "Users can send friend requests"
on public.friend_requests for insert to authenticated
with check (auth.uid() = sender_id and status = 'pending');

drop policy if exists "Receivers can respond to friend requests" on public.friend_requests;
create policy "Receivers can respond to friend requests"
on public.friend_requests for update to authenticated
using (auth.uid() = receiver_id and status = 'pending')
with check (auth.uid() = receiver_id and status in ('accepted','rejected'));

drop policy if exists "Participants can delete friend requests" on public.friend_requests;
create policy "Participants can delete friend requests"
on public.friend_requests for delete to authenticated
using (auth.uid() = sender_id or auth.uid() = receiver_id);

create or replace function public.search_profile_by_id(p_id uuid)
returns table(id uuid, nickname text)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, coalesce(p.nickname, '漂流者')::text
  from public.profiles p
  where p.id = p_id
    and p.id <> auth.uid()
  limit 1;
$$;

create or replace function public.get_my_friends()
returns table(id uuid, nickname text)
language sql
stable
security definer
set search_path = public
as $$
  select distinct
    case when fr.sender_id = auth.uid() then p2.id else p1.id end as id,
    coalesce(case when fr.sender_id = auth.uid() then p2.nickname else p1.nickname end, '漂流者')::text as nickname
  from public.friend_requests fr
  join public.profiles p1 on p1.id = fr.sender_id
  join public.profiles p2 on p2.id = fr.receiver_id
  where fr.status = 'accepted'
    and auth.uid() in (fr.sender_id, fr.receiver_id);
$$;

revoke all on function public.search_profile_by_id(uuid) from public;
revoke all on function public.get_my_friends() from public;
grant execute on function public.search_profile_by_id(uuid) to authenticated;
grant execute on function public.get_my_friends() to authenticated;
grant select, insert, update, delete on public.friend_requests to authenticated;
