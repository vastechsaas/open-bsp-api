create function public.enforce_human_conversation_assignee() returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if new.assigned_agent_id is null then
    return new;
  end if;

  if not exists (
    select 1
    from public.agents
    where id = new.assigned_agent_id
      and organization_id = new.organization_id
      and ai = false
      and user_id is not null
  ) then
    raise exception 'Conversation assignee must be a human agent in the same organization'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger enforce_human_conversation_assignee
before insert or update of assigned_agent_id, organization_id
on public.conversations
for each row
execute function public.enforce_human_conversation_assignee();

create function public.assign_conversation_to_me(
  p_conversation_id uuid
) returns public.conversations
language plpgsql
security definer
set search_path to ''
as $$
declare
  updated_conversation public.conversations;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'authentication required';
  end if;

  update public.conversations c
  set assigned_agent_id = a.id
  from public.agents a
  where c.id = p_conversation_id
    and c.assigned_agent_id is null
    and c.organization_id in (
      select public.get_authorized_orgs('agent')
    )
    and (
      public.get_request_organization_role(c.organization_id) <> 'agent'::public.role
      or c.status = 'active'
    )
    and a.organization_id = c.organization_id
    and a.user_id = auth.uid()
    and a.ai = false
  returning c.* into updated_conversation;

  if found then
    return updated_conversation;
  end if;

  if not exists (
    select 1
    from public.conversations
    where id = p_conversation_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'conversation not found';
  end if;

  if not exists (
    select 1
    from public.conversations
    where id = p_conversation_id
      and organization_id in (
        select public.get_authorized_orgs('agent')
      )
  ) then
    raise exception using
      errcode = '42501',
      message = 'conversation is not accessible to the authenticated user';
  end if;

  if not exists (
    select 1
    from public.agents a
    join public.conversations c
      on c.organization_id = a.organization_id
    where c.id = p_conversation_id
      and a.user_id = auth.uid()
      and a.ai = false
  ) then
    raise exception using
      errcode = '23514',
      message = 'authenticated user is not a human agent in the conversation organization';
  end if;

  raise exception using
    errcode = '23505',
    message = 'conversation is already assigned';
end;
$$;

create function public.unassign_conversation_from_me(
  p_conversation_id uuid
) returns public.conversations
language plpgsql
security definer
set search_path to ''
as $$
declare
  updated_conversation public.conversations;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'authentication required';
  end if;

  update public.conversations c
  set assigned_agent_id = null
  from public.agents a
  where c.id = p_conversation_id
    and c.assigned_agent_id = a.id
    and c.organization_id in (
      select public.get_authorized_orgs('agent')
    )
    and (
      public.get_request_organization_role(c.organization_id) <> 'agent'::public.role
      or c.status = 'active'
    )
    and a.organization_id = c.organization_id
    and a.user_id = auth.uid()
    and a.ai = false
  returning c.* into updated_conversation;

  if found then
    return updated_conversation;
  end if;

  if not exists (
    select 1
    from public.conversations
    where id = p_conversation_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'conversation not found';
  end if;

  if not exists (
    select 1
    from public.conversations
    where id = p_conversation_id
      and organization_id in (
        select public.get_authorized_orgs('agent')
      )
  ) then
    raise exception using
      errcode = '42501',
      message = 'conversation is not accessible to the authenticated user';
  end if;

  if not exists (
    select 1
    from public.conversations c
    join public.agents a
      on a.organization_id = c.organization_id
     and a.id = c.assigned_agent_id
    where c.id = p_conversation_id
      and a.user_id = auth.uid()
      and a.ai = false
  ) then
    raise exception using
      errcode = '42501',
      message = 'conversation is not assigned to the authenticated human agent';
  end if;

  raise exception using
    errcode = '23514',
    message = 'conversation cannot be unassigned';
end;
$$;

create function public.set_conversation_agent_assignment(
  p_conversation_id uuid,
  p_agent_id uuid
) returns public.conversations
language plpgsql
security definer
set search_path to ''
as $$
declare
  target_conversation public.conversations;
  caller_role public.role;
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

  update public.conversations
  set assigned_agent_id = p_agent_id
  where id = p_conversation_id
  returning * into target_conversation;

  return target_conversation;
end;
$$;

create function public.create_conversation_for_me(
  p_organization_id uuid,
  p_service public.service,
  p_organization_address text,
  p_contact_address text default null,
  p_group_address text default null,
  p_name text default null,
  p_extra jsonb default null
) returns public.conversations
language plpgsql
security definer
set search_path to ''
as $$
declare
  current_agent_id uuid;
  created_conversation public.conversations;
begin
  if public.get_request_organization_role(p_organization_id) <> 'agent'::public.role then
    raise exception using
      errcode = '42501',
      message = 'only an accepted Agent can create a self-assigned conversation';
  end if;

  current_agent_id := public.get_current_human_agent_id(p_organization_id);
  if current_agent_id is null then
    raise exception using
      errcode = '42501',
      message = 'authenticated Agent membership is not available';
  end if;

  insert into public.conversations (
    organization_id,
    service,
    organization_address,
    contact_address,
    group_address,
    name,
    assigned_agent_id,
    extra,
    status
  ) values (
    p_organization_id,
    p_service,
    p_organization_address,
    p_contact_address,
    p_group_address,
    p_name,
    current_agent_id,
    p_extra,
    'active'
  )
  returning * into created_conversation;

  return created_conversation;
end;
$$;

revoke execute on function public.set_conversation_agent_assignment(uuid, uuid)
from public;
grant execute on function public.set_conversation_agent_assignment(uuid, uuid)
to authenticated;

revoke execute on function public.create_conversation_for_me(
  uuid,
  public.service,
  text,
  text,
  text,
  text,
  jsonb
) from public;
grant execute on function public.create_conversation_for_me(
  uuid,
  public.service,
  text,
  text,
  text,
  text,
  jsonb
) to authenticated;
