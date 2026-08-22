create function public.create_private_note(
  p_conversation_id uuid,
  p_text text,
  p_mentioned_agent_ids uuid[] default array[]::uuid[]
) returns public.messages
language plpgsql
volatile
security definer
set search_path to ''
as $$
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
$$;

create function public.transfer_conversation_with_private_note(
  p_conversation_id uuid,
  p_target_agent_id uuid,
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
$$;

create function public.list_mentionable_humans_page(
  p_organization_id uuid,
  p_page integer default 1,
  p_page_size integer default 50,
  p_search text default null
) returns table (
  id uuid,
  name text,
  picture text,
  role public.role,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  current_agent_id uuid;
  normalized_page integer;
  normalized_page_size integer;
  normalized_search text;
begin
  if not exists (
    select 1
    from public.get_authorized_orgs('agent') as authorized_orgs(id)
    where authorized_orgs.id = p_organization_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  current_agent_id := public.get_current_human_agent_id(p_organization_id);
  if current_agent_id is null then
    raise exception using
      errcode = '42501',
      message = 'accepted human membership is required';
  end if;

  normalized_page := greatest(coalesce(p_page, 1), 1);
  normalized_page_size := least(greatest(coalesce(p_page_size, 50), 1), 50);
  normalized_search := lower(btrim(coalesce(p_search, '')));

  return query
  select
    candidate.id,
    candidate.name,
    candidate.picture,
    (candidate.extra->>'role')::public.role,
    count(*) over() as total_count
  from public.agents candidate
  where candidate.organization_id = p_organization_id
    and candidate.id <> current_agent_id
    and candidate.ai = false
    and candidate.user_id is not null
    and (
      candidate.extra->'invitation' is null
      or candidate.extra->'invitation'->>'status' = 'accepted'
    )
    and candidate.extra->>'role' in ('owner', 'admin', 'supervisor', 'member', 'agent')
    and (
      normalized_search = ''
      or lower(candidate.name) like '%' || normalized_search || '%'
    )
  order by lower(candidate.name), candidate.id
  offset (normalized_page - 1) * normalized_page_size
  limit normalized_page_size;
end;
$$;

create function public.list_mentioned_conversations_page(
  p_organization_id uuid,
  p_page integer default 1,
  p_page_size integer default 25,
  p_search text default null
) returns table (
  organization_id uuid,
  id uuid,
  service public.service,
  organization_address text,
  contact_address text,
  group_address text,
  name text,
  assigned_agent_id uuid,
  routing_queue_id uuid,
  routed_at timestamp with time zone,
  extra jsonb,
  status text,
  created_at timestamp with time zone,
  updated_at timestamp with time zone,
  preview_message jsonb,
  latest_mention_at timestamp with time zone,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  current_agent_id uuid;
  normalized_page integer;
  normalized_page_size integer;
  normalized_search text;
begin
  if not exists (
    select 1
    from public.get_authorized_orgs('agent') as authorized_orgs(id)
    where authorized_orgs.id = p_organization_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  current_agent_id := public.get_current_human_agent_id(p_organization_id);
  if current_agent_id is null then
    raise exception using
      errcode = '42501',
      message = 'accepted human membership is required';
  end if;

  normalized_page := greatest(coalesce(p_page, 1), 1);
  normalized_page_size := least(greatest(coalesce(p_page_size, 25), 1), 50);
  normalized_search := lower(btrim(coalesce(p_search, '')));

  return query
  with latest_mentions as materialized (
    select
      message.conversation_id,
      max(mention.created_at) as latest_mention_at
    from public.message_mentions mention
    join public.messages message
      on message.organization_id = mention.organization_id
      and message.id = mention.message_id
    where mention.organization_id = p_organization_id
      and mention.mentioned_agent_id = current_agent_id
    group by message.conversation_id
  )
  select
    conversation.organization_id,
    conversation.id,
    conversation.service,
    conversation.organization_address,
    conversation.contact_address,
    conversation.group_address,
    conversation.name,
    conversation.assigned_agent_id,
    conversation.routing_queue_id,
    conversation.routed_at,
    conversation.extra,
    conversation.status,
    conversation.created_at,
    conversation.updated_at,
    preview.message,
    mention.latest_mention_at,
    count(*) over() as total_count
  from latest_mentions mention
  join public.conversations conversation
    on conversation.organization_id = p_organization_id
    and conversation.id = mention.conversation_id
  left join lateral (
    select to_jsonb(message) as message
    from public.messages message
    where message.organization_id = conversation.organization_id
      and message.conversation_id = conversation.id
      and message.direction in (
        'incoming'::public.direction,
        'outgoing'::public.direction
      )
    order by message.timestamp desc, message.id desc
    limit 1
  ) preview on true
  where normalized_search = ''
    or lower(coalesce(conversation.name, '')) like '%' || normalized_search || '%'
    or lower(coalesce(conversation.contact_address, '')) like '%' || normalized_search || '%'
    or lower(coalesce(conversation.group_address, '')) like '%' || normalized_search || '%'
    or lower(conversation.organization_address) like '%' || normalized_search || '%'
  order by mention.latest_mention_at desc, conversation.id desc
  offset (normalized_page - 1) * normalized_page_size
  limit normalized_page_size;
end;
$$;

revoke execute on function public.create_private_note(uuid, text, uuid[])
from public;

grant execute on function public.create_private_note(uuid, text, uuid[])
to authenticated;

revoke execute on function public.transfer_conversation_with_private_note(
  uuid,
  uuid,
  text
) from public;

grant execute on function public.transfer_conversation_with_private_note(
  uuid,
  uuid,
  text
) to authenticated;

revoke execute on function public.list_mentionable_humans_page(
  uuid,
  integer,
  integer,
  text
) from public;

grant execute on function public.list_mentionable_humans_page(
  uuid,
  integer,
  integer,
  text
) to authenticated;

revoke execute on function public.list_mentioned_conversations_page(
  uuid,
  integer,
  integer,
  text
) from public;

grant execute on function public.list_mentioned_conversations_page(
  uuid,
  integer,
  integer,
  text
) to authenticated;
