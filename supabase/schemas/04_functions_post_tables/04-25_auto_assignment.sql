create function public.try_auto_assign_conversation(
  p_conversation_id uuid,
  p_source text default 'recovery'
) returns public.conversations
language plpgsql volatile security definer set search_path = ''
as $$
declare
  conversation_row public.conversations;
  queue_row public.routing_queues;
  selected_agent public.agents;
  last_agent_id uuid;
  assignment_time timestamptz := clock_timestamp();
  assignment_event_id uuid;
begin
  select c.* into conversation_row
  from public.conversations c
  where c.id = p_conversation_id
  for update;

  if not found or conversation_row.status <> 'active'
    or conversation_row.assigned_agent_id is not null
    or conversation_row.routing_queue_id is null then
    return conversation_row;
  end if;

  select q.* into queue_row
  from public.routing_queues q
  join public.organization_automation_settings settings
    on settings.organization_id = q.organization_id
   and settings.auto_assign_conversations
  where q.organization_id = conversation_row.organization_id
    and q.id = conversation_row.routing_queue_id
    and q.status = 'active'
    and q.assignment_strategy = 'round_robin';

  if not found then return conversation_row; end if;

  insert into public.routing_queue_assignment_state (
    organization_id, routing_queue_id
  ) values (conversation_row.organization_id, queue_row.id)
  on conflict (organization_id, routing_queue_id) do nothing;

  select state.last_assigned_agent_id into last_agent_id
  from public.routing_queue_assignment_state state
  where state.organization_id = conversation_row.organization_id
    and state.routing_queue_id = queue_row.id
  for update;

  with eligible as (
    select a.*, row_number() over (order by member.created_at, a.id) as position
    from public.routing_queue_members member
    join public.agents a
      on a.organization_id = member.organization_id and a.id = member.agent_id
    join public.agent_assignment_presence presence
      on presence.organization_id = a.organization_id and presence.agent_id = a.id
    where member.organization_id = conversation_row.organization_id
      and member.routing_queue_id = queue_row.id
      and a.ai = false and a.user_id is not null
      and a.extra->>'role' = 'agent'
      and coalesce(a.extra->'invitation'->>'status', 'accepted') = 'accepted'
      and presence.available
      and presence.last_heartbeat_at >= assignment_time - interval '2 minutes'
  ), cursor_position as (
    select position from eligible where id = last_agent_id
  )
  select e.organization_id, e.user_id, e.id, e.name, e.picture, e.ai,
         e.extra, e.created_at, e.updated_at
  into selected_agent
  from eligible e
  order by
    case when e.position > coalesce((select position from cursor_position), 0) then 0 else 1 end,
    e.position
  limit 1;

  if not found then return conversation_row; end if;

  update public.conversations c
  set assigned_agent_id = selected_agent.id
  where c.id = conversation_row.id
  returning * into conversation_row;

  update public.routing_queue_assignment_state state
  set last_assigned_agent_id = selected_agent.id, updated_at = assignment_time
  where state.organization_id = conversation_row.organization_id
    and state.routing_queue_id = queue_row.id;

  insert into public.conversation_assignment_events (
    organization_id, conversation_id, routing_queue_id, routing_queue_name,
    assigned_agent_id, assigned_agent_name, strategy, source, created_at
  ) values (
    conversation_row.organization_id, conversation_row.id, queue_row.id, queue_row.name,
    selected_agent.id, selected_agent.name, 'round_robin', p_source, assignment_time
  ) returning id into assignment_event_id;

  insert into public.messages (
    organization_id, conversation_id, direction, agent_id, service,
    organization_address, group_address, content, status, timestamp
  ) values (
    conversation_row.organization_id, conversation_row.id, 'internal', null,
    conversation_row.service, conversation_row.organization_address,
    conversation_row.group_address,
    jsonb_build_object(
      'version', '1', 'type', 'text', 'kind', 'assignment_event',
      'text', format('Automatically assigned to %s using Round Robin.', selected_agent.name),
      'assignment_event', jsonb_build_object(
        'id', assignment_event_id, 'agent_id', selected_agent.id,
        'agent_name', selected_agent.name, 'queue_id', queue_row.id,
        'queue_name', queue_row.name, 'strategy', 'round_robin', 'source', p_source
      )
    ), '{}'::jsonb, assignment_time
  );

  perform public.enqueue_user_notification(
    conversation_row.organization_id, selected_agent.id, null,
    conversation_row.id, 'conversation_assigned',
    format('automatic_assignment:%s', assignment_event_id),
    jsonb_build_object(
      'assignment_event_id', assignment_event_id,
      'assigned_agent_id', selected_agent.id,
      'routing_queue_id', queue_row.id,
      'routing_queue_name', queue_row.name,
      'strategy', 'round_robin'
    )
  );

  return conversation_row;
end;
$$;

create function public.process_auto_assignment_backlog(
  p_organization_id uuid default null,
  p_routing_queue_id uuid default null,
  p_limit integer default 100,
  p_source text default 'recovery'
) returns integer
language plpgsql volatile security definer set search_path = ''
as $$
declare candidate record; processed integer := 0; result public.conversations;
begin
  for candidate in
    select c.id
    from public.conversations c
    join public.routing_queues q
      on q.organization_id = c.organization_id and q.id = c.routing_queue_id
    join public.organization_automation_settings settings
      on settings.organization_id = c.organization_id
    where c.status = 'active' and c.assigned_agent_id is null
      and settings.auto_assign_conversations
      and q.status = 'active' and q.assignment_strategy = 'round_robin'
      and (p_organization_id is null or c.organization_id = p_organization_id)
      and (p_routing_queue_id is null or c.routing_queue_id = p_routing_queue_id)
    order by coalesce(c.routed_at, c.created_at), c.id
    limit least(greatest(coalesce(p_limit, 100), 1), 100)
  loop
    result := public.try_auto_assign_conversation(candidate.id, p_source);
    if result.assigned_agent_id is not null then processed := processed + 1; end if;
  end loop;
  return processed;
end;
$$;

create function public.get_my_assignment_availability(p_organization_id uuid)
returns table (available boolean, last_heartbeat_at timestamptz, eligible boolean, updated_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
declare v_agent_id uuid;
begin
  if public.get_request_organization_role(p_organization_id) <> 'agent'::public.role then
    raise exception using errcode = '42501', message = 'accepted Agent role required';
  end if;
  v_agent_id := public.get_current_human_agent_id(p_organization_id);
  return query
  select coalesce(p.available, false), p.last_heartbeat_at,
    coalesce(p.available and p.last_heartbeat_at >= clock_timestamp() - interval '2 minutes', false),
    p.updated_at
  from (select 1) seed
  left join public.agent_assignment_presence p
    on p.organization_id = p_organization_id and p.agent_id = v_agent_id;
end;
$$;

create function public.set_my_assignment_availability(p_organization_id uuid, p_available boolean)
returns table (available boolean, last_heartbeat_at timestamptz, eligible boolean, updated_at timestamptz)
language plpgsql volatile security definer set search_path = ''
as $$
declare v_agent_id uuid; state public.agent_assignment_presence;
begin
  if public.get_request_organization_role(p_organization_id) <> 'agent'::public.role
    or p_available is null then
    raise exception using errcode = '42501', message = 'accepted Agent role required';
  end if;
  v_agent_id := public.get_current_human_agent_id(p_organization_id);
  insert into public.agent_assignment_presence (
    organization_id, agent_id, available, last_heartbeat_at, updated_at
  ) values (
    p_organization_id, v_agent_id, p_available,
    case when p_available then clock_timestamp() else null end, clock_timestamp()
  ) on conflict (organization_id, agent_id) do update
    set available = excluded.available,
        last_heartbeat_at = excluded.last_heartbeat_at,
        updated_at = excluded.updated_at
  returning * into state;
  if p_available then
    perform public.process_auto_assignment_backlog(p_organization_id, null, 100, 'agent_available');
  end if;
  return query select state.available, state.last_heartbeat_at,
    state.available and state.last_heartbeat_at >= clock_timestamp() - interval '2 minutes', state.updated_at;
end;
$$;

create function public.heartbeat_my_assignment_availability(p_organization_id uuid)
returns table (available boolean, last_heartbeat_at timestamptz, eligible boolean, updated_at timestamptz)
language plpgsql volatile security definer set search_path = ''
as $$
declare v_agent_id uuid; state public.agent_assignment_presence;
begin
  if public.get_request_organization_role(p_organization_id) <> 'agent'::public.role then
    raise exception using errcode = '42501', message = 'accepted Agent role required';
  end if;
  v_agent_id := public.get_current_human_agent_id(p_organization_id);
  update public.agent_assignment_presence p
  set last_heartbeat_at = clock_timestamp(), updated_at = clock_timestamp()
  where p.organization_id = p_organization_id and p.agent_id = v_agent_id and p.available
  returning * into state;
  if not found then raise exception using errcode = '23514', message = 'Agent is unavailable'; end if;
  perform public.process_auto_assignment_backlog(p_organization_id, null, 100, 'agent_available');
  return query select state.available, state.last_heartbeat_at, true, state.updated_at;
end;
$$;

create function public.update_organization_auto_assignment(p_organization_id uuid, p_enabled boolean)
returns public.organization_automation_settings
language plpgsql volatile security definer set search_path = ''
as $$
declare settings public.organization_automation_settings;
begin
  if public.get_request_organization_role(p_organization_id) not in (
    'owner'::public.role, 'admin'::public.role, 'supervisor'::public.role
  ) or p_enabled is null then
    raise exception using errcode = '42501', message = 'owner, admin, or supervisor role required';
  end if;
  update public.organization_automation_settings s
  set auto_assign_conversations = p_enabled, updated_at = now(),
      updated_by_user_id = auth.uid(), updated_by_scope = 'organization'
  where s.organization_id = p_organization_id returning * into settings;
  if p_enabled then perform public.process_auto_assignment_backlog(p_organization_id, null, 100, 'automation_enabled'); end if;
  return settings;
end;
$$;

create function public.update_routing_queue_assignment_strategy(p_routing_queue_id uuid, p_strategy text)
returns public.routing_queues
language plpgsql volatile security definer set search_path = ''
as $$
declare queue public.routing_queues;
begin
  if p_strategy not in ('manual', 'round_robin') then
    raise exception using errcode = '22023', message = 'invalid assignment strategy';
  end if;
  select q.* into queue from public.routing_queues q where q.id = p_routing_queue_id for update;
  if not found or public.get_request_organization_role(queue.organization_id) not in (
    'owner'::public.role, 'admin'::public.role, 'supervisor'::public.role
  ) then raise exception using errcode = '42501', message = 'queue management permission required'; end if;
  update public.routing_queues q set assignment_strategy = p_strategy where q.id = queue.id returning * into queue;
  if p_strategy = 'round_robin' then perform public.process_auto_assignment_backlog(queue.organization_id, queue.id, 100, 'automation_enabled'); end if;
  return queue;
end;
$$;

create function public.update_platform_organization_auto_assignment(
  p_organization_id uuid, p_enabled boolean, p_request_id uuid
) returns public.organization_automation_settings
language plpgsql volatile security definer set search_path = ''
as $$
declare admin_user_id uuid; existing public.platform_admin_action_events;
  before_settings public.organization_automation_settings;
  after_settings public.organization_automation_settings;
begin
  admin_user_id := public.require_platform_admin();
  if p_enabled is null or p_request_id is null then
    raise exception using errcode = '22023', message = 'enabled state and request id are required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(admin_user_id::text || ':' || p_request_id::text, 0));
  select e.* into existing from public.platform_admin_action_events e
  where e.platform_admin_user_id = admin_user_id and e.request_id = p_request_id;
  if found then
    if existing.action_type <> 'organization_automation.update'
      or existing.organization_id <> p_organization_id
      or existing.target_id <> 'auto_assignment' then
      raise exception using errcode = '22023', message = 'request id already used';
    end if;
    select s.* into after_settings from public.organization_automation_settings s
    where s.organization_id = p_organization_id;
    return after_settings;
  end if;
  select s.* into before_settings from public.organization_automation_settings s
  where s.organization_id = p_organization_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'automation settings not found'; end if;
  update public.organization_automation_settings s
  set auto_assign_conversations = p_enabled, updated_at = now(),
      updated_by_user_id = admin_user_id, updated_by_scope = 'platform'
  where s.organization_id = p_organization_id returning * into after_settings;
  insert into public.platform_admin_action_events (
    platform_admin_user_id, organization_id, action_type, target_type,
    target_id, request_id, before_state, after_state
  ) values (
    admin_user_id, p_organization_id, 'organization_automation.update',
    'organization_automation', 'auto_assignment', p_request_id,
    to_jsonb(before_settings), to_jsonb(after_settings)
  );
  if p_enabled then perform public.process_auto_assignment_backlog(p_organization_id, null, 100, 'automation_enabled'); end if;
  return after_settings;
end;
$$;

create function public.update_platform_routing_queue_assignment_strategy(
  p_organization_id uuid, p_routing_queue_id uuid, p_strategy text, p_request_id uuid
) returns public.routing_queues
language plpgsql volatile security definer set search_path = ''
as $$
declare admin_user_id uuid; existing public.platform_admin_action_events;
  before_queue public.routing_queues; after_queue public.routing_queues;
begin
  admin_user_id := public.require_platform_admin();
  if p_strategy not in ('manual', 'round_robin') or p_request_id is null then
    raise exception using errcode = '22023', message = 'valid strategy and request id are required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(admin_user_id::text || ':' || p_request_id::text, 0));
  select e.* into existing from public.platform_admin_action_events e
  where e.platform_admin_user_id = admin_user_id and e.request_id = p_request_id;
  if found then
    if existing.action_type <> 'routing_queue.update'
      or existing.organization_id <> p_organization_id
      or existing.target_id <> p_routing_queue_id::text then
      raise exception using errcode = '22023', message = 'request id already used';
    end if;
    select q.* into after_queue from public.routing_queues q where q.id = p_routing_queue_id;
    return after_queue;
  end if;
  select q.* into before_queue from public.routing_queues q
  where q.organization_id = p_organization_id and q.id = p_routing_queue_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'routing queue not found'; end if;
  update public.routing_queues q set assignment_strategy = p_strategy
  where q.id = p_routing_queue_id returning * into after_queue;
  insert into public.platform_admin_action_events (
    platform_admin_user_id, organization_id, action_type, target_type,
    target_id, request_id, before_state, after_state
  ) values (
    admin_user_id, p_organization_id, 'routing_queue.update', 'routing_queue',
    p_routing_queue_id::text, p_request_id, to_jsonb(before_queue), to_jsonb(after_queue)
  );
  if p_strategy = 'round_robin' then perform public.process_auto_assignment_backlog(p_organization_id, p_routing_queue_id, 100, 'automation_enabled'); end if;
  return after_queue;
end;
$$;

revoke all on table public.agent_assignment_presence from anon, authenticated;
revoke all on table public.routing_queue_assignment_state from anon, authenticated;
revoke all on table public.conversation_assignment_events from anon, authenticated;
grant select on table public.agent_assignment_presence to authenticated;
grant select on table public.conversation_assignment_events to authenticated;

revoke execute on function public.try_auto_assign_conversation(uuid, text) from public, anon, authenticated;
revoke execute on function public.process_auto_assignment_backlog(uuid, uuid, integer, text) from public, anon, authenticated;
grant execute on function public.try_auto_assign_conversation(uuid, text) to service_role;
grant execute on function public.process_auto_assignment_backlog(uuid, uuid, integer, text) to service_role;
revoke execute on function public.get_my_assignment_availability(uuid) from public;
revoke execute on function public.set_my_assignment_availability(uuid, boolean) from public;
revoke execute on function public.heartbeat_my_assignment_availability(uuid) from public;
revoke execute on function public.update_organization_auto_assignment(uuid, boolean) from public;
revoke execute on function public.update_routing_queue_assignment_strategy(uuid, text) from public;
revoke execute on function public.update_platform_organization_auto_assignment(uuid, boolean, uuid) from public;
revoke execute on function public.update_platform_routing_queue_assignment_strategy(uuid, uuid, text, uuid) from public;
grant execute on function public.get_my_assignment_availability(uuid) to authenticated;
grant execute on function public.set_my_assignment_availability(uuid, boolean) to authenticated;
grant execute on function public.heartbeat_my_assignment_availability(uuid) to authenticated;
grant execute on function public.update_organization_auto_assignment(uuid, boolean) to authenticated;
grant execute on function public.update_routing_queue_assignment_strategy(uuid, text) to authenticated;
grant execute on function public.update_platform_organization_auto_assignment(uuid, boolean, uuid) to authenticated;
grant execute on function public.update_platform_routing_queue_assignment_strategy(uuid, uuid, text, uuid) to authenticated;
