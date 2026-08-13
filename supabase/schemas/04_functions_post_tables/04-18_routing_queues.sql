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

create function public.get_routing_queue_audit_state(
  p_routing_queue_id uuid
) returns jsonb
language sql
stable
security definer
set search_path to ''
as $$
  select jsonb_build_object(
    'id', queue.id,
    'name', queue.name,
    'status', queue.status,
    'agent_ids', coalesce(
      (
        select jsonb_agg(member.agent_id order by member.agent_id)
        from public.routing_queue_members member
        where member.organization_id = queue.organization_id
          and member.routing_queue_id = queue.id
      ),
      '[]'::jsonb
    )
  )
  from public.routing_queues queue
  where queue.id = p_routing_queue_id;
$$;

create function public.list_platform_routing_queues_page(
  p_organization_id uuid,
  p_page integer default 1,
  p_page_size integer default 10,
  p_search text default null,
  p_status text default null
) returns table (
  id uuid,
  organization_id uuid,
  name text,
  status text,
  member_ids uuid[],
  member_names text[],
  member_pictures text[],
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
  normalized_page integer := greatest(coalesce(p_page, 1), 1);
  normalized_page_size integer := least(greatest(coalesce(p_page_size, 10), 1), 50);
  normalized_search text := nullif(btrim(coalesce(p_search, '')), '');
  normalized_status text := nullif(lower(btrim(coalesce(p_status, ''))), '');
begin
  perform public.require_platform_admin();

  if not exists (
    select 1 from public.organizations organization
    where organization.id = p_organization_id
  ) then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;

  if normalized_status is not null
    and normalized_status not in ('active', 'archived')
  then
    raise exception using
      errcode = '22023',
      message = 'routing queue status filter is invalid';
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
      and (normalized_status is null or queue.status = normalized_status)
  )
  select
    queue.id,
    queue.organization_id,
    queue.name,
    queue.status,
    coalesce(members.member_ids, array[]::uuid[]),
    coalesce(members.member_names, array[]::text[]),
    coalesce(members.member_pictures, array[]::text[]),
    coalesce(members.member_count, 0),
    queue.created_at,
    queue.updated_at,
    count(*) over()
  from filtered queue
  left join lateral (
    select
      array_agg(agent.id order by lower(agent.name), agent.id) as member_ids,
      array_agg(agent.name order by lower(agent.name), agent.id) as member_names,
      array_agg(coalesce(agent.picture, '') order by lower(agent.name), agent.id)
        as member_pictures,
      count(*) as member_count
    from public.routing_queue_members member
    join public.agents agent
      on agent.organization_id = member.organization_id
      and agent.id = member.agent_id
    where member.organization_id = queue.organization_id
      and member.routing_queue_id = queue.id
  ) members on true
  order by queue.name asc, queue.id asc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$$;

create function public.list_platform_organization_agents_page(
  p_organization_id uuid,
  p_page integer default 1,
  p_page_size integer default 10,
  p_search text default null
) returns table (
  organization_id uuid,
  id uuid,
  user_id uuid,
  name text,
  email text,
  picture text,
  queue_ids uuid[],
  queue_names text[],
  created_at timestamp with time zone,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  normalized_page integer := greatest(coalesce(p_page, 1), 1);
  normalized_page_size integer := least(greatest(coalesce(p_page_size, 10), 1), 50);
  normalized_search text := lower(btrim(coalesce(p_search, '')));
begin
  perform public.require_platform_admin();

  if not exists (
    select 1 from public.organizations organization
    where organization.id = p_organization_id
  ) then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;

  return query
  with accepted_agents as (
    select
      agent.*,
      coalesce(
        nullif(agent.extra->'invitation'->>'email', ''),
        auth_user.email
      ) as resolved_email
    from public.agents agent
    left join auth.users auth_user on auth_user.id = agent.user_id
    where agent.organization_id = p_organization_id
      and agent.ai = false
      and agent.user_id is not null
      and agent.extra->>'role' = 'agent'
      and coalesce(
        agent.extra->'invitation'->>'status',
        'accepted'
      ) = 'accepted'
  ), filtered as (
    select agent.*
    from accepted_agents agent
    where normalized_search = ''
      or lower(agent.name) like '%' || normalized_search || '%'
      or lower(coalesce(agent.resolved_email, '')) like '%' || normalized_search || '%'
  )
  select
    agent.organization_id,
    agent.id,
    agent.user_id,
    agent.name,
    agent.resolved_email,
    agent.picture,
    coalesce(queues.queue_ids, array[]::uuid[]),
    coalesce(queues.queue_names, array[]::text[]),
    agent.created_at,
    count(*) over()
  from filtered agent
  left join lateral (
    select
      array_agg(queue.id order by lower(queue.name), queue.id) as queue_ids,
      array_agg(queue.name order by lower(queue.name), queue.id) as queue_names
    from public.routing_queue_members member
    join public.routing_queues queue
      on queue.organization_id = member.organization_id
      and queue.id = member.routing_queue_id
    where member.organization_id = agent.organization_id
      and member.agent_id = agent.id
  ) queues on true
  order by lower(agent.name) asc, agent.id asc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$$;

create function public.create_platform_routing_queue(
  p_organization_id uuid,
  p_name text,
  p_agent_ids uuid[] default array[]::uuid[],
  p_request_id uuid default null
) returns public.routing_queues
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  authenticated_user_id uuid;
  normalized_name text := btrim(coalesce(p_name, ''));
  created_queue public.routing_queues;
  existing_event public.platform_admin_action_events;
begin
  authenticated_user_id := public.require_platform_admin();

  if p_request_id is null then
    raise exception using errcode = '22023', message = 'request id is required';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(authenticated_user_id::text || ':' || p_request_id::text, 0)
  );

  select * into existing_event
  from public.platform_admin_action_events event
  where event.platform_admin_user_id = authenticated_user_id
    and event.request_id = p_request_id;

  if found then
    if existing_event.action_type <> 'routing_queue.create'
      or existing_event.organization_id <> p_organization_id
    then
      raise exception using
        errcode = '22023',
        message = 'request id was already used for a different platform action';
    end if;

    select queue.* into created_queue
    from public.routing_queues queue
    where queue.id = existing_event.target_id::uuid;
    return created_queue;
  end if;

  if not exists (
    select 1 from public.organizations organization
    where organization.id = p_organization_id
  ) then
    raise exception using errcode = 'P0002', message = 'organization not found';
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

  insert into public.platform_admin_action_events (
    platform_admin_user_id,
    organization_id,
    action_type,
    target_type,
    target_id,
    request_id,
    after_state
  ) values (
    authenticated_user_id,
    created_queue.organization_id,
    'routing_queue.create',
    'routing_queue',
    created_queue.id::text,
    p_request_id,
    public.get_routing_queue_audit_state(created_queue.id)
  );

  return created_queue;
exception
  when unique_violation then
    raise exception using
      errcode = '23505',
      message = 'routing queue name already exists in this organization';
end;
$$;

create function public.update_platform_routing_queue(
  p_routing_queue_id uuid,
  p_name text,
  p_status text,
  p_agent_ids uuid[] default array[]::uuid[],
  p_request_id uuid default null
) returns public.routing_queues
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  authenticated_user_id uuid;
  normalized_name text := btrim(coalesce(p_name, ''));
  existing_queue public.routing_queues;
  updated_queue public.routing_queues;
  existing_event public.platform_admin_action_events;
  before_state jsonb;
begin
  authenticated_user_id := public.require_platform_admin();

  if p_request_id is null then
    raise exception using errcode = '22023', message = 'request id is required';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(authenticated_user_id::text || ':' || p_request_id::text, 0)
  );

  select * into existing_event
  from public.platform_admin_action_events event
  where event.platform_admin_user_id = authenticated_user_id
    and event.request_id = p_request_id;

  if found then
    if existing_event.action_type <> 'routing_queue.update'
      or existing_event.target_id <> p_routing_queue_id::text
    then
      raise exception using
        errcode = '22023',
        message = 'request id was already used for a different platform action';
    end if;

    select queue.* into updated_queue
    from public.routing_queues queue
    where queue.id = p_routing_queue_id;
    return updated_queue;
  end if;

  select queue.* into existing_queue
  from public.routing_queues queue
  where queue.id = p_routing_queue_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'routing queue not found';
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

  before_state := public.get_routing_queue_audit_state(existing_queue.id);

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

  insert into public.platform_admin_action_events (
    platform_admin_user_id,
    organization_id,
    action_type,
    target_type,
    target_id,
    request_id,
    before_state,
    after_state
  ) values (
    authenticated_user_id,
    updated_queue.organization_id,
    'routing_queue.update',
    'routing_queue',
    updated_queue.id::text,
    p_request_id,
    before_state,
    public.get_routing_queue_audit_state(updated_queue.id)
  );

  return updated_queue;
exception
  when unique_violation then
    raise exception using
      errcode = '23505',
      message = 'routing queue name already exists in this organization';
end;
$$;

revoke execute on function public.get_routing_queue_audit_state(uuid) from public;
revoke execute on function public.get_routing_queue_audit_state(uuid) from anon;
revoke execute on function public.get_routing_queue_audit_state(uuid) from authenticated;

revoke execute on function public.list_platform_routing_queues_page(
  uuid,
  integer,
  integer,
  text,
  text
) from public;

revoke execute on function public.list_platform_organization_agents_page(
  uuid,
  integer,
  integer,
  text
) from public;

revoke execute on function public.create_platform_routing_queue(
  uuid,
  text,
  uuid[],
  uuid
) from public;

revoke execute on function public.update_platform_routing_queue(
  uuid,
  text,
  text,
  uuid[],
  uuid
) from public;

grant execute on function public.list_platform_routing_queues_page(
  uuid,
  integer,
  integer,
  text,
  text
) to authenticated;

grant execute on function public.list_platform_organization_agents_page(
  uuid,
  integer,
  integer,
  text
) to authenticated;

grant execute on function public.create_platform_routing_queue(
  uuid,
  text,
  uuid[],
  uuid
) to authenticated;

grant execute on function public.update_platform_routing_queue(
  uuid,
  text,
  text,
  uuid[],
  uuid
) to authenticated;
