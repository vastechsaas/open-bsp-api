
set check_function_bodies = off;

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
  if auth.uid() is null or p_action not in ('resolve-and-close','resume','takeover') then
    raise exception 'authenticated conversation action required' using errcode = '42501'; end if;
  select * into target from public.conversations where organization_id = p_organization_id and id = p_conversation_id for update;
  actor := public.get_current_human_agent_id(p_organization_id);
  role := public.get_request_organization_role(p_organization_id);
  if target.id is null or actor is null or role not in ('owner','admin','supervisor','agent')
    or (role = 'agent' and (p_action = 'resume' or (target.assigned_agent_id is distinct from actor
      and not (p_action = 'takeover' and target.assigned_agent_id is null and target.routing_queue_id is not null
        and exists(select 1 from public.routing_queue_members where organization_id = p_organization_id and routing_queue_id = target.routing_queue_id and agent_id = actor))))) then
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
  if not found or (case when p_action = 'takeover' then mapping.human_owned or mapping.support_request->>'status' is distinct from 'waiting' else not mapping.human_owned end)
    or target.status <> 'active' or not public.is_organization_active(p_organization_id) then
    raise exception 'conversation is not in active human support' using errcode = '23514'; end if;
  if p_expected_revision !~ '^[0-9]+$' or p_expected_revision::numeric < mapping.ownership_revision::numeric
    or (p_action = 'takeover' and p_expected_revision::numeric <> mapping.ownership_revision::numeric) then
    raise exception 'conversation ownership changed' using errcode = '40001'; end if;
  latest_wamid := mapping.last_inbound_wamid;
  if latest_wamid is null then
    select external_id into latest_wamid from public.messages where organization_id = p_organization_id and conversation_id = p_conversation_id
      and direction = 'incoming' and external_id is not null order by created_at desc, id desc limit 1;
  end if;
  if p_action <> 'takeover' and latest_wamid is distinct from p_observed_last_inbound_wamid then
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
  if p_action = 'takeover' and target.assigned_agent_id is distinct from actor then
    -- Manager override can claim a queued chat without pretending to be a queue
    -- member. The original queue remains in support_request.target for history.
    update public.conversations set assigned_agent_id = actor,
      routing_queue_id = case when role in ('owner','admin','supervisor') and not exists(
        select 1 from public.routing_queue_members where organization_id=p_organization_id
          and routing_queue_id=target.routing_queue_id and agent_id=actor) then null else routing_queue_id end
      where id = target.id;
  end if;
  update public.chatbot_node_conversations set pending_request_id = p_request_id, lifecycle_enabled = true,
    last_inbound_wamid = latest_wamid where organization_id = p_organization_id and conversation_id = target.id;
  return operation;
end;
$function$
;

-- Repeat the explicit source ACLs for local databases that applied the original
-- generated migration before the db-diff permission-noise review.
revoke all on function public.apply_node_conversation_lifecycle(uuid,text,text,text,text,text,text,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.apply_node_conversation_lifecycle(uuid,text,text,text,text,text,text,text,uuid,jsonb) to service_role;
revoke all on function public.record_node_support_request(uuid,text,text,text,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.record_node_support_request(uuid,text,text,text,uuid,text,jsonb) to service_role;

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
    update public.conversations set routing_queue_id=null,assigned_agent_id=agent_id where id=target.id;
  end if;
  insert into public.chatbot_node_conversations(organization_id,organization_address,node_conversation_id,conversation_id,
    human_owned,lifecycle_enabled,ownership_revision,state,support_request,last_inbound_wamid)
    values(p_organization_id,p_address,p_node_conversation_id,target.id,false,true,p_revision,'bot_ready',p_support_request,p_support_request->>'source_wamid')
    on conflict(organization_id,organization_address,node_conversation_id) do update set
      human_owned=false,lifecycle_enabled=true,ownership_revision=greatest(p_revision::numeric,chatbot_node_conversations.ownership_revision::numeric)::text,
      state='bot_ready',support_request=p_support_request;
  insert into public.chatbot_node_handoff_receipts(event_id,organization_id,conversation_id) values(p_event_id,p_organization_id,target.id);
  return target.id;
end;
$function$
;
