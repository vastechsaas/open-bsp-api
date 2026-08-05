create function public.get_authorized_orgs_by_roles(
  roles public.role[]
) returns setof uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  api_key text;
  org_id uuid;
begin
  -- First, try JWT authentication via auth.uid()
  if auth.uid() is not null then
    return query select organization_id from public.agents
    where
      user_id = auth.uid()
    and (
      extra->'invitation' is null
      or extra->'invitation'->>'status' = 'accepted'
    )
    and extra->>'role' in (
      select allowed_role::text
      from unnest(roles) as allowed_role
    );

    -- Authenticated but lacking the requested role: return the empty set so RLS
    -- subqueries can fall through to other OR-combined policies (e.g. a member
    -- accepting their own invitation while an owner-only policy is also evaluated).
    -- Raising here would short-circuit the whole RLS evaluation.
    -- raise exception using
    --   errcode = '42501',
    --   message = format('insufficient permissions, %s role required', role::text);
    return;
  end if;

  -- Fallback to API key authentication
  api_key := current_setting('request.headers', true)::json->>'api-key';

  if api_key is not null then
    select a.organization_id into org_id
    from public.api_keys a
    where a.key = api_key
    and a.role = any(roles);

    if org_id is not null then
      return next org_id;
    end if;
    -- Same reasoning as the JWT branch: invalid key or insufficient role returns
    -- the empty set, not a raise. Validate api-key existence at the request edge
    -- (e.g. a pre-request hook) if you want loud failure for missing/invalid keys.
    -- raise exception using
    --   errcode = '42501',
    --   message = format('invalid api key or insufficient permissions, %s role required', role::text);
    return;
  end if;

  raise exception using
    errcode = '42501',
    message = 'authentication required',
    hint = 'use api-key header or jwt authentication';
end;
$$;

create function public.get_authorized_orgs(role public.role default 'member') returns setof uuid
language sql
security definer
set search_path to ''
as $$
  select public.get_authorized_orgs_by_roles(
    case role
      when 'owner'::public.role then array['owner']::public.role[]
      when 'admin'::public.role then array['owner', 'admin']::public.role[]
      when 'supervisor'::public.role then array['owner', 'admin', 'supervisor']::public.role[]
      when 'member'::public.role then array['owner', 'admin', 'supervisor', 'member']::public.role[]
      when 'agent'::public.role then array['owner', 'admin', 'supervisor', 'member', 'agent']::public.role[]
      else array[]::public.role[]
    end
  );
$$;

create function public.role_rank(role public.role) returns integer
language sql
immutable
set search_path to ''
as $$
  select case role
    when 'owner'::public.role then 5
    when 'admin'::public.role then 4
    when 'supervisor'::public.role then 3
    when 'member'::public.role then 2
    when 'agent'::public.role then 1
    else 0
  end;
$$;

create function public.get_request_organization_role(
  p_organization_id uuid
) returns public.role
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  request_role public.role;
  api_key text;
begin
  if auth.uid() is not null then
    select (a.extra->>'role')::public.role into request_role
    from public.agents a
    where a.organization_id = p_organization_id
      and a.user_id = auth.uid()
      and a.ai = false
      and (
        a.extra->'invitation' is null
        or a.extra->'invitation'->>'status' = 'accepted'
      )
      and a.extra->>'role' in ('owner', 'admin', 'supervisor', 'member', 'agent')
    limit 1;

    return request_role;
  end if;

  api_key := current_setting('request.headers', true)::json->>'api-key';
  if api_key is not null then
    select a.role into request_role
    from public.api_keys a
    where a.organization_id = p_organization_id
      and a.key = api_key;
  end if;

  return request_role;
exception
  when invalid_text_representation then
    return null;
end;
$$;

create function public.get_current_human_agent_id(
  p_organization_id uuid
) returns uuid
language sql
stable
security definer
set search_path to ''
as $$
  select a.id
  from public.agents a
  where a.organization_id = p_organization_id
    and a.user_id = auth.uid()
    and a.ai = false
    and (
      a.extra->'invitation' is null
      or a.extra->'invitation'->>'status' = 'accepted'
    )
  limit 1;
$$;

create function public.agent_can_read_conversation(
  p_organization_id uuid,
  p_conversation_id uuid
) returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select public.get_request_organization_role(p_organization_id) = 'agent'::public.role
    and exists (
      select 1
      from public.conversations c
      where c.id = p_conversation_id
        and c.organization_id = p_organization_id
        and (
          (
            c.status = 'active'
            and (
              c.assigned_agent_id is null
              or c.assigned_agent_id = public.get_current_human_agent_id(p_organization_id)
            )
          )
          or (
            c.status in ('spam', 'closed')
            and c.assigned_agent_id = public.get_current_human_agent_id(p_organization_id)
          )
        )
    );
$$;

create function public.agent_owns_conversation(
  p_organization_id uuid,
  p_conversation_id uuid
) returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select public.get_request_organization_role(p_organization_id) = 'agent'::public.role
    and exists (
      select 1
      from public.conversations c
      where c.id = p_conversation_id
        and c.organization_id = p_organization_id
        and c.status = 'active'
        and c.assigned_agent_id = public.get_current_human_agent_id(p_organization_id)
    );
$$;

create function public.agent_conversation_update_rules(
  p_id uuid,
  p_organization_id uuid,
  p_service public.service,
  p_organization_address text,
  p_contact_address text,
  p_group_address text,
  p_assigned_agent_id uuid
) returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (
    select 1
    from public.conversations c
    where c.id = p_id
      and c.organization_id = p_organization_id
      and c.service = p_service
      and c.organization_address = p_organization_address
      and c.contact_address is not distinct from p_contact_address
      and c.group_address is not distinct from p_group_address
      and c.assigned_agent_id = p_assigned_agent_id
      and c.assigned_agent_id = public.get_current_human_agent_id(p_organization_id)
  );
$$;

create function public.agent_message_insert_rules(
  p_organization_id uuid,
  p_conversation_id uuid,
  p_agent_id uuid,
  p_direction public.direction,
  p_service public.service,
  p_organization_address text,
  p_group_address text
) returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select public.get_request_organization_role(p_organization_id) = 'agent'::public.role
    and p_direction = 'outgoing'::public.direction
    and p_agent_id = public.get_current_human_agent_id(p_organization_id)
    and exists (
      select 1
      from public.conversations c
      where c.id = p_conversation_id
        and c.organization_id = p_organization_id
        and c.status = 'active'
        and c.assigned_agent_id = p_agent_id
        and c.service = p_service
        and c.organization_address = p_organization_address
        and c.group_address is not distinct from p_group_address
    );
$$;

create function public.agent_can_download_media_object(
  p_name text
) returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (
    select 1
    from public.messages m
    cross join lateral jsonb_path_query(m.content, '$.**') as content_value
    where content_value = to_jsonb('internal://media/' || p_name)
      and public.agent_can_read_conversation(m.organization_id, m.conversation_id)
  );
$$;

-- Check if agent immutable fields match the original (for UPDATE policies)
create function public.agent_update_by_owner_rules(
  p_id uuid,
  p_user_id uuid,
  p_organization_id uuid,
  p_ai boolean,
  p_extra jsonb
) returns boolean
language plpgsql
security definer -- avoid RLS infinite recursion
set search_path to ''
as $$
begin
  return exists (
    select 1 from public.agents
    where id = p_id
      -- updating user_id is not allowed
      and user_id is not distinct from p_user_id
      -- prevent from smuggling into another org
      and organization_id = p_organization_id
      -- once created, ai/human cannot be changed
      and ai = p_ai
      -- sent invitations can only be updated by the receiver
      and extra->'invitation' is not distinct from p_extra->'invitation'
  );
end;
$$;

-- Check if org and role are unchanged (for member self-update)
create function public.member_self_update_rules(
  p_id uuid,
  p_user_id uuid,
  p_organization_id uuid,
  p_ai boolean,
  p_extra jsonb
) returns boolean
language plpgsql
security definer -- avoid RLS infinite recursion
set search_path to ''
as $$
begin
  return exists (
    select 1 from public.agents
    where id = p_id
      -- updating user_id is not allowed
      and user_id = p_user_id
      -- prevent member from smuggling into another org
      and organization_id = p_organization_id
      -- cannot change to ai
      and ai = p_ai
      -- only owners can change update members role
      and extra->>'role' = p_extra->>'role'
  );
end;
$$;

-- Admins and Supervisors can update human Members and Agents without changing their role,
-- invitation state, organization, or identity.
create function public.member_update_by_supervisor_rules(
  p_id uuid,
  p_user_id uuid,
  p_organization_id uuid,
  p_ai boolean,
  p_extra jsonb
) returns boolean
language plpgsql
security definer -- avoid RLS infinite recursion
set search_path to ''
as $$
begin
  return exists (
    select 1 from public.agents
    where id = p_id
      and user_id is not distinct from p_user_id
      and organization_id = p_organization_id
      and ai = false
      and p_ai = false
      and extra->>'role' in ('member', 'agent')
      and extra is not distinct from p_extra
  );
end;
$$;

-- Check if organization name is unchanged (for admin updates)
create function public.org_update_by_admin_rules(
  p_id uuid,
  p_name text
) returns boolean
language plpgsql
security definer -- avoid RLS infinite recursion
set search_path to ''
as $$
begin
  return exists (
    select 1 from public.organizations
    where id = p_id
      -- name cannot be changed by admins
      and name = p_name
  );
end;
$$;

-- Check if contact address fields are unchanged (for contact_id updates)
create function public.contact_address_update_rules(
  p_organization_id uuid,
  p_service public.service,
  p_address text,
  p_extra jsonb,
  p_status text
) returns boolean
language plpgsql
set search_path to ''
as $$
begin
  return exists (
    select 1 from public.contacts_addresses
    where organization_id = p_organization_id
      and address = p_address
      and service = p_service
      and status = p_status
      and extra is not distinct from p_extra
  );
end;
$$;
