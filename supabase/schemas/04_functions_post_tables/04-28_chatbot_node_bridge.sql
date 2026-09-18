create function public.record_node_chatbot_handoff(
  p_organization_id uuid, p_organization_address text, p_recipient text,
  p_source_wamid text, p_node_conversation_id text, p_event_id uuid,
  p_agent_id uuid default null, p_routing_queue_id uuid default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
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
  insert into public.chatbot_node_conversations(organization_id, organization_address, node_conversation_id, conversation_id)
    values (p_organization_id, p_organization_address, p_node_conversation_id, target.id)
    on conflict (organization_id, organization_address, node_conversation_id)
    do update set human_owned = true;
  insert into public.chatbot_node_handoff_receipts(event_id, organization_id, conversation_id)
    values(p_event_id, p_organization_id, target.id);
  return target.id;
end;
$$;
revoke all on function public.record_node_chatbot_handoff(uuid,text,text,text,text,uuid,uuid,uuid) from public, anon, authenticated;
grant execute on function public.record_node_chatbot_handoff(uuid,text,text,text,text,uuid,uuid,uuid) to service_role;

create function public.enqueue_node_chatbot_operation(
  p_organization_id uuid, p_address text, p_company_id text, p_request_id uuid,
  p_action text, p_payload jsonb
) returns public.chatbot_node_operations
language plpgsql security definer set search_path = '' as $$
declare
  operation public.chatbot_node_operations;
  binding public.chatbot_node_bridges;
begin
  perform 1 from public.organizations_addresses where organization_id = p_organization_id
    and address = p_address and service = 'whatsapp' for update;
  if not found then raise exception 'WhatsApp number not found' using errcode = 'P0002'; end if;
  select * into operation from public.chatbot_node_operations where request_id = p_request_id;
  if found then
    if operation.organization_id <> p_organization_id or operation.organization_address <> p_address
      or operation.action <> p_action or operation.payload <> p_payload then
      raise exception 'request ID cannot be reused with different data' using errcode = '23514';
    end if;
    return operation;
  end if;
  if p_action in ('activate', 'restore', 'resume') and not exists (
    select 1 from public.organization_lifecycle where organization_id = p_organization_id and status = 'active'
  ) then raise exception 'organization is archived' using errcode = '42501'; end if;
  if exists (select 1 from public.chatbot_node_operations where organization_id = p_organization_id
    and organization_address = p_address and status not in ('succeeded', 'failed')) then
    raise exception 'number has an unresolved bridge operation' using errcode = '23514';
  end if;
  if p_action = 'activate' then
    if exists (select 1 from public.chatbot_flow_deployments where organization_id = p_organization_id
      and organization_address = p_address) or exists (
      select 1 from public.chatbot_flow_runs r join public.conversations c on c.id = r.conversation_id
      where c.organization_id = p_organization_id and c.organization_address = p_address and r.status in ('running', 'waiting')
    ) then raise exception 'deactivate native deployment and finish active native sessions first' using errcode = '23514'; end if;
    if not exists (select 1 from public.chatbot_flow_versions v join public.chatbot_flows f on f.id = v.flow_id
      where v.organization_id = p_organization_id and v.id = (p_payload->>'source_version_id')::uuid
      and v.flow_id = (p_payload->>'source_flow_id')::uuid and v.status = 'published' and f.status = 'active') then
      raise exception 'published tenant flow not found' using errcode = '23514';
    end if;
  end if;
  insert into public.chatbot_node_bridges(organization_id, organization_address, node_company_id)
    values(p_organization_id, p_address, p_company_id) on conflict do nothing;
  select * into binding from public.chatbot_node_bridges where organization_id = p_organization_id
    and organization_address = p_address for update;
  if binding.node_company_id <> p_company_id then raise exception 'Node tenant mapping mismatch' using errcode = '23514'; end if;
  insert into public.chatbot_node_operations(request_id, organization_id, organization_address, action, phase, payload)
    values(p_request_id, p_organization_id, p_address, p_action,
      case when p_action = 'activate' then 'prepare' else p_action end, p_payload) returning * into operation;
  -- Until acknowledged, suppress native execution; failures cannot silently
  -- restore native mode because the remote result may be ambiguous.
  update public.chatbot_node_bridges set engine = 'transitioning', sync_status = 'pending',
    flow_id = case when p_action = 'activate' then (p_payload->>'source_flow_id')::uuid else flow_id end,
    flow_version_id = case when p_action = 'activate' then (p_payload->>'source_version_id')::uuid else flow_version_id end,
    request_id = p_request_id, last_error = null, updated_at = now()
    where organization_id = p_organization_id and organization_address = p_address;
  return operation;
end;
$$;
revoke all on function public.enqueue_node_chatbot_operation(uuid,text,text,uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.enqueue_node_chatbot_operation(uuid,text,text,uuid,text,jsonb) to service_role;

create function public.complete_node_chatbot_operation(p_request_id uuid, p_phase text, p_result jsonb)
returns public.chatbot_node_operations language plpgsql security definer set search_path = '' as $$
declare
  operation public.chatbot_node_operations;
begin
  select * into operation from public.chatbot_node_operations where request_id = p_request_id for update;
  if not found then raise exception 'operation not found' using errcode = 'P0002'; end if;
  if operation.phase <> p_phase or operation.status = 'succeeded' then return operation; end if;
  if operation.status not in ('in_flight', 'reconciling') then raise exception 'operation is not outstanding' using errcode = '23514'; end if;
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
$$;
revoke all on function public.complete_node_chatbot_operation(uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.complete_node_chatbot_operation(uuid,text,jsonb) to service_role;

create function public.is_node_managed_number(p_organization_id uuid, p_address text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.chatbot_node_bridges where organization_id = p_organization_id
    and organization_address = p_address and engine <> 'native');
$$;
revoke all on function public.is_node_managed_number(uuid,text) from public, anon, authenticated;
grant execute on function public.is_node_managed_number(uuid,text) to service_role;

create function public.guard_native_chatbot_deployment() returns trigger language plpgsql set search_path = '' as $$
begin
  perform 1 from public.organizations_addresses where organization_id = new.organization_id and address = new.organization_address for update;
  if public.is_node_managed_number(new.organization_id, new.organization_address) then
    raise exception 'number is managed by Node or has unresolved transition' using errcode = '23514';
  end if;
  return new;
end;
$$;
create trigger guard_native_chatbot_deployment before insert or update on public.chatbot_flow_deployments
  for each row execute function public.guard_native_chatbot_deployment();

create function public.sync_node_bridge_lifecycle() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  binding public.chatbot_node_bridges;
  operation_id uuid;
begin
  if old.status = new.status then return new; end if;
  for binding in select * from public.chatbot_node_bridges where organization_id = new.organization_id
    and engine <> 'native' for update loop
    -- Stop stale activation retries locally. Node's suspended flag rejects any
    -- old activation that arrives after the suspension acknowledgment.
    update public.chatbot_node_operations set status = 'failed', last_error = 'Superseded by organization lifecycle change'
      where organization_id = binding.organization_id and organization_address = binding.organization_address
        and status not in ('succeeded', 'failed');
    operation_id := gen_random_uuid();
    insert into public.chatbot_node_operations(request_id, organization_id, organization_address, action, phase, payload)
      values(operation_id, binding.organization_id, binding.organization_address,
        case when new.status = 'archived' then 'suspend' else 'restore' end,
        case when new.status = 'archived' then 'suspend' else 'restore' end, '{}');
    update public.chatbot_node_bridges set sync_status = 'pending', request_id = operation_id,
      engine = 'transitioning', updated_at = now()
      where organization_id = binding.organization_id and organization_address = binding.organization_address;
  end loop;
  return new;
end;
$$;
create trigger sync_node_bridge_lifecycle after update of status on public.organization_lifecycle
  for each row execute function public.sync_node_bridge_lifecycle();
