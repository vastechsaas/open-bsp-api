-- Node owns execution state; revisions fence delayed control-plane/queue events.
create function public.apply_node_conversation_lifecycle(
  p_organization_id uuid, p_address text, p_node_conversation_id text,
  p_recipient text, p_revision text, p_state text, p_last_inbound_wamid text,
  p_source_wamid text default null, p_request_id uuid default null
) returns uuid language plpgsql security definer set search_path = '' as $$
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
    pending_request_id = null,
    last_inbound_wamid = coalesce(last_inbound_wamid, p_last_inbound_wamid),
    resolved_by = case when p_state = 'closed' then nullif(operation.payload->>'actor_agent_id','')::uuid else resolved_by end,
    closed_at = case when p_state = 'closed' then now() else closed_at end
    where organization_id = p_organization_id and organization_address = p_address and node_conversation_id = p_node_conversation_id;
  if target.status = 'spam' then return target.id; end if;
  if p_state = 'closed' then
    -- Retain assignee so the agent can still read their closed history under RLS.
    update public.conversations set status = 'closed', extra = jsonb_build_object('node_support_resolution',
      jsonb_build_object('request_id', p_request_id, 'resolved_by', operation.payload->>'actor_agent_id', 'closed_at', now())) where id = target.id;
  elsif p_state in ('bot_ready','bot_active') then
    update public.conversations set status = 'active', assigned_agent_id = null, routing_queue_id = null, routed_at = null,
      extra = jsonb_build_object('paused', null) where id = target.id;
  else
    update public.conversations set status = 'active' where id = target.id;
  end if;
  return target.id;
end;
$$;
revoke all on function public.apply_node_conversation_lifecycle(uuid,text,text,text,text,text,text,text,uuid) from public, anon, authenticated;
grant execute on function public.apply_node_conversation_lifecycle(uuid,text,text,text,text,text,text,text,uuid) to service_role;

create function public.begin_node_conversation_operation(
  p_organization_id uuid, p_conversation_id uuid, p_request_id uuid, p_action text,
  p_observed_last_inbound_wamid text, p_expected_revision text
) returns public.chatbot_node_operations language plpgsql security definer set search_path = '' as $$
declare
  target public.conversations;
  mapping public.chatbot_node_conversations;
  actor uuid;
  role public.role;
  latest_wamid text;
  operation public.chatbot_node_operations;
  body jsonb;
begin
  if auth.uid() is null or p_action not in ('resolve-and-close','resume') then
    raise exception 'authenticated conversation action required' using errcode = '42501'; end if;
  select * into target from public.conversations where organization_id = p_organization_id and id = p_conversation_id for update;
  actor := public.get_current_human_agent_id(p_organization_id);
  role := public.get_request_organization_role(p_organization_id);
  if target.id is null or actor is null or role not in ('owner','admin','supervisor','agent')
    or (role = 'agent' and (p_action = 'resume' or target.assigned_agent_id is distinct from actor)) then
    raise exception 'conversation action is not permitted' using errcode = '42501'; end if;
  body := jsonb_build_object('observed_last_inbound_wamid',p_observed_last_inbound_wamid,
    'expected_revision',p_expected_revision,'actor_agent_id',actor);
  select * into operation from public.chatbot_node_operations where request_id = p_request_id;
  if found then
    if operation.organization_id <> p_organization_id or operation.conversation_id is distinct from p_conversation_id
      or operation.action <> p_action or operation.payload - 'node_conversation_id' <> body then
      raise exception 'request ID cannot be reused with different data' using errcode = '23514'; end if;
    if operation.status <> 'failed' then return operation; end if;
  end if;
  select * into mapping from public.chatbot_node_conversations where organization_id = p_organization_id and conversation_id = p_conversation_id for update;
  if not found or not mapping.human_owned or target.status <> 'active' or not public.is_organization_active(p_organization_id) then
    raise exception 'conversation is not in active human support' using errcode = '23514'; end if;
  if p_expected_revision !~ '^[0-9]+$' or p_expected_revision::numeric < mapping.ownership_revision::numeric then
    raise exception 'conversation ownership changed' using errcode = '40001'; end if;
  latest_wamid := mapping.last_inbound_wamid;
  if latest_wamid is null then
    select external_id into latest_wamid from public.messages where organization_id = p_organization_id and conversation_id = p_conversation_id
      and direction = 'incoming' and external_id is not null order by created_at desc, id desc limit 1;
  end if;
  if latest_wamid is distinct from p_observed_last_inbound_wamid then
    raise exception 'A new customer message arrived—review it before closing.' using errcode = '40001'; end if;
  if exists(select 1 from public.messages m join public.agents a on a.id = m.agent_id where m.conversation_id = target.id
    and m.direction = 'outgoing' and not a.ai and m.status ? 'pending' and not m.status ?| array['sent','delivered','read','failed']) then
    raise exception 'Wait for pending human messages to finish sending.' using errcode = '23514'; end if;
  if exists(select 1 from public.chatbot_node_operations where organization_id = p_organization_id
    and organization_address = mapping.organization_address and status not in ('succeeded','failed')
    and (conversation_id is null or conversation_id = target.id)) then
    raise exception 'conversation has an unresolved bridge operation' using errcode = '23514'; end if;
  if operation.request_id is not null then
    -- Manual retry reclaims ownership and its durable operation atomically, with
    -- exactly the same access/message/send checks as the original request.
    update public.chatbot_node_operations set status='reconciling',attempts=0,next_attempt_at=null
      where request_id=p_request_id returning * into operation;
  else
    insert into public.chatbot_node_operations(request_id,organization_id,organization_address,conversation_id,action,phase,payload)
      values(p_request_id,p_organization_id,mapping.organization_address,target.id,p_action,p_action,
        body || jsonb_build_object('node_conversation_id',mapping.node_conversation_id)) returning * into operation;
  end if;
  update public.chatbot_node_conversations set pending_request_id = p_request_id, lifecycle_enabled = true,
    last_inbound_wamid = latest_wamid where organization_id = p_organization_id and conversation_id = target.id;
  return operation;
end;
$$;
revoke all on function public.begin_node_conversation_operation(uuid,uuid,uuid,text,text,text) from public,anon;
grant execute on function public.begin_node_conversation_operation(uuid,uuid,uuid,text,text,text) to authenticated;

create function public.guard_node_human_message() returns trigger language plpgsql security definer set search_path = '' as $$
declare target public.conversations;
begin
  if new.direction <> 'outgoing' or not new.status ? 'pending' or new.content = '{}'::jsonb
    or not exists(select 1 from public.agents where id = new.agent_id and not ai) then return new; end if;
  select * into target from public.conversations where id = new.conversation_id for update;
  if exists(select 1 from public.chatbot_node_conversations where conversation_id = target.id and lifecycle_enabled
    and (not human_owned or pending_request_id is not null or target.status = 'closed')) then
    raise exception 'Human sending is unavailable while closing or while the chatbot owns this conversation.' using errcode = '42501'; end if;
  return new;
end;
$$;
create trigger node_human_message_guard before insert on public.messages for each row execute function public.guard_node_human_message();

create function public.track_node_customer_message() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.direction <> 'incoming' or new.external_id is null or new.content = '{}'::jsonb then return new; end if;
  perform 1 from public.conversations where id = new.conversation_id for update;
  update public.chatbot_node_conversations set last_inbound_wamid = new.external_id where organization_id = new.organization_id
    and conversation_id = new.conversation_id;
  if exists(select 1 from public.chatbot_node_conversations where conversation_id = new.conversation_id and lifecycle_enabled
    and not human_owned and pending_request_id is null) then
    update public.conversations set status = 'active', assigned_agent_id = null, routing_queue_id = null, routed_at = null
      where id = new.conversation_id and status = 'closed';
  end if;
  return new;
end;
$$;
create trigger node_customer_message_track after insert on public.messages for each row execute function public.track_node_customer_message();

-- Do not let a generic status edit bypass Node confirmation. Trusted lifecycle
-- RPCs run as the function owner, while ordinary REST writes remain guarded.
create function public.guard_node_conversation_status() returns trigger language plpgsql set search_path = '' as $$
begin
  if current_user in ('authenticated','anon') and new.status is distinct from old.status
    and exists(select 1 from public.chatbot_node_conversations where conversation_id = old.id and lifecycle_enabled) then
    raise exception 'Use Resolve & close or Return to chatbot for this conversation.' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger node_conversation_status_guard before update of status on public.conversations
  for each row execute function public.guard_node_conversation_status();
