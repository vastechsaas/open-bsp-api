create function public.archive_organization(
  p_organization_id uuid,
  p_expected_name text,
  p_reason text,
  p_request_id uuid
) returns table (
  organization_id uuid,
  status text,
  archived_at timestamp with time zone,
  purge_eligible_at timestamp with time zone
)
language plpgsql
security definer
set search_path to ''
as $$
declare
  actor_user_id uuid := auth.uid();
  actor_scope text;
  target public.organizations;
  lifecycle public.organization_lifecycle;
  previous_state jsonb;
  statuses jsonb;
begin
  if actor_user_id is null then
    raise exception using errcode = '42501', message = 'authentication required';
  end if;
  if p_request_id is null then
    raise exception using errcode = '22023', message = 'request id is required';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using errcode = '22023', message = 'archive reason is required';
  end if;

  select event.actor_scope into actor_scope
  from public.organization_lifecycle_events event
  where event.request_id = p_request_id
    and event.organization_id = p_organization_id
    and event.action_type = 'organization.archive';

  if actor_scope is not null then
    return query
    select state.organization_id, state.status, state.archived_at, state.purge_eligible_at
    from public.organization_lifecycle state
    where state.organization_id = p_organization_id;
    return;
  end if;

  select organization.* into target
  from public.organizations organization
  where organization.id = p_organization_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;
  if target.name <> p_expected_name then
    raise exception using errcode = '22023', message = 'organization name confirmation does not match';
  end if;

  if public.is_platform_admin() then
    actor_scope := 'platform_admin';
  elsif exists (
    select 1 from public.agents agent
    where agent.organization_id = p_organization_id
      and agent.user_id = actor_user_id
      and agent.ai = false
      and agent.extra->>'role' = 'owner'
      and (agent.extra->'invitation' is null or agent.extra->'invitation'->>'status' = 'accepted')
  ) then
    actor_scope := 'owner';
  else
    raise exception using errcode = '42501', message = 'owner or platform administrator access required';
  end if;

  select state.* into lifecycle
  from public.organization_lifecycle state
  where state.organization_id = p_organization_id
  for update;

  if lifecycle.status = 'archived' then
    return query select lifecycle.organization_id, lifecycle.status, lifecycle.archived_at, lifecycle.purge_eligible_at;
    return;
  end if;

  select coalesce(jsonb_object_agg(account.service::text || ':' || account.address, account.status), '{}'::jsonb)
  into statuses
  from public.organizations_addresses account
  where account.organization_id = p_organization_id;

  previous_state := to_jsonb(lifecycle);

  update public.organization_lifecycle state set
    status = 'archived',
    archived_at = clock_timestamp(),
    archived_by_user_id = actor_user_id,
    archived_by_scope = actor_scope,
    archive_reason = btrim(p_reason),
    purge_eligible_at = clock_timestamp() + interval '30 days',
    restored_at = null,
    restored_by_user_id = null,
    restored_by_scope = null,
    restore_reason = null,
    address_statuses = statuses
  where state.organization_id = p_organization_id
  returning state.* into lifecycle;

  update public.organizations_addresses account
  set status = 'archived'
  where account.organization_id = p_organization_id
    and account.status = 'connected';

  insert into public.organization_lifecycle_events (
    organization_id, organization_name, action_type, actor_user_id,
    actor_scope, request_id, reason, before_state, after_state
  ) values (
    p_organization_id, target.name, 'organization.archive', actor_user_id,
    actor_scope, p_request_id, btrim(p_reason), previous_state, to_jsonb(lifecycle)
  );

  return query select lifecycle.organization_id, lifecycle.status, lifecycle.archived_at, lifecycle.purge_eligible_at;
end;
$$;

create function public.restore_organization(
  p_organization_id uuid,
  p_reason text,
  p_request_id uuid
) returns table (
  organization_id uuid,
  status text,
  restored_at timestamp with time zone
)
language plpgsql
security definer
set search_path to ''
as $$
declare
  actor_user_id uuid := auth.uid();
  actor_scope text;
  target public.organizations;
  lifecycle public.organization_lifecycle;
  previous_state jsonb;
begin
  if actor_user_id is null then
    raise exception using errcode = '42501', message = 'authentication required';
  end if;
  if p_request_id is null then
    raise exception using errcode = '22023', message = 'request id is required';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using errcode = '22023', message = 'restore reason is required';
  end if;

  if exists (
    select 1 from public.organization_lifecycle_events event
    where event.request_id = p_request_id
      and event.organization_id = p_organization_id
      and event.action_type = 'organization.restore'
  ) then
    return query
    select state.organization_id, state.status, state.restored_at
    from public.organization_lifecycle state
    where state.organization_id = p_organization_id;
    return;
  end if;

  select organization.* into target
  from public.organizations organization
  where organization.id = p_organization_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;

  select state.* into lifecycle
  from public.organization_lifecycle state
  where state.organization_id = p_organization_id
  for update;

  if public.is_platform_admin() then
    actor_scope := 'platform_admin';
  elsif lifecycle.purge_eligible_at > clock_timestamp() and exists (
    select 1 from public.agents agent
    where agent.organization_id = p_organization_id
      and agent.user_id = actor_user_id
      and agent.ai = false
      and agent.extra->>'role' = 'owner'
      and (agent.extra->'invitation' is null or agent.extra->'invitation'->>'status' = 'accepted')
  ) then
    actor_scope := 'owner';
  else
    raise exception using errcode = '42501', message = 'platform administrator access required after the recovery window';
  end if;

  if lifecycle.status = 'active' then
    return query select lifecycle.organization_id, lifecycle.status, lifecycle.restored_at;
    return;
  end if;

  previous_state := to_jsonb(lifecycle);

  update public.organizations_addresses account
  set status = coalesce(
    lifecycle.address_statuses->>(account.service::text || ':' || account.address),
    case when account.status = 'archived' then 'disconnected' else account.status end
  )
  where account.organization_id = p_organization_id
    and account.status = 'archived';

  update public.organization_lifecycle state set
    status = 'active',
    restored_at = clock_timestamp(),
    restored_by_user_id = actor_user_id,
    restored_by_scope = actor_scope,
    restore_reason = btrim(p_reason),
    purge_eligible_at = null,
    address_statuses = '{}'::jsonb
  where state.organization_id = p_organization_id
  returning state.* into lifecycle;

  insert into public.organization_lifecycle_events (
    organization_id, organization_name, action_type, actor_user_id,
    actor_scope, request_id, reason, before_state, after_state
  ) values (
    p_organization_id, target.name, 'organization.restore', actor_user_id,
    actor_scope, p_request_id, btrim(p_reason), previous_state, to_jsonb(lifecycle)
  );

  return query select lifecycle.organization_id, lifecycle.status, lifecycle.restored_at;
end;
$$;

create function public.list_my_archived_organizations_page(
  p_page integer default 1,
  p_page_size integer default 10,
  p_search text default null
) returns table (
  organization_id uuid,
  organization_name text,
  archived_at timestamp with time zone,
  purge_eligible_at timestamp with time zone,
  archive_reason text,
  can_restore boolean,
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
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'authentication required';
  end if;

  return query
  select organization.id, organization.name, lifecycle.archived_at,
    lifecycle.purge_eligible_at, lifecycle.archive_reason,
    lifecycle.purge_eligible_at > clock_timestamp(), count(*) over()
  from public.organizations organization
  join public.organization_lifecycle lifecycle on lifecycle.organization_id = organization.id
  join public.agents agent on agent.organization_id = organization.id
  where lifecycle.status = 'archived'
    and agent.user_id = auth.uid()
    and agent.ai = false
    and agent.extra->>'role' = 'owner'
    and (agent.extra->'invitation' is null or agent.extra->'invitation'->>'status' = 'accepted')
    and (normalized_search = '' or lower(organization.name) like '%' || normalized_search || '%')
  order by lifecycle.archived_at desc, organization.id desc
  limit normalized_page_size offset (normalized_page - 1) * normalized_page_size;
end;
$$;

create function public.purge_archived_organization(
  p_organization_id uuid,
  p_expected_name text,
  p_reason text,
  p_request_id uuid,
  p_actor_user_id uuid
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  target public.organizations;
  lifecycle public.organization_lifecycle;
  prior_event public.organization_lifecycle_events;
begin
  select event.* into prior_event
  from public.organization_lifecycle_events event
  where event.request_id = p_request_id;
  if found then
    return prior_event.after_state;
  end if;

  if p_actor_user_id is null or not exists (
    select 1 from public.platform_admins admin
    where admin.user_id = p_actor_user_id and admin.active = true
  ) then
    raise exception using errcode = '42501', message = 'active platform administrator required';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using errcode = '22023', message = 'purge reason is required';
  end if;

  select organization.* into target
  from public.organizations organization
  where organization.id = p_organization_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;
  if target.name <> p_expected_name then
    raise exception using errcode = '22023', message = 'organization name confirmation does not match';
  end if;

  select state.* into lifecycle
  from public.organization_lifecycle state
  where state.organization_id = p_organization_id
  for update;
  if lifecycle.status <> 'archived' or lifecycle.purge_eligible_at > clock_timestamp() then
    raise exception using errcode = '22023', message = 'organization is not eligible for permanent purge';
  end if;

  insert into public.organization_lifecycle_events (
    organization_id, organization_name, action_type, actor_user_id,
    actor_scope, request_id, reason, before_state, after_state
  ) values (
    p_organization_id, target.name, 'organization.purge', p_actor_user_id,
    'platform_admin', p_request_id, btrim(p_reason), to_jsonb(lifecycle),
    jsonb_build_object('organization_id', p_organization_id, 'status', 'purged', 'purged_at', clock_timestamp())
  );

  perform set_config('app.organization_purge', 'on', true);
  delete from public.organizations where id = p_organization_id;

  return jsonb_build_object('organization_id', p_organization_id, 'status', 'purged');
end;
$$;

create function public.list_platform_organization_lifecycle_page(
  p_page integer default 1,
  p_page_size integer default 10,
  p_search text default null,
  p_status text default null
) returns table (
  organization_id uuid,
  organization_name text,
  lifecycle_status text,
  archived_at timestamp with time zone,
  purge_eligible_at timestamp with time zone,
  archive_reason text,
  archived_by_scope text,
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
  normalized_status text := nullif(lower(btrim(coalesce(p_status, ''))), '');
begin
  perform public.require_platform_admin();
  if normalized_status is not null and normalized_status not in ('active', 'archived') then
    raise exception using errcode = '22023', message = 'invalid lifecycle status';
  end if;

  return query
  select organization.id, organization.name, lifecycle.status,
    lifecycle.archived_at, lifecycle.purge_eligible_at,
    lifecycle.archive_reason, lifecycle.archived_by_scope, count(*) over()
  from public.organizations organization
  join public.organization_lifecycle lifecycle on lifecycle.organization_id = organization.id
  where (normalized_status is null or lifecycle.status = normalized_status)
    and (normalized_search = ''
      or lower(organization.name) like '%' || normalized_search || '%'
      or organization.id::text like '%' || normalized_search || '%')
  order by
    case when lifecycle.status = 'archived' then 0 else 1 end,
    lifecycle.archived_at desc nulls last,
    organization.updated_at desc,
    organization.id desc
  limit normalized_page_size offset (normalized_page - 1) * normalized_page_size;
end;
$$;

revoke execute on function public.archive_organization(uuid, text, text, uuid) from public, anon;
revoke execute on function public.restore_organization(uuid, text, uuid) from public, anon;
revoke execute on function public.list_my_archived_organizations_page(integer, integer, text) from public, anon;
revoke execute on function public.purge_archived_organization(uuid, text, text, uuid, uuid) from public, anon, authenticated;
revoke execute on function public.list_platform_organization_lifecycle_page(integer, integer, text, text) from public, anon;

grant execute on function public.archive_organization(uuid, text, text, uuid) to authenticated;
grant execute on function public.restore_organization(uuid, text, uuid) to authenticated;
grant execute on function public.list_my_archived_organizations_page(integer, integer, text) to authenticated;
grant execute on function public.purge_archived_organization(uuid, text, text, uuid, uuid) to service_role;
grant execute on function public.list_platform_organization_lifecycle_page(integer, integer, text, text) to authenticated;
