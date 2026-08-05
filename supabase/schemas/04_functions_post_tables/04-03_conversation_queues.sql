create function public.get_conversation_queues(
  p_organization_id uuid default null
)
returns table (
  key text,
  label text,
  "order" integer,
  enabled boolean
)
language plpgsql
stable
set search_path to ''
as $$
declare
  request_role public.role;
begin
  if p_organization_id is not null
    and not exists (
      select 1
      from public.get_authorized_orgs('agent') as authorized_orgs(id)
      where authorized_orgs.id = p_organization_id
    )
  then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  request_role := case
    when p_organization_id is null then null
    else public.get_request_organization_role(p_organization_id)
  end;

  if request_role = 'agent'::public.role then
    return query
    select q.key, q.label, q.sort_order as "order", q.enabled
    from (
      values
        ('pending', 'Pending', 1, true),
        ('assigned', 'Assigned', 2, true)
    ) as q(key, label, sort_order, enabled)
    order by q.sort_order;
    return;
  end if;

  return query
  select
    q.key,
    q.label,
    q.sort_order as "order",
    q.enabled
  from (
    values
      ('all_active', 'All (active)', 1, true),
      ('assigned', 'Assigned', 2, true),
      ('pending', 'Pending', 3, true),
      ('spam', 'Spam', 4, true),
      ('closed', 'Closed', 5, true),
      ('expired', 'Expired', 6, true)
  ) as q(key, label, sort_order, enabled)
  order by q.sort_order;
end;
$$;

create function public.get_conversation_queue_conversations(
  p_organization_id uuid,
  p_queue_key text,
  p_limit integer default 50,
  p_offset integer default 0
) returns setof public.conversations
language plpgsql
stable
security invoker
set search_path to ''
as $$
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

  if request_role = 'agent'::public.role
    and p_queue_key not in ('pending', 'assigned')
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
  where c.organization_id = p_organization_id
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
        p_queue_key = 'spam'
        and c.status = 'spam'
      )
      or (
        p_queue_key = 'closed'
        and c.status = 'closed'
      )
      or (
        p_queue_key = 'expired'
        and c.status = 'active'
        and incoming.latest_incoming_at <= now() - interval '24 hours'
      )
    )
  order by c.updated_at desc, c.id desc
  limit normalized_limit
  offset normalized_offset;
end;
$$;
