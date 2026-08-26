create function public.list_transferable_routing_queue_options(
  p_conversation_id uuid
) returns table (
  id uuid,
  name text
)
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  conversation_row public.conversations;
  request_role public.role;
  author_agent_id uuid;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'authentication required';
  end if;

  select conversation.* into conversation_row
  from public.conversations conversation
  where conversation.id = p_conversation_id;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'conversation is not accessible to the authenticated user';
  end if;

  if conversation_row.status <> 'active' then
    raise exception using
      errcode = '22023',
      message = 'only active conversations can be transferred';
  end if;

  request_role := public.get_request_organization_role(
    conversation_row.organization_id
  );
  author_agent_id := public.get_current_human_agent_id(
    conversation_row.organization_id
  );

  if author_agent_id is null
    or (
      request_role = 'agent'::public.role
      and conversation_row.assigned_agent_id is distinct from author_agent_id
    )
    or request_role not in (
      'owner'::public.role,
      'admin'::public.role,
      'supervisor'::public.role,
      'agent'::public.role
    )
  then
    raise exception using
      errcode = '42501',
      message = 'conversation queue transfer is not permitted';
  end if;

  return query
  select queue.id, queue.name
  from public.routing_queues queue
  where queue.organization_id = conversation_row.organization_id
    and queue.status = 'active'
    and queue.id is distinct from conversation_row.routing_queue_id
  order by lower(queue.name), queue.id;
end;
$$;

create function public.transfer_conversation_to_queue_with_private_note(
  p_conversation_id uuid,
  p_target_routing_queue_id uuid,
  p_text text
) returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  conversation_row public.conversations;
  updated_conversation public.conversations;
  destination_queue public.routing_queues;
  previous_queue_name text;
  author_agent_id uuid;
  request_role public.role;
  normalized_text text := btrim(coalesce(p_text, ''));
  transfer_time timestamp with time zone := now();
  note public.messages;
  routing_event public.conversation_routing_events;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'authentication required';
  end if;

  if normalized_text = '' then
    raise exception using
      errcode = '22023',
      message = 'queue transfer explanation is required';
  end if;

  select conversation.* into conversation_row
  from public.conversations conversation
  where conversation.id = p_conversation_id
  for update;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'conversation is not accessible to the authenticated user';
  end if;

  if conversation_row.status <> 'active' then
    raise exception using
      errcode = '22023',
      message = 'only active conversations can be transferred';
  end if;

  request_role := public.get_request_organization_role(
    conversation_row.organization_id
  );
  author_agent_id := public.get_current_human_agent_id(
    conversation_row.organization_id
  );

  if author_agent_id is null
    or (
      request_role = 'agent'::public.role
      and conversation_row.assigned_agent_id is distinct from author_agent_id
    )
    or request_role not in (
      'owner'::public.role,
      'admin'::public.role,
      'supervisor'::public.role,
      'agent'::public.role
    )
  then
    raise exception using
      errcode = '42501',
      message = 'conversation queue transfer is not permitted';
  end if;

  select queue.* into destination_queue
  from public.routing_queues queue
  where queue.id = p_target_routing_queue_id
    and queue.organization_id = conversation_row.organization_id
    and queue.status = 'active'
  for key share;

  if not found then
    raise exception using
      errcode = '22023',
      message = 'destination must be an active queue in the same organization';
  end if;

  if conversation_row.routing_queue_id = destination_queue.id then
    raise exception using
      errcode = '22023',
      message = 'destination queue must be different from the current queue';
  end if;

  if conversation_row.routing_queue_id is not null then
    select queue.name into previous_queue_name
    from public.routing_queues queue
    where queue.id = conversation_row.routing_queue_id
      and queue.organization_id = conversation_row.organization_id;
  end if;

  insert into public.messages (
    organization_id,
    conversation_id,
    direction,
    agent_id,
    contact_address,
    service,
    organization_address,
    group_address,
    content,
    status
  ) values (
    conversation_row.organization_id,
    conversation_row.id,
    'internal'::public.direction,
    author_agent_id,
    conversation_row.contact_address,
    conversation_row.service,
    conversation_row.organization_address,
    conversation_row.group_address,
    jsonb_build_object(
      'version', '1',
      'type', 'text',
      'kind', 'private_note',
      'text', normalized_text,
      'mentioned_agent_ids', '[]'::jsonb,
      'routing_transfer', jsonb_build_object(
        'from_queue_id', conversation_row.routing_queue_id,
        'from_queue_name', previous_queue_name,
        'to_queue_id', destination_queue.id,
        'to_queue_name', destination_queue.name
      )
    ),
    '{}'::jsonb
  )
  returning * into note;

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
    conversation_row.organization_id,
    conversation_row.id,
    conversation_row.routing_queue_id,
    previous_queue_name,
    destination_queue.id,
    destination_queue.name,
    author_agent_id,
    'manual_transfer',
    normalized_text,
    transfer_time
  )
  returning * into routing_event;

  update public.conversations conversation
  set routing_queue_id = destination_queue.id,
      routed_at = transfer_time,
      assigned_agent_id = null
  where conversation.id = conversation_row.id
  returning * into updated_conversation;

  perform public.enqueue_user_notification(
    updated_conversation.organization_id,
    member.agent_id,
    author_agent_id,
    updated_conversation.id,
    'conversation_transferred_to_queue',
    format('conversation_queue_transfer:%s', routing_event.id),
    jsonb_build_object(
      'message_id', note.id,
      'routing_event_id', routing_event.id,
      'from_queue_id', conversation_row.routing_queue_id,
      'from_queue_name', previous_queue_name,
      'to_queue_id', destination_queue.id,
      'to_queue_name', destination_queue.name,
      'text', normalized_text
    )
  )
  from public.routing_queue_members member
  where member.organization_id = updated_conversation.organization_id
    and member.routing_queue_id = destination_queue.id
    and member.agent_id is distinct from author_agent_id;

  updated_conversation := public.try_auto_assign_conversation(
    updated_conversation.id,
    'queue_transfer'
  );

  return jsonb_build_object(
    'conversation', to_jsonb(updated_conversation),
    'note', to_jsonb(note),
    'routing_event', to_jsonb(routing_event)
  );
end;
$$;

revoke execute on function public.list_transferable_routing_queue_options(uuid)
from public;

grant execute on function public.list_transferable_routing_queue_options(uuid)
to authenticated;

revoke execute on function public.transfer_conversation_to_queue_with_private_note(
  uuid,
  uuid,
  text
) from public;

grant execute on function public.transfer_conversation_to_queue_with_private_note(
  uuid,
  uuid,
  text
) to authenticated;
