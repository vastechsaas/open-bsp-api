CREATE INDEX chatbot_node_conversations_inbox_idx ON public.chatbot_node_conversations USING btree (organization_id, conversation_id);

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.broadcast_support_inbox_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare context jsonb; previous jsonb;
begin
  context := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  if tg_op = 'UPDATE' then
    previous := to_jsonb(old);
    if tg_table_name = 'chatbot_node_conversations'
      and context - 'last_inbound_wamid' - 'ownership_revision'
        = previous - 'last_inbound_wamid' - 'ownership_revision' then
      return null;
    end if;
    if tg_table_name = 'chatbot_node_bridges'
      and context->'engine' = previous->'engine'
      and context->'organization_id' = previous->'organization_id'
      and context->'organization_address' = previous->'organization_address' then
      return null;
    end if;
  end if;
  perform realtime.send(jsonb_build_object(
    'organization_id', context->>'organization_id',
    'organization_address', context->>'organization_address',
    'conversation_id', context->>'conversation_id'
  ), 'conversation_inbox_changed', 'conversation-queue:' || (context->>'organization_id'), true);
  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_support_inbox_visibility(p_organization_id uuid, p_conversation_ids uuid[])
 RETURNS TABLE(conversation_id uuid, visible boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin
  if auth.uid() is null or not exists (
    select 1 from public.get_authorized_orgs('agent') a(id) where a.id = p_organization_id
  ) then
    raise exception 'organization is not accessible to the authenticated user' using errcode = '42501';
  end if;
  if p_conversation_ids is null or cardinality(p_conversation_ids) > 500 then
    raise exception 'provide at most 500 conversation IDs' using errcode = '22023';
  end if;
  return query select c.id, public.is_support_inbox_visible(c.organization_id,c.id)
    from public.conversations c
    where c.organization_id = p_organization_id and c.id = any(p_conversation_ids);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.is_support_inbox_visible(p_organization_id uuid, p_conversation_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1 from public.conversations c
    where c.organization_id = p_organization_id and c.id = p_conversation_id
      and (
        c.organization_id in (select public.get_authorized_orgs('member'))
        or public.agent_can_read_conversation(c.organization_id, c.id)
      )
      and (
        not exists (
          select 1 from public.chatbot_node_bridges b
          where b.organization_id = c.organization_id
            and b.organization_address = c.organization_address and b.engine <> 'native'
        )
        or exists (
          select 1 from public.chatbot_node_conversations m
          where m.organization_id = c.organization_id and m.conversation_id = c.id
            and m.organization_address = c.organization_address
            and (
              m.human_owned or m.pending_request_id is not null
              or m.support_request->>'status' = 'waiting'
              or (c.status in ('closed', 'spam') and m.state = 'closed'
                and (m.closed_at is not null or m.support_request->>'status' = 'resolved'))
            )
        )
      )
  );
$function$
;

CREATE OR REPLACE FUNCTION public.get_conversation_queue_conversations(p_organization_id uuid, p_queue_key text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_routing_queue_id uuid DEFAULT NULL::uuid)
 RETURNS SETOF public.conversations
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  normalized_limit integer;
  normalized_offset integer;
  request_role public.role;
  current_agent_id uuid;
begin
  if p_organization_id is null then
    raise exception using
      errcode = '22004',
      message = 'organization id is required';
  end if;

  if p_queue_key is null or p_queue_key not in (
    'all_active',
    'assigned',
    'pending',
    'mentioned',
    'spam',
    'closed',
    'expired'
  ) then
    raise exception using
      errcode = '22023',
      message = 'invalid conversation queue key';
  end if;

  if not exists (
    select 1
    from public.get_authorized_orgs('agent') as authorized_orgs(id)
    where authorized_orgs.id = p_organization_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  request_role := public.get_request_organization_role(p_organization_id);
  current_agent_id := public.get_current_human_agent_id(p_organization_id);

  if p_routing_queue_id is not null
    and not exists (
      select 1
      from public.routing_queues queue
      where queue.organization_id = p_organization_id
        and queue.id = p_routing_queue_id
        and (
          request_role <> 'agent'::public.role
          or exists (
            select 1
            from public.routing_queue_members member
            where member.organization_id = queue.organization_id
              and member.routing_queue_id = queue.id
              and member.agent_id = current_agent_id
          )
        )
    )
  then
    raise exception using
      errcode = '42501',
      message = 'routing queue is not accessible to the authenticated user';
  end if;

  if request_role = 'agent'::public.role
    and p_queue_key = 'all_active'
  then
    raise exception using
      errcode = '42501',
      message = 'conversation queue is not available to Agent users';
  end if;

  normalized_limit := least(greatest(coalesce(p_limit, 50), 1), 500);
  normalized_offset := greatest(coalesce(p_offset, 0), 0);

  return query
  select c.*
  from public.conversations c
  left join lateral (
    select max(m.timestamp) as latest_incoming_at
    from public.messages m
    where m.organization_id = c.organization_id
      and m.conversation_id = c.id
      and m.direction = 'incoming'::public.direction
  ) incoming on true
  left join lateral (
    select max(mention.created_at) as latest_mention_at
    from public.message_mentions mention
    join public.messages message
      on message.organization_id = mention.organization_id
      and message.id = mention.message_id
    where mention.organization_id = c.organization_id
      and mention.mentioned_agent_id = current_agent_id
      and message.conversation_id = c.id
  ) mentioned on true
  where c.organization_id = p_organization_id
    and public.is_support_inbox_visible(c.organization_id, c.id)
    and (
      p_queue_key = 'mentioned'
      or p_routing_queue_id is null
      or c.routing_queue_id = p_routing_queue_id
    )
    and (
      (
        p_queue_key = 'all_active'
        and c.status = 'active'
      )
      or (
        p_queue_key = 'assigned'
        and c.status = 'active'
        and c.assigned_agent_id is not null
        and (
          request_role <> 'agent'::public.role
          or c.assigned_agent_id = current_agent_id
        )
      )
      or (
        p_queue_key = 'pending'
        and c.status = 'active'
        and c.assigned_agent_id is null
      )
      or (
        p_queue_key = 'mentioned'
        and mentioned.latest_mention_at is not null
      )
      or (
        p_queue_key = 'spam'
        and c.status = 'spam'
        and (
          request_role <> 'agent'::public.role
          or c.assigned_agent_id = current_agent_id
        )
      )
      or (
        p_queue_key = 'closed'
        and c.status = 'closed'
        and (
          request_role <> 'agent'::public.role
          or c.assigned_agent_id = current_agent_id
        )
      )
      or (
        p_queue_key = 'expired'
        and c.status = 'active'
        and incoming.latest_incoming_at <= now() - interval '24 hours'
        and (
          request_role <> 'agent'::public.role
          or c.assigned_agent_id is null
          or c.assigned_agent_id = current_agent_id
        )
      )
    )
  order by
    case
      when p_queue_key = 'mentioned' then mentioned.latest_mention_at
    end desc,
    c.updated_at desc,
    c.id desc
  limit normalized_limit
  offset normalized_offset;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_mentioned_conversations_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 25, p_search text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, id uuid, service public.service, organization_address text, contact_address text, group_address text, name text, assigned_agent_id uuid, routing_queue_id uuid, routed_at timestamp with time zone, extra jsonb, status text, created_at timestamp with time zone, updated_at timestamp with time zone, preview_message jsonb, latest_mention_at timestamp with time zone, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  where public.is_support_inbox_visible(conversation.organization_id, conversation.id)
    and (
      normalized_search = ''
      or lower(coalesce(conversation.name, '')) like '%' || normalized_search || '%'
      or lower(coalesce(conversation.contact_address, '')) like '%' || normalized_search || '%'
      or lower(coalesce(conversation.group_address, '')) like '%' || normalized_search || '%'
      or lower(conversation.organization_address) like '%' || normalized_search || '%'
    )
  order by mention.latest_mention_at desc, conversation.id desc
  offset (normalized_page - 1) * normalized_page_size
  limit normalized_page_size;
end;
$function$
;

CREATE TRIGGER broadcast_node_binding_inbox_change AFTER INSERT OR DELETE OR UPDATE ON public.chatbot_node_bridges FOR EACH ROW EXECUTE FUNCTION public.broadcast_support_inbox_change();

CREATE TRIGGER broadcast_node_conversation_inbox_change AFTER INSERT OR DELETE OR UPDATE ON public.chatbot_node_conversations FOR EACH ROW EXECUTE FUNCTION public.broadcast_support_inbox_change();

-- Match schema-source privileges; generated diffs omit grants on new routines.
revoke all on function public.is_support_inbox_visible(uuid,uuid) from public, anon;
grant execute on function public.is_support_inbox_visible(uuid,uuid) to authenticated, service_role;
revoke all on function public.get_support_inbox_visibility(uuid,uuid[]) from public, anon;
grant execute on function public.get_support_inbox_visibility(uuid,uuid[]) to authenticated;
revoke all on function public.broadcast_support_inbox_change() from public, anon, authenticated;

