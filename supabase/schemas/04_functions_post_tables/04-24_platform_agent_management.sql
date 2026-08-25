create function public.is_counted_agent_seat(
  p_ai boolean,
  p_extra jsonb
) returns boolean
language sql
immutable
set search_path to ''
as $$
  select
    not coalesce(p_ai, true)
    and p_extra->>'role' in ('supervisor', 'agent')
    and coalesce(p_extra->'invitation'->>'status', 'accepted')
      in ('pending', 'accepted');
$$;

create function public.count_organization_agent_seats(
  p_organization_id uuid
) returns bigint
language sql
stable
security definer
set search_path to ''
as $$
  select count(*)
  from public.agents agent
  where agent.organization_id = p_organization_id
    and public.is_counted_agent_seat(agent.ai, agent.extra);
$$;

create function public.enforce_organization_agent_capacity() returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  configured_limit integer;
  current_usage bigint;
begin
  if not public.is_counted_agent_seat(new.ai, new.extra) then
    return new;
  end if;

  if tg_op = 'UPDATE'
    and old.organization_id = new.organization_id
    and public.is_counted_agent_seat(old.ai, old.extra)
  then
    return new;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('organization-agent-capacity:' || new.organization_id::text, 0)
  );

  select capacity.max_agent_seats into configured_limit
  from public.organization_agent_capacity capacity
  where capacity.organization_id = new.organization_id;

  if configured_limit is null then
    return new;
  end if;

  select count(*) into current_usage
  from public.agents agent
  where agent.organization_id = new.organization_id
    and public.is_counted_agent_seat(agent.ai, agent.extra)
    and (tg_op <> 'UPDATE' or agent.id <> new.id);

  if current_usage >= configured_limit then
    raise exception using
      errcode = '23514',
      message = 'organization Agent capacity has been reached';
  end if;

  return new;
end;
$$;

create trigger enforce_organization_agent_capacity
before insert or update of organization_id, ai, extra on public.agents
for each row
execute function public.enforce_organization_agent_capacity();

create function public.get_platform_organization_agent_capacity(
  p_organization_id uuid
) returns table (
  organization_id uuid,
  max_agent_seats integer,
  used_agent_seats bigint,
  over_limit boolean,
  updated_at timestamp with time zone
)
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  perform public.require_platform_admin();

  if not exists (
    select 1 from public.organizations organization
    where organization.id = p_organization_id
  ) then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;

  return query
  select
    p_organization_id,
    capacity.max_agent_seats,
    public.count_organization_agent_seats(p_organization_id),
    capacity.max_agent_seats is not null
      and public.count_organization_agent_seats(p_organization_id)
        > capacity.max_agent_seats,
    capacity.updated_at
  from (values (true)) placeholder(value)
  left join public.organization_agent_capacity capacity
    on capacity.organization_id = p_organization_id;
end;
$$;

create function public.get_platform_organization_agent_audit_state(
  p_agent_id uuid
) returns jsonb
language sql
stable
security definer
set search_path to ''
as $$
  select jsonb_build_object(
    'id', agent.id,
    'organization_id', agent.organization_id,
    'name', agent.name,
    'email', coalesce(
      nullif(agent.extra->'invitation'->>'email', ''),
      auth_user.email
    ),
    'invitation_status', coalesce(
      agent.extra->'invitation'->>'status',
      'accepted'
    ),
    'queue_ids', coalesce(
      (
        select jsonb_agg(member.routing_queue_id order by member.routing_queue_id)
        from public.routing_queue_members member
        where member.organization_id = agent.organization_id
          and member.agent_id = agent.id
      ),
      '[]'::jsonb
    )
  )
  from public.agents agent
  left join auth.users auth_user on auth_user.id = agent.user_id
  where agent.id = p_agent_id;
$$;

create function public.update_platform_organization_agent_capacity(
  p_organization_id uuid,
  p_max_agent_seats integer,
  p_request_id uuid
) returns table (
  organization_id uuid,
  max_agent_seats integer,
  used_agent_seats bigint,
  over_limit boolean,
  updated_at timestamp with time zone
)
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  authenticated_user_id uuid;
  existing_event public.platform_admin_action_events;
  before_state jsonb;
  after_state jsonb;
begin
  authenticated_user_id := public.require_platform_admin();

  if p_request_id is null then
    raise exception using errcode = '22023', message = 'request id is required';
  end if;

  if p_max_agent_seats is not null and p_max_agent_seats <= 0 then
    raise exception using
      errcode = '22023',
      message = 'Agent capacity must be a positive integer or null';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(authenticated_user_id::text || ':' || p_request_id::text, 0)
  );

  select * into existing_event
  from public.platform_admin_action_events event
  where event.platform_admin_user_id = authenticated_user_id
    and event.request_id = p_request_id;

  if found then
    if existing_event.action_type <> 'organization_agent_capacity.update'
      or existing_event.organization_id <> p_organization_id
    then
      raise exception using
        errcode = '22023',
        message = 'request id was already used for a different platform action';
    end if;
    return query
    select * from public.get_platform_organization_agent_capacity(p_organization_id);
    return;
  end if;

  if not exists (
    select 1 from public.organizations organization
    where organization.id = p_organization_id
  ) then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('organization-agent-capacity:' || p_organization_id::text, 0)
  );

  select jsonb_build_object(
    'max_agent_seats', capacity.max_agent_seats,
    'used_agent_seats', public.count_organization_agent_seats(p_organization_id)
  ) into before_state
  from (values (true)) placeholder(value)
  left join public.organization_agent_capacity capacity
    on capacity.organization_id = p_organization_id;

  insert into public.organization_agent_capacity (
    organization_id,
    max_agent_seats,
    updated_by,
    updated_by_scope
  ) values (
    p_organization_id,
    p_max_agent_seats,
    authenticated_user_id,
    'platform'
  )
  on conflict on constraint organization_agent_capacity_pkey do update
  set max_agent_seats = excluded.max_agent_seats,
      updated_by = excluded.updated_by,
      updated_by_scope = excluded.updated_by_scope;

  after_state := jsonb_build_object(
    'max_agent_seats', p_max_agent_seats,
    'used_agent_seats', public.count_organization_agent_seats(p_organization_id)
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
    p_organization_id,
    'organization_agent_capacity.update',
    'organization_agent_capacity',
    p_organization_id::text,
    p_request_id,
    before_state,
    after_state
  );

  return query
  select * from public.get_platform_organization_agent_capacity(p_organization_id);
end;
$$;

create function public.create_platform_organization_agent_invitation(
  p_organization_id uuid,
  p_name text,
  p_email text,
  p_request_id uuid
) returns public.agents
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  authenticated_user_id uuid;
  normalized_name text := btrim(coalesce(p_name, ''));
  normalized_email text := lower(btrim(coalesce(p_email, '')));
  organization_name text;
  created_agent public.agents;
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
    if existing_event.action_type <> 'organization_agent.invite'
      or existing_event.organization_id <> p_organization_id
    then
      raise exception using
        errcode = '22023',
        message = 'request id was already used for a different platform action';
    end if;
    select agent.* into created_agent
    from public.agents agent
    where agent.id = existing_event.target_id::uuid;
    return created_agent;
  end if;

  select organization.name into organization_name
  from public.organizations organization
  where organization.id = p_organization_id;

  if not found then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;

  if char_length(normalized_name) not between 1 and 120 then
    raise exception using
      errcode = '22023',
      message = 'Agent name must contain between 1 and 120 characters';
  end if;

  if char_length(normalized_email) > 320
    or position('@' in normalized_email) <= 1
  then
    raise exception using errcode = '22023', message = 'valid email is required';
  end if;

  if exists (
    select 1
    from public.agents agent
    left join auth.users auth_user on auth_user.id = agent.user_id
    where agent.organization_id = p_organization_id
      and agent.ai = false
      and lower(coalesce(
        nullif(agent.extra->'invitation'->>'email', ''),
        auth_user.email,
        ''
      )) = normalized_email
      and coalesce(agent.extra->'invitation'->>'status', 'accepted')
        in ('pending', 'accepted')
  ) then
    raise exception using
      errcode = '23505',
      message = 'an active membership or invitation already exists for this email';
  end if;

  insert into public.agents (
    organization_id,
    name,
    ai,
    extra
  ) values (
    p_organization_id,
    normalized_name,
    false,
    jsonb_build_object(
      'role', 'agent',
      'invitation', jsonb_build_object(
        'organization_name', organization_name,
        'email', normalized_email,
        'status', 'pending'
      )
    )
  ) returning * into created_agent;

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
    p_organization_id,
    'organization_agent.invite',
    'organization_agent',
    created_agent.id::text,
    p_request_id,
    public.get_platform_organization_agent_audit_state(created_agent.id)
  );

  return created_agent;
end;
$$;

create function public.update_platform_organization_agent(
  p_agent_id uuid,
  p_name text,
  p_routing_queue_ids uuid[] default array[]::uuid[],
  p_request_id uuid default null
) returns public.agents
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  authenticated_user_id uuid;
  normalized_name text := btrim(coalesce(p_name, ''));
  normalized_queue_ids uuid[];
  existing_agent public.agents;
  updated_agent public.agents;
  invitation_status text;
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
    if existing_event.action_type <> 'organization_agent.update'
      or existing_event.target_id <> p_agent_id::text
    then
      raise exception using
        errcode = '22023',
        message = 'request id was already used for a different platform action';
    end if;
    select agent.* into updated_agent
    from public.agents agent where agent.id = p_agent_id;
    return updated_agent;
  end if;

  select agent.* into existing_agent
  from public.agents agent
  where agent.id = p_agent_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Agent not found';
  end if;

  invitation_status := coalesce(
    existing_agent.extra->'invitation'->>'status',
    'accepted'
  );

  if existing_agent.ai
    or existing_agent.extra->>'role' <> 'agent'
    or invitation_status not in ('pending', 'accepted')
  then
    raise exception using
      errcode = '22023',
      message = 'target must be a pending or accepted human Agent';
  end if;

  if char_length(normalized_name) not between 1 and 120 then
    raise exception using
      errcode = '22023',
      message = 'Agent name must contain between 1 and 120 characters';
  end if;

  select coalesce(array_agg(distinct queue_id order by queue_id), array[]::uuid[])
  into normalized_queue_ids
  from unnest(coalesce(p_routing_queue_ids, array[]::uuid[])) queue_id;

  if invitation_status = 'pending' and cardinality(normalized_queue_ids) > 0 then
    raise exception using
      errcode = '22023',
      message = 'pending Agents cannot be assigned to routing queues';
  end if;

  if invitation_status = 'accepted' and exists (
    select 1
    from unnest(normalized_queue_ids) requested(queue_id)
    left join public.routing_queues queue
      on queue.id = requested.queue_id
      and queue.organization_id = existing_agent.organization_id
      and queue.status = 'active'
    where queue.id is null
  ) then
    raise exception using
      errcode = '22023',
      message = 'routing queues must be active and belong to the Agent organization';
  end if;

  before_state := public.get_platform_organization_agent_audit_state(p_agent_id);

  update public.agents agent
  set name = normalized_name
  where agent.id = p_agent_id
  returning * into updated_agent;

  if invitation_status = 'accepted' then
    delete from public.routing_queue_members member
    where member.organization_id = updated_agent.organization_id
      and member.agent_id = updated_agent.id;

    insert into public.routing_queue_members (
      organization_id,
      routing_queue_id,
      agent_id
    )
    select updated_agent.organization_id, queue_id, updated_agent.id
    from unnest(normalized_queue_ids) queue_id;
  end if;

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
    updated_agent.organization_id,
    'organization_agent.update',
    'organization_agent',
    updated_agent.id::text,
    p_request_id,
    before_state,
    public.get_platform_organization_agent_audit_state(updated_agent.id)
  );

  return updated_agent;
end;
$$;

create function public.remove_platform_organization_agent(
  p_agent_id uuid,
  p_request_id uuid
) returns boolean
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  authenticated_user_id uuid;
  existing_agent public.agents;
  existing_event public.platform_admin_action_events;
  before_state jsonb;
  invitation_status text;
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
    if existing_event.action_type <> 'organization_agent.remove'
      or existing_event.target_id <> p_agent_id::text
    then
      raise exception using
        errcode = '22023',
        message = 'request id was already used for a different platform action';
    end if;
    return true;
  end if;

  select agent.* into existing_agent
  from public.agents agent
  where agent.id = p_agent_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Agent not found';
  end if;

  invitation_status := coalesce(
    existing_agent.extra->'invitation'->>'status',
    'accepted'
  );

  if existing_agent.ai
    or existing_agent.extra->>'role' <> 'agent'
    or invitation_status not in ('pending', 'accepted')
  then
    raise exception using
      errcode = '22023',
      message = 'target must be a pending or accepted human Agent';
  end if;

  before_state := public.get_platform_organization_agent_audit_state(p_agent_id);

  delete from public.agents agent where agent.id = p_agent_id;

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
    existing_agent.organization_id,
    'organization_agent.remove',
    'organization_agent',
    existing_agent.id::text,
    p_request_id,
    before_state,
    jsonb_build_object('removed', true)
  );

  return true;
end;
$$;

revoke execute on function public.is_counted_agent_seat(boolean, jsonb) from public, anon, authenticated;
revoke execute on function public.count_organization_agent_seats(uuid) from public, anon, authenticated;
revoke execute on function public.enforce_organization_agent_capacity() from public, anon, authenticated;
revoke execute on function public.get_platform_organization_agent_audit_state(uuid) from public, anon, authenticated;

revoke execute on function public.get_platform_organization_agent_capacity(uuid) from public;
revoke execute on function public.update_platform_organization_agent_capacity(uuid, integer, uuid) from public;
revoke execute on function public.create_platform_organization_agent_invitation(uuid, text, text, uuid) from public;
revoke execute on function public.update_platform_organization_agent(uuid, text, uuid[], uuid) from public;
revoke execute on function public.remove_platform_organization_agent(uuid, uuid) from public;

grant execute on function public.get_platform_organization_agent_capacity(uuid) to authenticated;
grant execute on function public.update_platform_organization_agent_capacity(uuid, integer, uuid) to authenticated;
grant execute on function public.create_platform_organization_agent_invitation(uuid, text, text, uuid) to authenticated;
grant execute on function public.update_platform_organization_agent(uuid, text, uuid[], uuid) to authenticated;
grant execute on function public.remove_platform_organization_agent(uuid, uuid) to authenticated;
