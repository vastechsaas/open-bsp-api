drop function if exists "public"."record_external_chatbot_reply"(p_organization_id uuid, p_agent_id uuid, p_phone_number_id text, p_recipient text, p_wamid text, p_sent_at timestamp with time zone, p_content jsonb);

alter table "public"."chatbot_node_conversations" add column "episode_number" integer;

alter table "public"."chatbot_node_conversations" add column "last_synced_at" timestamp with time zone;

alter table "public"."chatbot_node_conversations" add column "previous_node_conversation_id" text;

CREATE UNIQUE INDEX chatbot_node_episode_successor_idx ON public.chatbot_node_conversations USING btree (organization_id, organization_address, previous_node_conversation_id) WHERE (previous_node_conversation_id IS NOT NULL);

alter table "public"."chatbot_node_conversations" add constraint "chatbot_node_conversations_episode_number_check" CHECK ((episode_number > 0)) not valid;

alter table "public"."chatbot_node_conversations" validate constraint "chatbot_node_conversations_episode_number_check";

alter table "public"."chatbot_node_conversations" add constraint "chatbot_node_conversations_previous_node_conversation_id_check" CHECK ((previous_node_conversation_id ~ '^[0-9]+$'::text)) not valid;

alter table "public"."chatbot_node_conversations" validate constraint "chatbot_node_conversations_previous_node_conversation_id_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.list_previous_conversations_page(p_organization_id uuid, p_conversation_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, name text, status text, created_at timestamp with time zone, updated_at timestamp with time zone, total_count bigint)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare target public.conversations;
begin
  if auth.uid() is null or not exists(select 1 from public.get_authorized_orgs('agent') a(id) where a.id=p_organization_id) then
    raise exception 'organization is not accessible' using errcode='42501'; end if;
  select * into target from public.conversations c where c.organization_id=p_organization_id and c.id=p_conversation_id;
  if not found then raise exception 'conversation is not accessible' using errcode='42501'; end if;
  return query select c.id,c.name,c.status,c.created_at,c.updated_at,count(*) over()
    from public.conversations c where c.organization_id=p_organization_id and c.id<>target.id
    and c.service=target.service and c.organization_address=target.organization_address
    and c.contact_address=target.contact_address and c.group_address is null
    and (nullif(btrim(p_search),'') is null or c.name ilike '%' || btrim(p_search) || '%')
    order by c.created_at desc,c.id desc limit greatest(1,least(coalesce(p_page_size,10),50))
    offset (greatest(1,coalesce(p_page,1))-1)*greatest(1,least(coalesce(p_page_size,10),50));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_external_chatbot_reply(p_organization_id uuid, p_agent_id uuid, p_phone_number_id text, p_recipient text, p_wamid text, p_sent_at timestamp with time zone, p_content jsonb, p_conversation_id uuid DEFAULT NULL::uuid)
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
    if p_conversation_id is not null and existing_message.conversation_id<>p_conversation_id then
      raise exception 'WAMID belongs to another conversation' using errcode='23505'; end if;
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

  if p_conversation_id is not null then
    select c.id into target_conversation_id from public.conversations c
      where c.id=p_conversation_id and c.organization_id=p_organization_id and c.service='whatsapp'
      and c.organization_address=normalized_phone_number_id and c.contact_address=normalized_recipient and c.group_address is null;
    if not found then raise exception 'conversation mapping mismatch' using errcode='23514'; end if;
  else
  if exists(select 1 from public.chatbot_node_conversations m join public.conversations c on c.id=m.conversation_id
    where m.organization_id=p_organization_id and m.organization_address=normalized_phone_number_id
      and c.contact_address=normalized_recipient and m.episode_number is not null) then
    raise exception 'explicit Node episode context is required' using errcode='40001'; end if;
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

CREATE OR REPLACE FUNCTION public.resolve_node_conversation_episode(p_organization_id uuid, p_address text, p_recipient text, p_node_conversation_id text, p_episode_number integer, p_previous_node_conversation_id text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  mapping public.chatbot_node_conversations;
  predecessor public.chatbot_node_conversations;
  target public.conversations;
begin
  if p_node_conversation_id is null or p_episode_number is null or p_recipient is null or p_address is null
    or p_node_conversation_id !~ '^[0-9]+$' or p_episode_number < 1
    or (p_episode_number > 1 and p_previous_node_conversation_id is null)
    or (p_episode_number = 1 and p_previous_node_conversation_id is not null) then
    raise exception 'invalid Node episode context' using errcode='22023'; end if;
  if not public.is_organization_active(p_organization_id) or not public.is_node_managed_number(p_organization_id,p_address) then
    raise exception 'tenant or Node binding unavailable' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_organization_id::text || ':' || p_address || ':' || p_recipient,123));
  select * into mapping from public.chatbot_node_conversations where organization_id=p_organization_id
    and organization_address=p_address and node_conversation_id=p_node_conversation_id for update;
  if found then
    select * into target from public.conversations where organization_id=p_organization_id and id=mapping.conversation_id;
    if target.contact_address is distinct from p_recipient or
      (mapping.episode_number is not null and (mapping.episode_number<>p_episode_number
        or mapping.previous_node_conversation_id is distinct from p_previous_node_conversation_id)) then
      raise exception 'episode mapping mismatch' using errcode='23514'; end if;
    update public.chatbot_node_conversations set episode_number=p_episode_number,
      previous_node_conversation_id=p_previous_node_conversation_id where organization_id=p_organization_id
      and organization_address=p_address and node_conversation_id=p_node_conversation_id;
    return target.id;
  end if;
  if p_previous_node_conversation_id is not null then
    select * into predecessor from public.chatbot_node_conversations where organization_id=p_organization_id
      and organization_address=p_address and node_conversation_id=p_previous_node_conversation_id for update;
    if not found or predecessor.state<>'closed' then
      raise exception 'previous episode closure has not arrived' using errcode='40001'; end if;
    select * into target from public.conversations where organization_id=p_organization_id and id=predecessor.conversation_id;
    if target.contact_address is distinct from p_recipient or coalesce(predecessor.episode_number,1)<>p_episode_number-1 then
      raise exception 'episode predecessor mismatch' using errcode='23514'; end if;
    update public.chatbot_node_conversations set episode_number=coalesce(episode_number,1)
      where organization_id=p_organization_id and organization_address=p_address and node_conversation_id=p_previous_node_conversation_id;
    target.id := null;
  else
    if exists(select 1 from public.chatbot_node_conversations m join public.conversations c on c.id=m.conversation_id
      where m.organization_id=p_organization_id and m.organization_address=p_address and c.contact_address=p_recipient
      and m.episode_number is not null) then
      raise exception 'episode predecessor is required' using errcode='23514'; end if;
    -- Adopt the current legacy thread when enrolling a tenant; never move messages.
    select * into target from public.conversations c where c.organization_id=p_organization_id
      and c.organization_address=p_address and c.contact_address=p_recipient and c.group_address is null
      and c.status='active' and not exists(select 1 from public.chatbot_node_conversations m
        where m.organization_id=p_organization_id and m.conversation_id=c.id)
      order by c.created_at desc,c.id desc limit 1 for update;
  end if;
  if target.id is null then
    insert into public.conversations(organization_id,organization_address,contact_address,service)
      values(p_organization_id,p_address,p_recipient,'whatsapp') returning * into target;
  end if;
  insert into public.chatbot_node_conversations(organization_id,organization_address,node_conversation_id,conversation_id,
    human_owned,lifecycle_enabled,state,episode_number,previous_node_conversation_id)
    values(p_organization_id,p_address,p_node_conversation_id,target.id,false,true,'bot_ready',p_episode_number,p_previous_node_conversation_id);
  return target.id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.apply_node_conversation_lifecycle(p_organization_id uuid, p_address text, p_node_conversation_id text, p_recipient text, p_revision text, p_state text, p_last_inbound_wamid text, p_source_wamid text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid, p_support_request jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  mapping public.chatbot_node_conversations;
  target public.conversations;
  operation public.chatbot_node_operations;
begin
  if p_revision !~ '^[0-9]+$' or p_state not in ('human_owned','closed','bot_ready','bot_active') then
    raise exception 'invalid conversation lifecycle' using errcode = '22023';
  end if;
  if not public.is_organization_active(p_organization_id) then
    raise exception 'organization is archived' using errcode = '42501';
  end if;
  if not public.is_node_managed_number(p_organization_id, p_address) then
    raise exception 'number is not managed by Node' using errcode = '23514';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_organization_id::text || ':' || p_address || ':' || p_recipient, 123));
  select * into mapping from public.chatbot_node_conversations where organization_id = p_organization_id
    and organization_address = p_address and node_conversation_id = p_node_conversation_id;
  if found then
    select * into target from public.conversations where organization_id = p_organization_id and id = mapping.conversation_id for update;
  else
    select c.* into target from public.conversations c join public.messages m on m.conversation_id = c.id
      where c.organization_id = p_organization_id and c.organization_address = p_address and c.contact_address = p_recipient
        and m.organization_id = p_organization_id and m.direction = 'incoming' and m.external_id = coalesce(p_source_wamid, p_last_inbound_wamid)
      for update of c;
    if not found then raise exception 'customer message has not arrived' using errcode = '40001'; end if;
    insert into public.chatbot_node_conversations(organization_id, organization_address, node_conversation_id, conversation_id)
      values(p_organization_id, p_address, p_node_conversation_id, target.id) returning * into mapping;
  end if;
  if target.contact_address is distinct from p_recipient then raise exception 'conversation mapping mismatch' using errcode = '23514'; end if;
  if mapping.episode_number is not null and mapping.state = 'closed' then return target.id; end if;
  if p_revision::numeric <= mapping.ownership_revision::numeric and mapping.lifecycle_enabled then return target.id; end if;
  -- Reopen and handoff events may arrive ahead of the original inbound webhook.
  if not exists(select 1 from public.messages where organization_id = p_organization_id and conversation_id = target.id
    and direction = 'incoming' and external_id = coalesce(p_source_wamid, p_last_inbound_wamid)) then
    raise exception 'customer message has not arrived' using errcode = '40001';
  end if;
  -- The inbound webhook may beat the Node reopen event. Never hide that message
  -- by applying a close snapshot which only observed an older customer message.
  if p_state = 'closed' and mapping.last_inbound_wamid is not null
    and mapping.last_inbound_wamid is distinct from p_last_inbound_wamid then
    raise exception 'A new customer message arrived—review it before closing.' using errcode = '40001';
  end if;
  if p_request_id is not null then select * into operation from public.chatbot_node_operations where request_id = p_request_id
    and organization_id = p_organization_id and conversation_id = target.id; end if;
  update public.chatbot_node_conversations set lifecycle_enabled = true,
    ownership_revision = p_revision, state = p_state, human_owned = (p_state = 'human_owned'),
    pending_request_id = case when pending_request_id = p_request_id then null else pending_request_id end,
    last_synced_at = now(),
    support_request = coalesce(p_support_request, support_request),
    last_inbound_wamid = coalesce(last_inbound_wamid, p_last_inbound_wamid),
    resolved_by = case when p_state = 'closed' then nullif(operation.payload->>'actor_agent_id','')::uuid else resolved_by end,
    closed_at = case when p_state = 'closed' then now() else closed_at end
    where organization_id = p_organization_id and organization_address = p_address and node_conversation_id = p_node_conversation_id;
  if target.status = 'spam' then return target.id; end if;
  if p_state = 'closed' then
    -- Retain assignee so the agent can still read their closed history under RLS.
    update public.conversations set status = 'closed', extra = jsonb_build_object('node_support_resolution',
      jsonb_build_object('request_id', p_request_id, 'resolved_by', operation.payload->>'actor_agent_id', 'closed_at', now())) where id = target.id;
  elsif p_state in ('bot_ready','bot_active') and coalesce(p_support_request, mapping.support_request)->>'status' is distinct from 'waiting' then
    update public.conversations set status = 'active', assigned_agent_id = null, routing_queue_id = null, routed_at = null,
      extra = jsonb_build_object('paused', null) where id = target.id;
  else
    update public.conversations set status = 'active' where id = target.id;
  end if;
  return target.id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.before_insert_on_messages()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  -- If conversation_id is already provided, proceed as is
  if new.conversation_id is not null then
    return new;
  end if;

  -- A delivery status may update an old message after its episode closes.
  if new.external_id is not null then
    select m.conversation_id into new.conversation_id from public.messages m
      where m.organization_id=new.organization_id and m.external_id=new.external_id;
    if new.conversation_id is not null then return new; end if;
  end if;
  if (new.direction='incoming' or new.content='{}'::jsonb) and exists(
    select 1 from public.chatbot_node_conversations m join public.conversations c on c.id=m.conversation_id
      where m.organization_id=new.organization_id and m.organization_address=new.organization_address
        and c.contact_address is not distinct from new.contact_address and m.episode_number is not null
  ) then
    raise exception 'Node episode context required' using errcode='40001';
  end if;

  -- Look up conversation_id from conversation table
  -- Node's durable conversation mapping survives closure; never split history.
  perform pg_advisory_xact_lock(hashtextextended(new.organization_id::text || ':' || new.organization_address || ':' || coalesce(new.contact_address,''), 123));
  select c.id into new.conversation_id from public.conversations c
    join public.chatbot_node_conversations mapping on mapping.conversation_id = c.id and mapping.organization_id = c.organization_id
    where c.organization_id = new.organization_id and c.organization_address = new.organization_address
      and c.contact_address is not distinct from new.contact_address and c.group_address is not distinct from new.group_address
      and mapping.lifecycle_enabled order by c.created_at desc, c.id desc limit 1;
  if new.conversation_id is not null then return new; end if;
  select id into new.conversation_id
  from public.conversations
  where organization_id = new.organization_id and organization_address = new.organization_address
    and contact_address is not distinct from new.contact_address
    and group_address is not distinct from new.group_address
    and status = 'active'
  order by created_at desc
  limit 1;

  -- Create conversation if it doesn't exist
  if new.conversation_id is null then
    insert into public.conversations (
      organization_id,
      organization_address,
      contact_address,
      group_address,
      service
    ) values (
      new.organization_id,
      new.organization_address,
      new.contact_address,
      new.group_address,
      new.service
    )
    returning id into new.conversation_id;
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.guard_node_human_message()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare target public.conversations;
begin
  if new.direction <> 'outgoing' or not new.status ? 'pending' or new.content = '{}'::jsonb
    or not exists(select 1 from public.agents where id = new.agent_id and not ai) then return new; end if;
  select * into target from public.conversations where id = new.conversation_id for update;
  if exists(select 1 from public.chatbot_node_conversations where conversation_id = target.id and lifecycle_enabled
    and (not human_owned or pending_request_id is not null or target.status = 'closed'
      or (episode_number is not null and (last_synced_at is null or last_synced_at < now()-interval '60 seconds')))) then
    raise exception 'Human sending is unavailable while closing or while the chatbot owns this conversation.' using errcode = '42501'; end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.preserve_message_direction()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.direction := old.direction;
  new.conversation_id := old.conversation_id;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_node_chatbot_handoff(p_organization_id uuid, p_organization_address text, p_recipient text, p_source_wamid text, p_node_conversation_id text, p_event_id uuid, p_agent_id uuid DEFAULT NULL::uuid, p_routing_queue_id uuid DEFAULT NULL::uuid, p_revision text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  target public.conversations;
  existing_receipt public.chatbot_node_handoff_receipts;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text, 117));
  select * into existing_receipt from public.chatbot_node_handoff_receipts where event_id = p_event_id;
  if found then
    if existing_receipt.organization_id <> p_organization_id then
      raise exception 'handoff event belongs to another organization' using errcode = '42501';
    end if;
    return existing_receipt.conversation_id;
  end if;
  if not exists (select 1 from public.organization_lifecycle where organization_id = p_organization_id and status = 'active') then
    raise exception 'organization is archived' using errcode = '42501';
  end if;
  if not exists (select 1 from public.chatbot_node_bridges where organization_id = p_organization_id
    and organization_address = p_organization_address and engine in ('transitioning', 'node')) then
    raise exception 'number is not managed by Node' using errcode = '23514';
  end if;
  -- The exact source message must have arrived; never infer a conversation
  -- from a different number or an older conversation for the same customer.
  select c.* into target from public.conversations c join public.messages m on m.conversation_id = c.id
    where c.organization_id = p_organization_id and c.organization_address = p_organization_address
      and c.contact_address = p_recipient and m.organization_id = p_organization_id
      and m.external_id = p_source_wamid and m.direction = 'incoming' for update of c;
  if not found then raise exception 'source customer message has not arrived' using errcode = '40001'; end if;
  if exists(select 1 from public.chatbot_node_conversations where organization_id=p_organization_id and conversation_id=target.id
    and episode_number is not null and state='closed') then return target.id; end if;
  if exists(select 1 from public.chatbot_node_conversations where organization_id = p_organization_id and conversation_id = target.id
    and lifecycle_enabled and (p_revision is null or p_revision::numeric < ownership_revision::numeric
      or (p_revision::numeric = ownership_revision::numeric and not human_owned))) then
    insert into public.chatbot_node_handoff_receipts(event_id,organization_id,conversation_id) values(p_event_id,p_organization_id,target.id);
    return target.id;
  end if;
  update public.conversations set status = 'active' where id = target.id and status = 'closed';
  if (p_agent_id is null) = (p_routing_queue_id is null) then
    raise exception 'exactly one handoff target is required' using errcode = '23514';
  end if;
  if p_routing_queue_id is not null then
    perform public.route_conversation_to_queue(target.id, p_routing_queue_id);
  else
    if not exists (select 1 from public.agents a where a.organization_id = p_organization_id
      and a.id = p_agent_id and not a.ai and a.user_id is not null
      and coalesce(a.extra->'invitation'->>'status', 'accepted') = 'accepted') then
      raise exception 'handoff requires an active tenant human agent' using errcode = '23514';
    end if;
    -- Reuse assignment constraints; clear old queue so a valid tenant agent
    -- isn't incorrectly rejected as a member of a previous routing queue.
    update public.conversations set routing_queue_id = null,
      assigned_agent_id = case when
        (public.business_hours_status(p_organization_id,null,p_agent_id)->>'configured')::boolean
        and public.business_hours_status(p_organization_id,null,p_agent_id)->>'reason'<>'available'
        then null else p_agent_id end where id = target.id;
    perform public.notify_support_unavailability(target.id,p_event_id::text,p_agent_id);
  end if;
  insert into public.chatbot_node_conversations(organization_id, organization_address, node_conversation_id, conversation_id, ownership_revision, lifecycle_enabled)
    values (p_organization_id, p_organization_address, p_node_conversation_id, target.id, coalesce(p_revision,'0'), p_revision is not null)
    on conflict (organization_id, organization_address, node_conversation_id)
    do update set human_owned = true, state = 'human_owned', ownership_revision = coalesce(p_revision,chatbot_node_conversations.ownership_revision),
      lifecycle_enabled = chatbot_node_conversations.lifecycle_enabled or p_revision is not null,last_synced_at=now();
  insert into public.chatbot_node_handoff_receipts(event_id, organization_id, conversation_id)
    values(p_event_id, p_organization_id, target.id);
  return target.id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_node_support_request(p_organization_id uuid, p_address text, p_recipient text, p_node_conversation_id text, p_event_id uuid, p_revision text, p_support_request jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  target public.conversations;
  mapping public.chatbot_node_conversations;
  receipt public.chatbot_node_handoff_receipts;
  queue_id uuid;
  agent_id uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text,117));
  select * into receipt from public.chatbot_node_handoff_receipts where event_id = p_event_id;
  if found then
    if receipt.organization_id <> p_organization_id then raise exception 'event belongs to another tenant' using errcode='42501'; end if;
    return receipt.conversation_id;
  end if;
  if not public.is_organization_active(p_organization_id) or not public.is_node_managed_number(p_organization_id,p_address) then
    raise exception 'tenant or Node binding unavailable' using errcode='42501'; end if;
  if p_revision !~ '^[0-9]+$' or p_support_request->>'status' is distinct from 'waiting'
    or p_support_request->>'id' is null or p_support_request->>'source_wamid' is null then
    raise exception 'invalid support request' using errcode='22023'; end if;
  perform (p_support_request->>'id')::uuid;
  select c.* into target from public.conversations c join public.messages m on m.conversation_id=c.id
    where c.organization_id=p_organization_id and c.organization_address=p_address and c.contact_address=p_recipient
      and m.organization_id=p_organization_id and m.external_id=p_support_request->>'source_wamid' and m.direction='incoming'
    for update of c;
  if not found then raise exception 'source message has not arrived' using errcode='40001'; end if;
  select * into mapping from public.chatbot_node_conversations where organization_id=p_organization_id
    and organization_address=p_address and node_conversation_id=p_node_conversation_id for update;
  if found and mapping.conversation_id <> target.id then raise exception 'conversation mapping mismatch' using errcode='23514'; end if;
  if mapping.episode_number is not null and mapping.state='closed' then return target.id; end if;
  -- A newer bot snapshot can arrive before the request's independent outbox
  -- event. Route that same waiting request once; never revive a handled request.
  if mapping.lifecycle_enabled and p_revision::numeric <= mapping.ownership_revision::numeric
    and not (mapping.support_request->>'id'=p_support_request->>'id' and mapping.support_request->>'status'='waiting') then
    insert into public.chatbot_node_handoff_receipts(event_id,organization_id,conversation_id) values(p_event_id,p_organization_id,target.id);
    return target.id;
  end if;
  if mapping.human_owned and mapping.lifecycle_enabled then raise exception 'conversation already human owned' using errcode='40001'; end if;
  if mapping.support_request->>'status'='waiting' and mapping.support_request->>'id' <> p_support_request->>'id' then
    raise exception 'another support request is pending' using errcode='23514'; end if;
  if mapping.pending_request_id is not null then raise exception 'conversation synchronization pending' using errcode='40001'; end if;
  queue_id := (p_support_request->'target'->>'routing_queue_id')::uuid;
  agent_id := (p_support_request->'target'->>'agent_id')::uuid;
  if (queue_id is null) = (agent_id is null) then raise exception 'exactly one support target required' using errcode='23514'; end if;
  update public.conversations set status='active' where id=target.id and status='closed';
  if queue_id is not null then perform public.route_conversation_to_queue(target.id,queue_id);
  else
    if not exists(select 1 from public.agents where id=agent_id and organization_id=p_organization_id and not ai and user_id is not null
      and coalesce(extra->'invitation'->>'status','accepted')='accepted') then raise exception 'accepted tenant agent required' using errcode='23514'; end if;
    update public.conversations set routing_queue_id=null,
      assigned_agent_id=case when
        (public.business_hours_status(p_organization_id,null,agent_id)->>'configured')::boolean
        and public.business_hours_status(p_organization_id,null,agent_id)->>'reason'<>'available'
        then null else agent_id end where id=target.id;
    perform public.notify_support_unavailability(target.id,p_support_request->>'id',agent_id);
  end if;
  insert into public.chatbot_node_conversations(organization_id,organization_address,node_conversation_id,conversation_id,
    human_owned,lifecycle_enabled,ownership_revision,state,support_request,last_inbound_wamid)
    values(p_organization_id,p_address,p_node_conversation_id,target.id,false,true,p_revision,'bot_ready',p_support_request,p_support_request->>'source_wamid')
    on conflict(organization_id,organization_address,node_conversation_id) do update set
      human_owned=false,lifecycle_enabled=true,ownership_revision=greatest(p_revision::numeric,chatbot_node_conversations.ownership_revision::numeric)::text,
      state='bot_ready',support_request=p_support_request,last_synced_at=now();
  insert into public.chatbot_node_handoff_receipts(event_id,organization_id,conversation_id) values(p_event_id,p_organization_id,target.id);
  return target.id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.track_node_customer_message()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.direction <> 'incoming' or new.external_id is null or new.content = '{}'::jsonb then return new; end if;
  perform 1 from public.conversations where id = new.conversation_id for update;
  update public.chatbot_node_conversations set last_inbound_wamid = new.external_id where organization_id = new.organization_id
    and conversation_id = new.conversation_id;
  if exists(select 1 from public.chatbot_node_conversations where conversation_id = new.conversation_id and lifecycle_enabled
      and episode_number is null and not human_owned and pending_request_id is null and support_request->>'status' is distinct from 'waiting') then
    update public.conversations set status = 'active', assigned_agent_id = null, routing_queue_id = null, routed_at = null
      where id = new.conversation_id and status = 'closed';
  end if;
  return new;
end;
$function$
;

-- Migra omits ACLs for newly created/signature-changed functions.
revoke all on function public.resolve_node_conversation_episode(uuid,text,text,text,integer,text) from public,anon,authenticated;
grant execute on function public.resolve_node_conversation_episode(uuid,text,text,text,integer,text) to service_role;
revoke all on function public.list_previous_conversations_page(uuid,uuid,integer,integer,text) from public,anon;
grant execute on function public.list_previous_conversations_page(uuid,uuid,integer,integer,text) to authenticated;
revoke all on function public.record_external_chatbot_reply(uuid,uuid,text,text,text,timestamptz,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.record_external_chatbot_reply(uuid,uuid,text,text,text,timestamptz,jsonb,uuid) to service_role;

-- Cron is managed in migrations; the worker's execution budget is 45 seconds.
select cron.schedule('node-chatbot-bridge-every-minute','* * * * *',
  $$select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name='edge_functions_url') || '/node-chatbot-bridge-worker',
    headers := jsonb_build_object('content-type','application/json',
      'authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='edge_functions_token')),
    body := '{}'::jsonb, timeout_milliseconds := 55000
  )$$
);


