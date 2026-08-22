set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.enqueue_user_notification(p_organization_id uuid, p_recipient_agent_id uuid, p_actor_agent_id uuid, p_conversation_id uuid, p_notification_type text, p_source_event_key text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  notification_id uuid;
begin
  if not exists (
    select 1
    from public.agents recipient
    where recipient.organization_id = p_organization_id
      and recipient.id = p_recipient_agent_id
      and recipient.ai = false
      and recipient.user_id is not null
      and recipient.extra->>'role' in (
        'owner',
        'admin',
        'supervisor',
        'member',
        'agent'
      )
      and (
        recipient.extra->'invitation' is null
        or recipient.extra->'invitation'->>'status' = 'accepted'
      )
  ) then
    raise exception using
      errcode = '23514',
      message = 'notification recipient must be an accepted human in the organization';
  end if;

  insert into public.user_notifications (
    organization_id,
    recipient_agent_id,
    actor_agent_id,
    conversation_id,
    notification_type,
    source_event_key,
    payload
  ) values (
    p_organization_id,
    p_recipient_agent_id,
    p_actor_agent_id,
    p_conversation_id,
    p_notification_type,
    p_source_event_key,
    coalesce(p_payload, '{}'::jsonb)
  )
  on conflict (
    organization_id,
    recipient_agent_id,
    source_event_key
  ) do nothing
  returning id into notification_id;

  if notification_id is null then
    select notification.id into notification_id
    from public.user_notifications notification
    where notification.organization_id = p_organization_id
      and notification.recipient_agent_id = p_recipient_agent_id
      and notification.source_event_key = p_source_event_key;
  end if;

  return notification_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_private_note(p_conversation_id uuid, p_text text, p_mentioned_agent_ids uuid[] DEFAULT ARRAY[]::uuid[])
 RETURNS public.messages
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  conversation_row public.conversations;
  author_agent_id uuid;
  request_role public.role;
  normalized_text text;
  normalized_mentions uuid[];
  note public.messages;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'authentication required';
  end if;

  normalized_text := btrim(coalesce(p_text, ''));
  if normalized_text = '' then
    raise exception using
      errcode = '22023',
      message = 'private note text is required';
  end if;

  if array_position(p_mentioned_agent_ids, null) is not null then
    raise exception using
      errcode = '22023',
      message = 'mentioned agent ids cannot contain null';
  end if;

  select coalesce(array_agg(distinct mentioned_id order by mentioned_id), array[]::uuid[])
  into normalized_mentions
  from unnest(coalesce(p_mentioned_agent_ids, array[]::uuid[])) as mentioned(mentioned_id);

  select c.*
  into conversation_row
  from public.conversations c
  where c.id = p_conversation_id;

  if conversation_row.id is null then
    raise exception using
      errcode = '42501',
      message = 'conversation is not accessible to the authenticated user';
  end if;

  request_role := public.get_request_organization_role(conversation_row.organization_id);
  author_agent_id := public.get_current_human_agent_id(conversation_row.organization_id);

  if request_role is null or author_agent_id is null then
    raise exception using
      errcode = '42501',
      message = 'conversation is not accessible to the authenticated user';
  end if;

  if request_role = 'agent'::public.role then
    if not public.agent_can_read_conversation(
      conversation_row.organization_id,
      conversation_row.id
    ) then
      raise exception using
        errcode = '42501',
        message = 'conversation is not accessible to the authenticated user';
    end if;
  elsif not exists (
    select 1
    from public.get_authorized_orgs('member') as authorized_orgs(id)
    where authorized_orgs.id = conversation_row.organization_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'conversation is not accessible to the authenticated user';
  end if;

  if conversation_row.status <> 'active' then
    raise exception using
      errcode = '22023',
      message = 'private notes can only be added to active conversations';
  end if;

  if author_agent_id = any(normalized_mentions) then
    raise exception using
      errcode = '22023',
      message = 'authors cannot mention themselves';
  end if;

  if (
    select count(*)
    from public.agents target
    where target.organization_id = conversation_row.organization_id
      and target.id = any(normalized_mentions)
      and target.ai = false
      and target.user_id is not null
      and (
        target.extra->'invitation' is null
        or target.extra->'invitation'->>'status' = 'accepted'
      )
      and target.extra->>'role' in ('owner', 'admin', 'supervisor', 'member', 'agent')
  ) <> cardinality(normalized_mentions) then
    raise exception using
      errcode = '22023',
      message = 'mentions must target accepted humans in the same organization';
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
      'mentioned_agent_ids', to_jsonb(normalized_mentions)
    ),
    '{}'::jsonb
  )
  returning * into note;

  insert into public.message_mentions (
    organization_id,
    message_id,
    mentioned_agent_id,
    created_at
  )
  select
    note.organization_id,
    note.id,
    mentioned_id,
    note.created_at
  from unnest(normalized_mentions) as mentioned(mentioned_id);

  perform public.enqueue_user_notification(
    note.organization_id,
    mentioned_id,
    author_agent_id,
    note.conversation_id,
    'private_note_mention',
    format('private_note_mention:%s', note.id),
    jsonb_build_object(
      'message_id', note.id,
      'text', normalized_text
    )
  )
  from unnest(normalized_mentions) as mentioned(mentioned_id);

  return note;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_user_notifications_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 25, p_unread_only boolean DEFAULT false)
 RETURNS TABLE(organization_id uuid, id uuid, recipient_agent_id uuid, actor_agent_id uuid, conversation_id uuid, notification_type text, source_event_key text, payload jsonb, created_at timestamp with time zone, read_at timestamp with time zone, resolved_at timestamp with time zone, total_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_current_agent_id uuid;
  v_page integer;
  v_page_size integer;
  v_offset integer;
begin
  v_current_agent_id :=
    public.get_current_human_agent_id(p_organization_id);

  if v_current_agent_id is null then
    raise exception 'Not authorized';
  end if;

  v_page := greatest(coalesce(p_page, 1), 1);

  v_page_size :=
    least(
      greatest(coalesce(p_page_size, 25), 1),
      50
    );

  v_offset := (v_page - 1) * v_page_size;

  return query
  select
    n.organization_id,
    n.id,
    n.recipient_agent_id,
    n.actor_agent_id,
    n.conversation_id,
    n.notification_type,
    n.source_event_key,
    n.payload,
    n.created_at,
    n.read_at,
    n.resolved_at,
    count(*) over() as total_count
  from public.user_notifications n
  where n.organization_id = p_organization_id
    and n.recipient_agent_id = v_current_agent_id
    and (
      coalesce(p_unread_only, false) = false
      or (
        n.read_at is null
        and n.resolved_at is null
      )
    )
  order by n.created_at desc, n.id desc
  limit v_page_size
  offset v_offset;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_conversation_agent_assignment(p_conversation_id uuid, p_agent_id uuid)
 RETURNS public.conversations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  target_conversation public.conversations;
  caller_role public.role;
  actor_agent_id uuid;
  previous_assigned_agent_id uuid;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'authentication required';
  end if;

  select c.* into target_conversation
  from public.conversations c
  where c.id = p_conversation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'conversation not found';
  end if;

  caller_role := public.get_request_organization_role(
    target_conversation.organization_id
  );
  actor_agent_id := public.get_current_human_agent_id(
    target_conversation.organization_id
  );
  previous_assigned_agent_id := target_conversation.assigned_agent_id;

  if caller_role not in (
    'owner'::public.role,
    'admin'::public.role,
    'supervisor'::public.role
  ) then
    raise exception using
      errcode = '42501',
      message = 'only owners, admins, and supervisors can manage Agent assignments';
  end if;

  if target_conversation.assigned_agent_id is not null
    and not exists (
      select 1
      from public.agents a
      where a.id = target_conversation.assigned_agent_id
        and a.organization_id = target_conversation.organization_id
        and a.ai = false
        and a.user_id is not null
        and a.extra->>'role' = 'agent'
        and (
          a.extra->'invitation' is null
          or a.extra->'invitation'->>'status' = 'accepted'
        )
    )
  then
    raise exception using
      errcode = '42501',
      message = 'conversations assigned to non-Agent users cannot be reassigned';
  end if;

  if p_agent_id is not null
    and not exists (
      select 1
      from public.agents a
      where a.id = p_agent_id
        and a.organization_id = target_conversation.organization_id
        and a.ai = false
        and a.user_id is not null
        and a.extra->>'role' = 'agent'
        and (
          a.extra->'invitation' is null
          or a.extra->'invitation'->>'status' = 'accepted'
        )
    )
  then
    raise exception using
      errcode = '23514',
      message = 'assignee must be an accepted Agent in the same organization';
  end if;

  if p_agent_id is not null
    and target_conversation.routing_queue_id is not null
    and not exists (
      select 1
      from public.routing_queue_members member
      where member.organization_id = target_conversation.organization_id
        and member.routing_queue_id = target_conversation.routing_queue_id
        and member.agent_id = p_agent_id
    )
  then
    raise exception using
      errcode = '23514',
      message = 'assignee must belong to the conversation routing queue';
  end if;

  update public.conversations
  set assigned_agent_id = p_agent_id
  where id = p_conversation_id
  returning * into target_conversation;

  if p_agent_id is not null
    and p_agent_id is distinct from previous_assigned_agent_id
  then
    perform public.enqueue_user_notification(
      target_conversation.organization_id,
      p_agent_id,
      actor_agent_id,
      target_conversation.id,
      'conversation_assigned',
      format(
        'conversation_assignment:%s:%s:%s',
        target_conversation.id,
        p_agent_id,
        txid_current()
      ),
      jsonb_build_object(
        'previous_assigned_agent_id', previous_assigned_agent_id,
        'assigned_agent_id', p_agent_id
      )
    );
  end if;

  return target_conversation;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.transfer_conversation_to_queue_with_private_note(p_conversation_id uuid, p_target_routing_queue_id uuid, p_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  return jsonb_build_object(
    'conversation', to_jsonb(updated_conversation),
    'note', to_jsonb(note),
    'routing_event', to_jsonb(routing_event)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.transfer_conversation_with_private_note(p_conversation_id uuid, p_target_agent_id uuid, p_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  conversation_row public.conversations;
  updated_conversation public.conversations;
  author_agent_id uuid;
  request_role public.role;
  normalized_text text;
  note public.messages;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'authentication required';
  end if;

  normalized_text := btrim(coalesce(p_text, ''));
  if normalized_text = '' then
    raise exception using
      errcode = '22023',
      message = 'transfer note text is required';
  end if;

  select c.*
  into conversation_row
  from public.conversations c
  where c.id = p_conversation_id
  for update;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'conversation is not accessible to the authenticated user';
  end if;

  request_role := public.get_request_organization_role(
    conversation_row.organization_id
  );
  author_agent_id := public.get_current_human_agent_id(
    conversation_row.organization_id
  );

  if request_role is distinct from 'agent'::public.role
    or author_agent_id is null
  then
    raise exception using
      errcode = '42501',
      message = 'only the assigned Agent can transfer this conversation';
  end if;

  if conversation_row.status <> 'active' then
    raise exception using
      errcode = '22023',
      message = 'only active conversations can be transferred';
  end if;

  if conversation_row.assigned_agent_id is distinct from author_agent_id then
    raise exception using
      errcode = '42501',
      message = 'conversation is not assigned to the authenticated Agent';
  end if;

  if p_target_agent_id is null or p_target_agent_id = author_agent_id then
    raise exception using
      errcode = '22023',
      message = 'transfer target must be another accepted Agent';
  end if;

  if not exists (
    select 1
    from public.agents target
    where target.id = p_target_agent_id
      and target.organization_id = conversation_row.organization_id
      and target.ai = false
      and target.user_id is not null
      and target.extra->>'role' = 'agent'
      and (
        target.extra->'invitation' is null
        or target.extra->'invitation'->>'status' = 'accepted'
      )
  ) then
    raise exception using
      errcode = '22023',
      message = 'transfer target must be another accepted Agent';
  end if;

  if conversation_row.routing_queue_id is not null
    and not exists (
      select 1
      from public.routing_queue_members member
      where member.organization_id = conversation_row.organization_id
        and member.routing_queue_id = conversation_row.routing_queue_id
        and member.agent_id = p_target_agent_id
    )
  then
    raise exception using
      errcode = '22023',
      message = 'transfer target must belong to the conversation routing queue';
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
      'mentioned_agent_ids', jsonb_build_array(p_target_agent_id),
      'transfer', jsonb_build_object(
        'from_agent_id', author_agent_id,
        'to_agent_id', p_target_agent_id
      )
    ),
    '{}'::jsonb
  )
  returning * into note;

  insert into public.message_mentions (
    organization_id,
    message_id,
    mentioned_agent_id,
    created_at
  ) values (
    note.organization_id,
    note.id,
    p_target_agent_id,
    note.created_at
  );

  update public.conversations c
  set assigned_agent_id = p_target_agent_id
  where c.id = conversation_row.id
    and c.status = 'active'
    and c.assigned_agent_id = author_agent_id
  returning c.* into updated_conversation;

  if not found then
    raise exception using
      errcode = '23505',
      message = 'conversation assignment changed before transfer completed';
  end if;

  perform public.enqueue_user_notification(
    updated_conversation.organization_id,
    p_target_agent_id,
    author_agent_id,
    updated_conversation.id,
    'conversation_transferred_to_agent',
    format('conversation_agent_transfer:%s', note.id),
    jsonb_build_object(
      'message_id', note.id,
      'from_agent_id', author_agent_id,
      'to_agent_id', p_target_agent_id,
      'text', normalized_text
    )
  );

  return jsonb_build_object(
    'conversation', to_jsonb(updated_conversation),
    'note', to_jsonb(note)
  );
end;
$function$
;

revoke execute on function public.enqueue_user_notification(uuid, uuid, uuid, uuid, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.enqueue_user_notification(uuid, uuid, uuid, uuid, text, text, jsonb) to service_role;

alter table public.user_notifications replica identity full;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'user_notifications'
  ) then
    alter publication supabase_realtime add table only public.user_notifications;
  end if;
end;
$$;
