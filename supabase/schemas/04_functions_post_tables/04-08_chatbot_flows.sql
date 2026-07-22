create function public.protect_published_chatbot_flow_version() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status = 'published' then
    raise exception using
      errcode = '23514',
      message = 'published chatbot flow versions are immutable';
  end if;

  return new;
end;
$$;

create trigger protect_published_chatbot_flow_version
before update
on public.chatbot_flow_versions
for each row
execute function public.protect_published_chatbot_flow_version();

create function public.validate_chatbot_flow_run() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  version_status text;
  conversation_organization_id uuid;
  message_conversation_id uuid;
begin
  if tg_op = 'UPDATE' and (
    new.organization_id <> old.organization_id
    or new.conversation_id <> old.conversation_id
    or new.flow_version_id <> old.flow_version_id
  ) then
    raise exception using
      errcode = '23514',
      message = 'chatbot flow run identity is immutable';
  end if;

  select version.status
  into version_status
  from public.chatbot_flow_versions as version
  where version.organization_id = new.organization_id
    and version.id = new.flow_version_id;

  if version_status is distinct from 'published' then
    raise exception using
      errcode = '23514',
      message = 'chatbot flow runs require a published flow version';
  end if;

  select conversation.organization_id
  into conversation_organization_id
  from public.conversations as conversation
  where conversation.id = new.conversation_id;

  if conversation_organization_id is distinct from new.organization_id then
    raise exception using
      errcode = '23514',
      message = 'chatbot flow run conversation must belong to the same organization';
  end if;

  if new.last_processed_message_id is not null then
    select message.conversation_id
    into message_conversation_id
    from public.messages as message
    where message.id = new.last_processed_message_id;

    if message_conversation_id is distinct from new.conversation_id then
      raise exception using
        errcode = '23514',
        message = 'last processed message must belong to the chatbot flow run conversation';
    end if;
  end if;

  return new;
end;
$$;

create trigger validate_chatbot_flow_run
before insert or update
on public.chatbot_flow_runs
for each row
execute function public.validate_chatbot_flow_run();
