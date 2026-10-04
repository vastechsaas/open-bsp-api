-- A support request is not a transfer of execution ownership.
create function public.record_node_support_request(
  p_organization_id uuid, p_address text, p_recipient text, p_node_conversation_id text,
  p_event_id uuid, p_revision text, p_support_request jsonb
) returns uuid language plpgsql security definer set search_path = '' as $$
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
$$;
revoke all on function public.record_node_support_request(uuid,text,text,text,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.record_node_support_request(uuid,text,text,text,uuid,text,jsonb) to service_role;

create function public.guard_node_takeover_assignment() returns trigger language plpgsql set search_path='' as $$
begin
  if (new.assigned_agent_id is distinct from old.assigned_agent_id or new.routing_queue_id is distinct from old.routing_queue_id)
    and exists(select 1 from public.chatbot_node_conversations where conversation_id=old.id and pending_request_id is not null) then
    raise exception 'Wait for conversation synchronization before changing assignment.' using errcode='40001'; end if;
  return new;
end;
$$;
create trigger node_takeover_assignment_guard before update of assigned_agent_id,routing_queue_id on public.conversations
  for each row execute function public.guard_node_takeover_assignment();
