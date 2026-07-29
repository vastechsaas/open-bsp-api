CREATE UNIQUE INDEX agents_external_chatbot_key_idx ON public.agents USING btree (organization_id, ((extra ->> 'integration_key'::text))) WHERE ((ai = true) AND ((extra ->> 'kind'::text) = 'external_chatbot'::text));

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.ensure_external_chatbot_agent(p_organization_id uuid, p_integration_key text, p_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  normalized_key text := lower(btrim(p_integration_key));
  normalized_name text := btrim(p_name);
  external_agent public.agents;
begin
  if normalized_key is null
    or normalized_key !~ '^[a-z0-9][a-z0-9_-]{0,63}$'
  then
    raise exception using
      errcode = '22023',
      message = 'external chatbot key is invalid';
  end if;

  if normalized_name is null
    or char_length(normalized_name) < 1
    or char_length(normalized_name) > 120
  then
    raise exception using
      errcode = '22023',
      message = 'external chatbot name is invalid';
  end if;

  if not exists (
    select 1
    from public.organizations as organization
    where organization.id = p_organization_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'organization not found';
  end if;

  select agent.*
  into external_agent
  from public.agents as agent
  where agent.organization_id = p_organization_id
    and agent.ai = true
    and agent.extra->>'kind' = 'external_chatbot'
    and agent.extra->>'integration_key' = normalized_key
  limit 1;

  if found then
    if external_agent.extra->>'mode' = 'inactive' then
      raise exception using
        errcode = '23514',
        message = 'external chatbot sender is inactive';
    end if;

    return external_agent.id;
  end if;

  begin
    insert into public.agents (
      organization_id,
      name,
      ai,
      extra
    ) values (
      p_organization_id,
      normalized_name,
      true,
      jsonb_build_object(
        'kind', 'external_chatbot',
        'integration_key', normalized_key,
        'mode', 'active'
      )
    )
    returning id into external_agent.id;
  exception
    when unique_violation then
      select agent.*
      into external_agent
      from public.agents as agent
      where agent.organization_id = p_organization_id
        and agent.ai = true
        and agent.extra->>'kind' = 'external_chatbot'
        and agent.extra->>'integration_key' = normalized_key;
  end;

  if external_agent.id is null then
    raise exception using
      errcode = '23514',
      message = 'external chatbot sender could not be resolved';
  end if;

  if external_agent.extra->>'mode' = 'inactive' then
    raise exception using
      errcode = '23514',
      message = 'external chatbot sender is inactive';
  end if;

  return external_agent.id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_external_chatbot_reply(p_organization_id uuid, p_agent_id uuid, p_phone_number_id text, p_recipient text, p_wamid text, p_sent_at timestamp with time zone, p_content jsonb)
 RETURNS TABLE(outcome text, message_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  normalized_phone_number_id text := btrim(p_phone_number_id);
  normalized_recipient text := btrim(p_recipient);
  normalized_wamid text := btrim(p_wamid);
  target_agent public.agents;
  existing_message public.messages;
  target_conversation_id uuid;
  target_message_id uuid;
  target_outcome text;
begin
  if normalized_phone_number_id is null
    or normalized_phone_number_id !~ '^[0-9]{5,32}$'
    or normalized_recipient is null
    or normalized_recipient !~ '^[0-9]{5,32}$'
    or normalized_wamid is null
    or normalized_wamid !~ '^wamid\..+'
    or char_length(normalized_wamid) > 512
    or p_sent_at is null
  then
    raise exception using
      errcode = '22023',
      message = 'external chatbot reply identifiers are required';
  end if;

  if p_content is null
    or p_content = '{}'::jsonb
    or p_content->>'version' is distinct from '1'
    or not coalesce(
      (
        p_content->>'type' = 'text'
        and p_content->>'kind' = 'text'
        and jsonb_typeof(p_content->'text') = 'string'
      )
      or (
        p_content->>'type' = 'data'
        and p_content->>'kind' = 'interactive'
        and jsonb_typeof(p_content->'data') = 'object'
      ),
      false
    )
  then
    raise exception using
      errcode = '22023',
      message = 'external chatbot reply content is invalid';
  end if;

  if not exists (
    select 1
    from public.organizations_addresses as address
    where address.organization_id = p_organization_id
      and address.address = normalized_phone_number_id
      and address.service = 'whatsapp'::public.service
      and address.status = 'connected'
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'connected WhatsApp phone number not found';
  end if;

  select agent.*
  into target_agent
  from public.agents as agent
  where agent.organization_id = p_organization_id
    and agent.id = p_agent_id;

  if not found
    or target_agent.ai is distinct from true
    or target_agent.extra->>'kind' is distinct from 'external_chatbot'
    or target_agent.extra->>'mode' = 'inactive'
  then
    raise exception using
      errcode = '23514',
      message = 'external chatbot sender is invalid';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('external-chatbot-wamid:' || normalized_wamid, 0)
  );

  select message.*
  into existing_message
  from public.messages as message
  where message.external_id = normalized_wamid
  for update;

  if found then
    if existing_message.organization_id <> p_organization_id
      or existing_message.service <> 'whatsapp'::public.service
      or existing_message.organization_address <> normalized_phone_number_id
      or existing_message.contact_address is distinct from normalized_recipient
      or existing_message.direction <> 'outgoing'::public.direction
    then
      raise exception using
        errcode = '23505',
        message = 'WAMID belongs to another message';
    end if;

    if existing_message.agent_id is not null
      and existing_message.agent_id <> p_agent_id
    then
      raise exception using
        errcode = '23505',
        message = 'WAMID belongs to another chatbot sender';
    end if;

    if existing_message.content <> '{}'::jsonb
      and existing_message.content <> p_content
    then
      raise exception using
        errcode = '23505',
        message = 'WAMID already has different message content';
    end if;

    target_outcome := case
      when existing_message.content = '{}'::jsonb
        or existing_message.agent_id is null
      then 'merged'
      else 'duplicate'
    end;

    update public.messages as message
    set agent_id = p_agent_id,
        content = p_content,
        status = jsonb_build_object('sent', p_sent_at),
        "timestamp" = case
          when existing_message.content = '{}'::jsonb then p_sent_at
          else existing_message."timestamp"
        end
    where message.id = existing_message.id
    returning message.id into target_message_id;

    return query
    select target_outcome, target_message_id;
    return;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'external-chatbot-conversation:'
        || p_organization_id::text
        || ':'
        || normalized_phone_number_id
        || ':'
        || normalized_recipient,
      0
    )
  );

  select conversation.id
  into target_conversation_id
  from public.conversations as conversation
  where conversation.organization_id = p_organization_id
    and conversation.service = 'whatsapp'::public.service
    and conversation.organization_address = normalized_phone_number_id
    and conversation.contact_address = normalized_recipient
    and conversation.group_address is null
    and conversation.status = 'active'
  order by conversation.created_at desc
  limit 1;

  if target_conversation_id is null then
    insert into public.conversations (
      organization_id,
      service,
      organization_address,
      contact_address
    ) values (
      p_organization_id,
      'whatsapp',
      normalized_phone_number_id,
      normalized_recipient
    )
    returning id into target_conversation_id;
  end if;

  insert into public.messages (
    organization_id,
    conversation_id,
    external_id,
    direction,
    agent_id,
    contact_address,
    service,
    organization_address,
    content,
    status,
    "timestamp"
  ) values (
    p_organization_id,
    target_conversation_id,
    normalized_wamid,
    'outgoing',
    p_agent_id,
    normalized_recipient,
    'whatsapp',
    normalized_phone_number_id,
    p_content,
    jsonb_build_object('sent', p_sent_at),
    p_sent_at
  )
  returning id into target_message_id;

  return query
  select 'stored'::text, target_message_id;
end;
$function$
;


revoke execute on function public.ensure_external_chatbot_agent(
  uuid,
  text,
  text
) from public, anon, authenticated;
grant execute on function public.ensure_external_chatbot_agent(
  uuid,
  text,
  text
) to service_role;

revoke execute on function public.record_external_chatbot_reply(
  uuid,
  uuid,
  text,
  text,
  text,
  timestamp with time zone,
  jsonb
) from public, anon, authenticated;
grant execute on function public.record_external_chatbot_reply(
  uuid,
  uuid,
  text,
  text,
  text,
  timestamp with time zone,
  jsonb
) to service_role;
