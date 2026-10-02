-- Generated retry fencing fix; spurious existing-table revoke drift omitted.
set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.before_insert_on_messages()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  -- If conversation_id is already provided, proceed as is
  if new.conversation_id is not null then
    return new;
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

CREATE OR REPLACE FUNCTION public.begin_node_conversation_operation(p_organization_id uuid, p_conversation_id uuid, p_request_id uuid, p_action text, p_observed_last_inbound_wamid text, p_expected_revision text)
 RETURNS public.chatbot_node_operations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.complete_node_chatbot_operation(p_request_id uuid, p_phase text, p_result jsonb)
 RETURNS public.chatbot_node_operations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  operation public.chatbot_node_operations;
begin
  select * into operation from public.chatbot_node_operations where request_id = p_request_id for update;
  if not found then raise exception 'operation not found' using errcode = 'P0002'; end if;
  if operation.phase <> p_phase or operation.status = 'succeeded' then return operation; end if;
  if operation.status not in ('in_flight', 'reconciling') then raise exception 'operation is not outstanding' using errcode = '23514'; end if;
  if operation.conversation_id is not null then
    perform public.apply_node_conversation_lifecycle(operation.organization_id, operation.organization_address,
      operation.payload->>'node_conversation_id', (select contact_address from public.conversations where id = operation.conversation_id),
      p_result->>'revision',p_result->>'state',p_result->>'last_inbound_wamid',p_result->>'last_inbound_wamid',operation.request_id);
    update public.chatbot_node_operations set status = 'succeeded', result = p_result, next_attempt_at = null, last_error = null
      where request_id = p_request_id returning * into operation;
    if operation.action = 'resolve-and-close' then
      -- Resolution attribution survives even if reconciliation already sees a
      -- newer reopened/human-owned revision. Do not change its ownership/status.
      update public.chatbot_node_conversations set resolved_by = (operation.payload->>'actor_agent_id')::uuid,
        closed_at = coalesce(closed_at, operation.created_at) where conversation_id = operation.conversation_id;
    end if;
    update public.chatbot_node_conversations set pending_request_id = null where conversation_id = operation.conversation_id and pending_request_id = p_request_id;
    return operation;
  end if;
  if p_phase = 'prepare' then
    if p_result->>'flow_id' is null or p_result->>'version_id' is null then raise exception 'invalid remote version' using errcode = '23514'; end if;
    update public.chatbot_node_operations set phase = 'activate', status = 'pending', attempts = 0,
      result = p_result, next_attempt_at = null, last_error = null where request_id = p_request_id returning * into operation;
    return operation;
  end if;
  update public.chatbot_node_operations set status = 'succeeded', result = p_result,
    next_attempt_at = null, last_error = null where request_id = p_request_id returning * into operation;
  update public.chatbot_node_bridges set
    engine = case when p_phase = 'deactivate' or (p_phase = 'restore' and p_result->>'enabled' = 'false') then 'disabled' else 'node' end,
    sync_status = case when p_phase = 'deactivate' or (p_phase = 'restore' and p_result->>'enabled' = 'false') then 'disabled' when p_phase = 'suspend' then 'suspended' else 'active' end,
    node_flow_id = case when p_phase = 'activate' then p_result->>'flow_id' else node_flow_id end,
    node_version_id = case when p_phase = 'activate' then p_result->>'version_id' else node_version_id end,
    flow_id = case when p_phase = 'activate' then (operation.payload->>'source_flow_id')::uuid else flow_id end,
    flow_version_id = case when p_phase = 'activate' then (operation.payload->>'source_version_id')::uuid else flow_version_id end,
    definition_hash = case when p_phase = 'activate' then operation.payload->>'definition_hash' else definition_hash end,
    last_error = null, updated_at = now()
    where organization_id = operation.organization_id and organization_address = operation.organization_address;
  if p_phase = 'resume' then
    update public.chatbot_node_conversations set human_owned = false where organization_id = operation.organization_id
      and organization_address = operation.organization_address and node_conversation_id = operation.payload->>'node_conversation_id';
  end if;
  return operation;
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
    update public.conversations set routing_queue_id = null, assigned_agent_id = p_agent_id where id = target.id;
  end if;
  insert into public.chatbot_node_conversations(organization_id, organization_address, node_conversation_id, conversation_id, ownership_revision, lifecycle_enabled)
    values (p_organization_id, p_organization_address, p_node_conversation_id, target.id, coalesce(p_revision,'0'), p_revision is not null)
    on conflict (organization_id, organization_address, node_conversation_id)
    do update set human_owned = true, state = 'human_owned', ownership_revision = coalesce(p_revision,chatbot_node_conversations.ownership_revision),
      lifecycle_enabled = chatbot_node_conversations.lifecycle_enabled or p_revision is not null;
  insert into public.chatbot_node_handoff_receipts(event_id, organization_id, conversation_id)
    values(p_event_id, p_organization_id, target.id);
  return target.id;
end;
$function$
;

