-- Enforce message payload consistency at the database boundary.
alter table public.messages
  add constraint messages_payload_consistency_check
  check (
    (
      message_type = 'text'
      and char_length(btrim(content)) between 1 and 500
      and media_path is null
      and media_mime is null
    )
    or (
      message_type = 'image'
      and content = ''
      and media_path is not null
      and media_mime in ('image/jpeg','image/png','image/webp','image/gif')
    )
    or (
      message_type = 'flash_image'
      and content = ''
      and media_path is not null
      and media_mime in ('image/jpeg','image/png','image/webp')
    )
    or (
      message_type = 'video'
      and content = ''
      and media_path is not null
      and media_mime in ('video/mp4','video/quicktime')
    )
    or (
      message_type = 'audio'
      and content = ''
      and media_path is not null
      and media_mime in ('audio/mp4','audio/mpeg','audio/webm','audio/aac','audio/wav','audio/ogg')
    )
  ) not valid;

alter table public.messages
  validate constraint messages_payload_consistency_check;

create or replace function public.validate_message_reply_target()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $function$
declare
  target public.messages%rowtype;
begin
  if new.reply_to_id is null then
    return new;
  end if;

  if new.reply_to_id = new.id then
    raise exception '不能回复消息本身';
  end if;

  select m.* into target
  from public.messages m
  where m.id = new.reply_to_id;

  if target.id is null then
    raise exception '回复的消息不存在或不可访问';
  end if;

  if not (
    (target.sender_id = new.sender_id and target.receiver_id = new.receiver_id)
    or
    (target.sender_id = new.receiver_id and target.receiver_id = new.sender_id)
  ) then
    raise exception '只能回复当前会话中的消息';
  end if;

  return new;
end;
$function$;

drop trigger if exists validate_message_reply_target on public.messages;
create trigger validate_message_reply_target
before insert or update of reply_to_id, sender_id, receiver_id
on public.messages
for each row
execute function public.validate_message_reply_target();

alter table public.community_comments
  drop constraint if exists community_comments_content_length_check;
