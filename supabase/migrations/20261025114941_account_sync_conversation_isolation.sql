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
      and not (p_action = 'takeover' and target.assigned_agent_id is null and (
        (target.routing_queue_id is not null and exists(select 1 from public.routing_queue_members
          where organization_id = p_organization_id and routing_queue_id = target.routing_queue_id and agent_id = actor))
        or exists(select 1 from public.chatbot_node_conversations where organization_id=p_organization_id
          and conversation_id=target.id and support_request->>'status'='waiting'
          and support_request->'target'->>'agent_id'=actor::text)))))) then
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
  if p_action='takeover' and role='agent' and
    (public.business_hours_status(p_organization_id,target.routing_queue_id)->>'open')::boolean is not true then
    raise exception 'Support is outside business hours. A manager can override the schedule.' using errcode='23514';
  end if;
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
    and organization_address = mapping.organization_address and action <> 'account-sync' and status not in ('succeeded','failed')
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


