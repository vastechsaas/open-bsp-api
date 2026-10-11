
drop function if exists "public"."notify_support_unavailability"(p_conversation_id uuid, p_request_id text, p_agent_id uuid);

drop function if exists "public"."record_node_support_request"(p_organization_id uuid, p_address text, p_recipient text, p_node_conversation_id text, p_event_id uuid, p_revision text, p_support_request jsonb);

drop function if exists "public"."route_conversation_to_queue"(p_conversation_id uuid, p_routing_queue_id uuid);

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.notify_support_unavailability(p_conversation_id uuid, p_request_id text, p_agent_id uuid DEFAULT NULL::uuid, p_handoff_text text DEFAULT NULL::text, p_always boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c public.conversations; availability jsonb; root jsonb; body text; latest_inbound timestamptz;
begin
  select * into c from public.conversations where id=p_conversation_id for update;
  if not found or c.status<>'active' or not public.is_organization_active(c.organization_id)
    or exists(select 1 from public.contacts_addresses where organization_id=c.organization_id
      and address=c.contact_address and status='blocked') then return; end if;
  availability := public.business_hours_status(c.organization_id,c.routing_queue_id,p_agent_id);
  if not p_always and (not (availability->>'configured')::boolean or availability->>'reason' not in ('outside_hours','no_agents')) then return; end if;
  select extra->'business_hours' into root from public.organizations where id=c.organization_id;
  -- Select exactly one message. Availability wins over the branch override;
  -- otherwise an existing custom node message wins over the shared default.
  body := case when (availability->>'configured')::boolean and availability->>'reason'='outside_hours' then
    coalesce(root->>'outside_hours_message','Our support team is currently outside business hours. Your request is queued and will be reviewed when support is available.')
    when (availability->>'configured')::boolean and availability->>'reason'='no_agents' then
      coalesce(root->>'no_agents_message','All support agents are currently unavailable. Your request is queued for the next available support agent.')
    else coalesce(nullif(btrim(p_handoff_text),''),root->>'handoff_message',
      E'Your request has been sent to our support team.\n\nYou can continue using the chatbot while you wait. We’ll let you know when an agent takes over.') end;
  if length(body) not between 1 and 4096 then raise exception 'Support message must contain 1 to 4096 characters' using errcode='22023'; end if;
  -- Do not originate a free-form notice outside the customer service window.
  select max(timestamp) into latest_inbound from public.messages where conversation_id=c.id and direction='incoming' and content<>'{}'::jsonb;
  if latest_inbound is null or latest_inbound < now()-interval '24 hours' then return; end if;
  insert into public.messages(id,organization_id,conversation_id,direction,service,organization_address,contact_address,
    group_address,content,timestamp)
  values(md5('support-availability:'||c.id::text||':'||p_request_id)::uuid,c.organization_id,c.id,
    'outgoing',c.service,c.organization_address,c.contact_address,c.group_address,
    jsonb_build_object('version','1','type','text','kind','text','text',body),now())
  on conflict(id) do nothing;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_node_support_request(p_organization_id uuid, p_address text, p_recipient text, p_node_conversation_id text, p_event_id uuid, p_revision text, p_support_request jsonb, p_acknowledgment jsonb DEFAULT NULL::jsonb)
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
  original_receipt public.chatbot_node_handoff_receipts;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text,117));
  select * into receipt from public.chatbot_node_handoff_receipts where event_id = p_event_id;
  if found then
    if receipt.organization_id <> p_organization_id then raise exception 'event belongs to another tenant' using errcode='42501'; end if;
    return receipt.conversation_id;
  end if;
  if p_acknowledgment is not null then
    if jsonb_typeof(p_acknowledgment) <> 'object'
      or exists(select 1 from jsonb_object_keys(p_acknowledgment) k where k not in ('text','original_event_id'))
      or (p_acknowledgment ? 'text' and (jsonb_typeof(p_acknowledgment->'text') <> 'string'
        or length(btrim(p_acknowledgment->>'text')) not between 1 and 4096)) then
      raise exception 'Invalid handoff acknowledgment' using errcode='22023'; end if;
    if p_acknowledgment ? 'original_event_id' then
      select * into original_receipt from public.chatbot_node_handoff_receipts
        where event_id=(p_acknowledgment->>'original_event_id')::uuid;
      if not found then raise exception 'original handoff has not arrived' using errcode='40001'; end if;
      if original_receipt.organization_id <> p_organization_id then raise exception 'handoff belongs to another tenant' using errcode='42501'; end if;
    end if;
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
  if p_acknowledgment ? 'original_event_id' then
    if original_receipt.conversation_id <> target.id or mapping.support_request->>'id' is distinct from p_support_request->>'id' then
      raise exception 'acknowledgment conversation mismatch' using errcode='23514'; end if;
    -- A repeat request only acknowledges. Never reroute or clear an assignment.
    perform public.notify_support_unavailability(target.id,p_event_id::text,agent_id,p_acknowledgment->>'text',true);
    insert into public.chatbot_node_handoff_receipts(event_id,organization_id,conversation_id) values(p_event_id,p_organization_id,target.id);
    return target.id;
  end if;
  update public.conversations set status='active' where id=target.id and status='closed';
  if queue_id is not null then perform public.route_conversation_to_queue(target.id,queue_id,p_acknowledgment is null);
  else
    if not exists(select 1 from public.agents where id=agent_id and organization_id=p_organization_id and not ai and user_id is not null
      and coalesce(extra->'invitation'->>'status','accepted')='accepted') then raise exception 'accepted tenant agent required' using errcode='23514'; end if;
    update public.conversations set routing_queue_id=null,
      assigned_agent_id=case when
        (public.business_hours_status(p_organization_id,null,agent_id)->>'configured')::boolean
        and public.business_hours_status(p_organization_id,null,agent_id)->>'reason'<>'available'
        then null else agent_id end where id=target.id;
    if p_acknowledgment is null then perform public.notify_support_unavailability(target.id,p_support_request->>'id',agent_id); end if;
  end if;
  insert into public.chatbot_node_conversations(organization_id,organization_address,node_conversation_id,conversation_id,
    human_owned,lifecycle_enabled,ownership_revision,state,support_request,last_inbound_wamid)
    values(p_organization_id,p_address,p_node_conversation_id,target.id,false,true,p_revision,'bot_ready',p_support_request,p_support_request->>'source_wamid')
    on conflict(organization_id,organization_address,node_conversation_id) do update set
      human_owned=false,lifecycle_enabled=true,ownership_revision=greatest(p_revision::numeric,chatbot_node_conversations.ownership_revision::numeric)::text,
      state='bot_ready',support_request=p_support_request,last_synced_at=now();
  if p_acknowledgment is not null then
    perform public.notify_support_unavailability(target.id,p_event_id::text,agent_id,p_acknowledgment->>'text',true);
  end if;
  insert into public.chatbot_node_handoff_receipts(event_id,organization_id,conversation_id) values(p_event_id,p_organization_id,target.id);
  return target.id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.route_conversation_to_queue(p_conversation_id uuid, p_routing_queue_id uuid, p_send_notice boolean DEFAULT true)
 RETURNS public.conversations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  target_conversation public.conversations;
  destination_queue public.routing_queues;
  previous_routing_queue_id uuid;
  previous_queue_name text;
  route_time timestamp with time zone := now();
begin
  select conversation.* into target_conversation
  from public.conversations conversation
  where conversation.id = p_conversation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'conversation not found';
  end if;

  if target_conversation.status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'only active conversations can be routed';
  end if;

  select queue.* into destination_queue
  from public.routing_queues queue
  where queue.id = p_routing_queue_id
    and queue.organization_id = target_conversation.organization_id
    and queue.status = 'active';

  if not found then
    raise exception using
      errcode = '23514',
      message = 'routing destination must be an active queue in the same organization';
  end if;

  previous_routing_queue_id := target_conversation.routing_queue_id;

  if previous_routing_queue_id is not null then
    select queue.name into previous_queue_name
    from public.routing_queues queue
    where queue.id = previous_routing_queue_id
      and queue.organization_id = target_conversation.organization_id;
  end if;

  update public.conversations conversation
  set routing_queue_id = p_routing_queue_id,
      routed_at = route_time,
      assigned_agent_id = null
  where conversation.id = p_conversation_id
  returning * into target_conversation;

  insert into public.conversation_routing_events (
    organization_id,
    conversation_id,
    previous_routing_queue_id,
    previous_routing_queue_name,
    destination_routing_queue_id,
    destination_routing_queue_name,
    actor_agent_id,
    source,
    explanation,
    created_at
  ) values (
    target_conversation.organization_id,
    target_conversation.id,
    previous_routing_queue_id,
    previous_queue_name,
    destination_queue.id,
    destination_queue.name,
    null,
    'chatbot_handoff',
    null,
    route_time
  );

  target_conversation := public.try_auto_assign_conversation(
    target_conversation.id,
    'chatbot_handoff'
  );

  if p_send_notice then
    perform public.notify_support_unavailability(target_conversation.id,
      'route:' || route_time::text);
  end if;

  return target_conversation;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.guard_business_hours_settings()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s jsonb := new.extra->'business_hours'; q record; field text;
begin
  if s is null or s='null'::jsonb then return new; end if;
  if tg_op='UPDATE' and s is not distinct from old.extra->'business_hours' then return new; end if;
  perform public.validate_business_hours_schedule(s);
  if s ? 'queue_overrides' then
    if jsonb_typeof(s->'queue_overrides') <> 'object' then
      raise exception 'Queue overrides must be an object' using errcode='22023'; end if;
    for q in select * from jsonb_each(s->'queue_overrides') loop
      -- JSON merge uses null tombstones to remove an override atomically.
      if q.value='null'::jsonb then continue; end if;
      if not exists(select 1 from public.routing_queues where organization_id=new.id and id=q.key::uuid) then
        raise exception 'Queue override must belong to a tenant queue' using errcode='22023'; end if;
      if q.value ? 'queue_overrides' then raise exception 'Nested queue overrides are unsupported' using errcode='22023'; end if;
      perform public.validate_business_hours_schedule(q.value);
    end loop;
  end if;
  foreach field in array array['handoff_message','outside_hours_message','no_agents_message'] loop
    if s ? field and (jsonb_typeof(s->field)<>'string' or length(btrim(s->>field)) not between 1 and 4096) then
      raise exception 'Unavailable support messages must contain 1 to 4096 characters' using errcode='22023'; end if;
  end loop;
  return new;
end;
$function$
;

-- The schema diff recreates changed signatures but omits function ACLs.
-- Reapply the access rules declared in the schema sources.
revoke all on function public.notify_support_unavailability(uuid,text,uuid,text,boolean) from public,anon,authenticated;
revoke all on function public.record_node_support_request(uuid,text,text,text,uuid,text,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.record_node_support_request(uuid,text,text,text,uuid,text,jsonb,jsonb) to service_role;
revoke execute on function public.route_conversation_to_queue(uuid,uuid,boolean) from public;


