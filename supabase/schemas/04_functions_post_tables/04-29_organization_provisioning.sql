create function public.provision_platform_organization(
  p_request_id uuid,
  p_organization_name text,
  p_owner_name text,
  p_owner_email text,
  p_members jsonb default '[]'::jsonb,
  p_max_agent_seats integer default null,
  p_storage_quota_gb integer default 25,
  p_auto_assign boolean default false
) returns public.organization_provisioning
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  authenticated_user_id uuid;
  normalized_organization_name text := btrim(coalesce(p_organization_name, ''));
  normalized_owner_name text := btrim(coalesce(p_owner_name, ''));
  normalized_owner_email text := lower(btrim(coalesce(p_owner_email, '')));
  normalized_members jsonb := '[]'::jsonb;
  normalized_member jsonb;
  member jsonb;
  member_name text;
  member_email text;
  member_role text;
  seen_emails text[];
  capacity_member_count integer := 0;
  created_organization public.organizations;
  created_agent public.agents;
  invitation_agent_ids uuid[] := array[]::uuid[];
  canonical_payload jsonb;
  existing_provisioning public.organization_provisioning;
  created_provisioning public.organization_provisioning;
begin
  authenticated_user_id := public.require_platform_admin();

  if p_request_id is null then
    raise exception using errcode = '22023', message = 'request id is required';
  end if;

  if char_length(normalized_organization_name) not between 1 and 250 then
    raise exception using
      errcode = '22023',
      message = 'organization name must contain between 1 and 250 characters';
  end if;

  if char_length(normalized_owner_name) not between 1 and 120 then
    raise exception using
      errcode = '22023',
      message = 'owner name must contain between 1 and 120 characters';
  end if;

  if char_length(normalized_owner_email) > 320
    or position('@' in normalized_owner_email) <= 1
  then
    raise exception using errcode = '22023', message = 'valid owner email is required';
  end if;

  if jsonb_typeof(coalesce(p_members, '[]'::jsonb)) <> 'array'
    or jsonb_array_length(coalesce(p_members, '[]'::jsonb)) > 50
  then
    raise exception using
      errcode = '22023',
      message = 'members must be an array containing at most 50 entries';
  end if;

  if p_max_agent_seats is not null and p_max_agent_seats <= 0 then
    raise exception using
      errcode = '22023',
      message = 'agent capacity must be greater than zero';
  end if;

  if p_storage_quota_gb not in (25, 50, 75, 100) then
    raise exception using
      errcode = '22023',
      message = 'storage quota must be 25, 50, 75 or 100 GB';
  end if;

  seen_emails := array[normalized_owner_email];
  for member in select value from jsonb_array_elements(coalesce(p_members, '[]'::jsonb)) loop
    if jsonb_typeof(member) <> 'object' then
      raise exception using errcode = '22023', message = 'each member must be an object';
    end if;

    member_name := btrim(coalesce(member->>'name', ''));
    member_email := lower(btrim(coalesce(member->>'email', '')));
    member_role := lower(btrim(coalesce(member->>'role', '')));

    if char_length(member_name) not between 1 and 120 then
      raise exception using
        errcode = '22023',
        message = 'member name must contain between 1 and 120 characters';
    end if;
    if char_length(member_email) > 320 or position('@' in member_email) <= 1 then
      raise exception using errcode = '22023', message = 'valid member email is required';
    end if;
    if member_role not in ('owner', 'admin', 'supervisor', 'member', 'agent') then
      raise exception using errcode = '22023', message = 'unsupported organization role';
    end if;
    if member_email = any(seen_emails) then
      raise exception using
        errcode = '23505',
        message = 'each onboarding email must be unique';
    end if;

    seen_emails := array_append(seen_emails, member_email);
    if member_role in ('supervisor', 'agent') then
      capacity_member_count := capacity_member_count + 1;
    end if;
    normalized_member := jsonb_build_object(
      'name', member_name,
      'email', member_email,
      'role', member_role
    );
    normalized_members := normalized_members || jsonb_build_array(normalized_member);
  end loop;

  if p_max_agent_seats is not null and capacity_member_count > p_max_agent_seats then
    raise exception using
      errcode = '23514',
      message = 'initial Agents and Supervisors exceed the configured capacity';
  end if;

  canonical_payload := jsonb_build_object(
    'organization_name', normalized_organization_name,
    'owner', jsonb_build_object(
      'name', normalized_owner_name,
      'email', normalized_owner_email
    ),
    'members', normalized_members,
    'max_agent_seats', p_max_agent_seats,
    'storage_quota_gb', p_storage_quota_gb,
    'auto_assign', coalesce(p_auto_assign, false)
  );

  perform pg_advisory_xact_lock(
    hashtextextended(authenticated_user_id::text || ':' || p_request_id::text, 0)
  );

  select provisioning.* into existing_provisioning
  from public.organization_provisioning provisioning
  where provisioning.platform_admin_user_id = authenticated_user_id
    and provisioning.request_id = p_request_id
  for update;

  if found then
    if existing_provisioning.request_payload <> canonical_payload then
      raise exception using
        errcode = '22023',
        message = 'request id was already used with a different onboarding payload';
    end if;

    if existing_provisioning.status = 'failed' then
      update public.organization_provisioning provisioning
      set status = 'pending_invitation', last_error = null
      where provisioning.id = existing_provisioning.id
      returning * into existing_provisioning;

      insert into public.organization_provisioning_events (
        provisioning_id, platform_admin_user_id, organization_id, event_type
      ) values (
        existing_provisioning.id,
        authenticated_user_id,
        existing_provisioning.organization_id,
        'retried'
      );
    end if;

    return existing_provisioning;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('organization-name:' || lower(normalized_organization_name), 0)
  );
  if exists (
    select 1 from public.organizations organization
    where lower(btrim(organization.name)) = lower(normalized_organization_name)
  ) then
    raise exception using
      errcode = '23505',
      message = 'an organization with this name already exists';
  end if;

  perform set_config('app.organization_provisioning', 'on', true);
  insert into public.organizations (name, extra)
  values (
    normalized_organization_name,
    jsonb_build_object('provisioned_by', 'platform_admin')
  ) returning * into created_organization;
  perform set_config('app.organization_provisioning', 'off', true);

  insert into public.organization_agent_capacity (
    organization_id, max_agent_seats, updated_by, updated_by_scope
  ) values (
    created_organization.id, p_max_agent_seats, authenticated_user_id, 'platform'
  );

  update public.organization_media_storage storage
  set quota_bytes = p_storage_quota_gb::bigint * 1000000000,
      updated_by = authenticated_user_id,
      updated_by_scope = 'platform'
  where storage.organization_id = created_organization.id;

  update public.organization_automation_settings settings
  set auto_assign_conversations = coalesce(p_auto_assign, false),
      updated_by_user_id = authenticated_user_id,
      updated_by_scope = 'platform'
  where settings.organization_id = created_organization.id;

  insert into public.agents (organization_id, name, ai, extra)
  values (
    created_organization.id,
    normalized_owner_name,
    false,
    jsonb_build_object(
      'role', 'owner',
      'invitation', jsonb_build_object(
        'organization_name', normalized_organization_name,
        'email', normalized_owner_email,
        'status', 'pending'
      )
    )
  ) returning * into created_agent;
  invitation_agent_ids := array_append(invitation_agent_ids, created_agent.id);

  for member in select value from jsonb_array_elements(normalized_members) loop
    insert into public.agents (organization_id, name, ai, extra)
    values (
      created_organization.id,
      member->>'name',
      false,
      jsonb_build_object(
        'role', member->>'role',
        'invitation', jsonb_build_object(
          'organization_name', normalized_organization_name,
          'email', member->>'email',
          'status', 'pending'
        )
      )
    ) returning * into created_agent;
    invitation_agent_ids := array_append(invitation_agent_ids, created_agent.id);
  end loop;

  insert into public.organization_provisioning (
    request_id,
    platform_admin_user_id,
    organization_id,
    organization_name,
    request_payload,
    invitation_agent_ids
  ) values (
    p_request_id,
    authenticated_user_id,
    created_organization.id,
    normalized_organization_name,
    canonical_payload,
    invitation_agent_ids
  ) returning * into created_provisioning;

  insert into public.organization_provisioning_events (
    provisioning_id,
    platform_admin_user_id,
    organization_id,
    event_type,
    details
  ) values (
    created_provisioning.id,
    authenticated_user_id,
    created_organization.id,
    'started',
    jsonb_build_object('invitation_count', cardinality(invitation_agent_ids))
  );

  return created_provisioning;
end;
$$;

create function public.finish_platform_organization_provisioning(
  p_provisioning_id uuid,
  p_status text,
  p_error text default null
) returns public.organization_provisioning
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  authenticated_user_id uuid;
  current_provisioning public.organization_provisioning;
  updated_provisioning public.organization_provisioning;
begin
  authenticated_user_id := public.require_platform_admin();

  if p_status not in ('completed', 'failed') then
    raise exception using errcode = '22023', message = 'invalid provisioning status';
  end if;
  if p_status = 'failed' and btrim(coalesce(p_error, '')) = '' then
    raise exception using errcode = '22023', message = 'failure reason is required';
  end if;

  select provisioning.* into current_provisioning
  from public.organization_provisioning provisioning
  where provisioning.id = p_provisioning_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'provisioning request not found';
  end if;

  if current_provisioning.status = 'completed' then
    return current_provisioning;
  end if;

  update public.organization_provisioning provisioning
  set status = p_status,
      attempt_count = provisioning.attempt_count + 1,
      last_error = case when p_status = 'failed' then left(btrim(p_error), 2000) else null end,
      completed_at = case when p_status = 'completed' then now() else null end
  where provisioning.id = p_provisioning_id
  returning * into updated_provisioning;

  insert into public.organization_provisioning_events (
    provisioning_id,
    platform_admin_user_id,
    organization_id,
    event_type,
    details
  ) values (
    updated_provisioning.id,
    authenticated_user_id,
    updated_provisioning.organization_id,
    p_status,
    case
      when p_status = 'failed' then jsonb_build_object('error', updated_provisioning.last_error)
      else '{}'::jsonb
    end
  );

  return updated_provisioning;
end;
$$;

create function public.get_platform_organization_provisioning(
  p_provisioning_id uuid
) returns public.organization_provisioning
language plpgsql
stable
security definer
set search_path to ''
as $$
declare result public.organization_provisioning;
begin
  perform public.require_platform_admin();
  select provisioning.* into result
  from public.organization_provisioning provisioning
  where provisioning.id = p_provisioning_id;
  if not found then
    raise exception using errcode = 'P0002', message = 'provisioning request not found';
  end if;
  return result;
end;
$$;

create function public.list_platform_organization_provisioning_page(
  p_page integer default 1,
  p_page_size integer default 25,
  p_search text default null,
  p_status text default null
) returns table (
  id uuid,
  request_id uuid,
  organization_id uuid,
  organization_name text,
  owner_name text,
  owner_email text,
  status text,
  attempt_count integer,
  last_error text,
  completed_at timestamp with time zone,
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
  normalized_page_size integer := least(greatest(coalesce(p_page_size, 25), 1), 50);
  normalized_search text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform public.require_platform_admin();
  if p_status is not null and p_status not in ('pending_invitation', 'completed', 'failed') then
    raise exception using errcode = '22023', message = 'invalid provisioning status filter';
  end if;

  return query
  with filtered as (
    select provisioning.*
    from public.organization_provisioning provisioning
    where (p_status is null or provisioning.status = p_status)
      and (
        normalized_search is null
        or provisioning.organization_name ilike '%' || normalized_search || '%'
        or provisioning.request_payload->'owner'->>'name' ilike '%' || normalized_search || '%'
        or provisioning.request_payload->'owner'->>'email' ilike '%' || normalized_search || '%'
      )
  )
  select
    filtered.id,
    filtered.request_id,
    filtered.organization_id,
    filtered.organization_name,
    filtered.request_payload->'owner'->>'name',
    filtered.request_payload->'owner'->>'email',
    filtered.status,
    filtered.attempt_count,
    filtered.last_error,
    filtered.completed_at,
    filtered.created_at,
    filtered.updated_at,
    count(*) over ()
  from filtered
  order by filtered.updated_at desc, filtered.id desc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$$;

revoke execute on function public.provision_platform_organization(uuid, text, text, text, jsonb, integer, integer, boolean) from public, anon;
revoke execute on function public.finish_platform_organization_provisioning(uuid, text, text) from public, anon;
revoke execute on function public.get_platform_organization_provisioning(uuid) from public, anon;
revoke execute on function public.list_platform_organization_provisioning_page(integer, integer, text, text) from public, anon;

grant execute on function public.provision_platform_organization(uuid, text, text, text, jsonb, integer, integer, boolean) to authenticated;
grant execute on function public.finish_platform_organization_provisioning(uuid, text, text) to authenticated;
grant execute on function public.get_platform_organization_provisioning(uuid) to authenticated;
grant execute on function public.list_platform_organization_provisioning_page(integer, integer, text, text) to authenticated;
