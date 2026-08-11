create function public.validate_routing_queue_agent_ids(
  p_organization_id uuid,
  p_agent_ids uuid[]
) returns uuid[]
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  normalized_ids uuid[];
begin
  select coalesce(array_agg(distinct agent_id order by agent_id), array[]::uuid[])
  into normalized_ids
  from unnest(coalesce(p_agent_ids, array[]::uuid[])) as requested(agent_id)
  where agent_id is not null;

  if exists (
    select 1
    from unnest(normalized_ids) as requested(agent_id)
    where not exists (
      select 1
      from public.agents agent
      where agent.organization_id = p_organization_id
        and agent.id = requested.agent_id
        and agent.ai = false
        and agent.user_id is not null
        and agent.extra->>'role' = 'agent'
        and coalesce(agent.extra->'invitation'->>'status', 'accepted') = 'accepted'
    )
  ) then
    raise exception using
      errcode = '22023',
      message = 'routing queue members must be accepted human Agents in the same organization';
  end if;

  return normalized_ids;
end;
$$;

create function public.replace_routing_queue_members(
  p_organization_id uuid,
  p_routing_queue_id uuid,
  p_agent_ids uuid[]
) returns void
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  normalized_ids uuid[];
begin
  normalized_ids := public.validate_routing_queue_agent_ids(
    p_organization_id,
    p_agent_ids
  );

  delete from public.routing_queue_members member
  where member.organization_id = p_organization_id
    and member.routing_queue_id = p_routing_queue_id
    and member.agent_id <> all(normalized_ids);

  insert into public.routing_queue_members (
    organization_id,
    routing_queue_id,
    agent_id
  )
  select p_organization_id, p_routing_queue_id, agent_id
  from unnest(normalized_ids) as requested(agent_id)
  on conflict do nothing;
end;
$$;

create function public.list_routing_queues_page(
  p_organization_id uuid,
  p_page integer default 1,
  p_page_size integer default 10,
  p_search text default null
) returns table (
  id uuid,
  organization_id uuid,
  name text,
  status text,
  member_ids uuid[],
  member_count bigint,
  created_at timestamp with time zone,
  updated_at timestamp with time zone,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  request_role public.role;
  normalized_page integer := greatest(coalesce(p_page, 1), 1);
  normalized_page_size integer := least(greatest(coalesce(p_page_size, 10), 1), 50);
  normalized_search text := nullif(btrim(coalesce(p_search, '')), '');
begin
  request_role := public.get_request_organization_role(p_organization_id);
  if request_role not in (
    'owner'::public.role,
    'admin'::public.role,
    'supervisor'::public.role
  ) then
    raise exception using
      errcode = '42501',
      message = 'owner, admin, or supervisor role required to manage routing queues';
  end if;

  return query
  with filtered as (
    select queue.*
    from public.routing_queues queue
    where queue.organization_id = p_organization_id
      and (
        normalized_search is null
        or queue.name ilike '%' || normalized_search || '%'
      )
  )
  select
    queue.id,
    queue.organization_id,
    queue.name,
    queue.status,
    coalesce(members.member_ids, array[]::uuid[]),
    coalesce(members.member_count, 0),
    queue.created_at,
    queue.updated_at,
    count(*) over() as total_count
  from filtered queue
  left join lateral (
    select
      array_agg(member.agent_id order by member.agent_id) as member_ids,
      count(*) as member_count
    from public.routing_queue_members member
    where member.organization_id = queue.organization_id
      and member.routing_queue_id = queue.id
  ) members on true
  order by queue.name asc, queue.id asc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$$;

create function public.list_routing_queue_options(
  p_organization_id uuid
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
  request_role public.role;
  current_agent_id uuid;
begin
  request_role := public.get_request_organization_role(p_organization_id);
  if request_role is null then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  current_agent_id := public.get_current_human_agent_id(p_organization_id);

  return query
  select queue.id, queue.name
  from public.routing_queues queue
  where queue.organization_id = p_organization_id
    and queue.status = 'active'
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
  order by queue.name asc, queue.id asc;
end;
$$;

create function public.create_routing_queue(
  p_organization_id uuid,
  p_name text,
  p_agent_ids uuid[] default array[]::uuid[]
) returns public.routing_queues
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  request_role public.role;
  normalized_name text := btrim(coalesce(p_name, ''));
  created_queue public.routing_queues;
begin
  request_role := public.get_request_organization_role(p_organization_id);
  if request_role not in (
    'owner'::public.role,
    'admin'::public.role,
    'supervisor'::public.role
  ) then
    raise exception using
      errcode = '42501',
      message = 'owner, admin, or supervisor role required to manage routing queues';
  end if;

  if char_length(normalized_name) not between 1 and 80 then
    raise exception using
      errcode = '22023',
      message = 'routing queue name must contain between 1 and 80 characters';
  end if;

  perform public.validate_routing_queue_agent_ids(p_organization_id, p_agent_ids);

  insert into public.routing_queues (organization_id, name)
  values (p_organization_id, normalized_name)
  returning * into created_queue;

  perform public.replace_routing_queue_members(
    created_queue.organization_id,
    created_queue.id,
    p_agent_ids
  );

  return created_queue;
exception
  when unique_violation then
    raise exception using
      errcode = '23505',
      message = 'routing queue name already exists in this organization';
end;
$$;

create function public.update_routing_queue(
  p_routing_queue_id uuid,
  p_name text,
  p_status text,
  p_agent_ids uuid[] default array[]::uuid[]
) returns public.routing_queues
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  existing_queue public.routing_queues;
  request_role public.role;
  normalized_name text := btrim(coalesce(p_name, ''));
  updated_queue public.routing_queues;
begin
  select queue.* into existing_queue
  from public.routing_queues queue
  where queue.id = p_routing_queue_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'routing queue not found';
  end if;

  request_role := public.get_request_organization_role(existing_queue.organization_id);
  if request_role not in (
    'owner'::public.role,
    'admin'::public.role,
    'supervisor'::public.role
  ) then
    raise exception using
      errcode = '42501',
      message = 'owner, admin, or supervisor role required to manage routing queues';
  end if;

  if char_length(normalized_name) not between 1 and 80 then
    raise exception using
      errcode = '22023',
      message = 'routing queue name must contain between 1 and 80 characters';
  end if;

  if p_status not in ('active', 'archived') then
    raise exception using
      errcode = '22023',
      message = 'routing queue status must be active or archived';
  end if;

  perform public.validate_routing_queue_agent_ids(
    existing_queue.organization_id,
    p_agent_ids
  );

  update public.routing_queues queue
  set name = normalized_name,
      status = p_status
  where queue.id = p_routing_queue_id
  returning * into updated_queue;

  perform public.replace_routing_queue_members(
    updated_queue.organization_id,
    updated_queue.id,
    p_agent_ids
  );

  return updated_queue;
exception
  when unique_violation then
    raise exception using
      errcode = '23505',
      message = 'routing queue name already exists in this organization';
end;
$$;

create function public.route_conversation_to_queue(
  p_conversation_id uuid,
  p_routing_queue_id uuid
) returns public.conversations
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  target_conversation public.conversations;
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

  if not exists (
    select 1
    from public.routing_queues queue
    where queue.id = p_routing_queue_id
      and queue.organization_id = target_conversation.organization_id
      and queue.status = 'active'
  ) then
    raise exception using
      errcode = '23514',
      message = 'routing destination must be an active queue in the same organization';
  end if;

  update public.conversations conversation
  set routing_queue_id = p_routing_queue_id,
      routed_at = now(),
      assigned_agent_id = null
  where conversation.id = p_conversation_id
  returning * into target_conversation;

  return target_conversation;
end;
$$;

revoke execute on function public.validate_routing_queue_agent_ids(uuid, uuid[]) from public;
revoke execute on function public.replace_routing_queue_members(uuid, uuid, uuid[]) from public;
revoke execute on function public.route_conversation_to_queue(uuid, uuid) from public;
revoke execute on function public.list_routing_queues_page(uuid, integer, integer, text) from public;
revoke execute on function public.list_routing_queue_options(uuid) from public;
revoke execute on function public.create_routing_queue(uuid, text, uuid[]) from public;
revoke execute on function public.update_routing_queue(uuid, text, text, uuid[]) from public;

grant execute on function public.list_routing_queues_page(uuid, integer, integer, text) to authenticated;
grant execute on function public.list_routing_queue_options(uuid) to authenticated;
grant execute on function public.create_routing_queue(uuid, text, uuid[]) to authenticated;
grant execute on function public.update_routing_queue(uuid, text, text, uuid[]) to authenticated;
