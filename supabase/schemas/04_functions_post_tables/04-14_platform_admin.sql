create function public.is_platform_admin() returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select auth.uid() is not null
    and exists (
      select 1
      from public.platform_admins as platform_admin
      where platform_admin.user_id = auth.uid()
        and platform_admin.active = true
    );
$$;

revoke execute on function public.is_platform_admin() from public;
grant execute on function public.is_platform_admin() to authenticated;

create function public.require_platform_admin() returns uuid
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  authenticated_user_id uuid;
begin
  authenticated_user_id := auth.uid();

  if authenticated_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'authentication required';
  end if;

  if not exists (
    select 1
    from public.platform_admins as platform_admin
    where platform_admin.user_id = authenticated_user_id
      and platform_admin.active = true
  ) then
    raise exception using
      errcode = '42501',
      message = 'platform administrator access required';
  end if;

  return authenticated_user_id;
end;
$$;

revoke execute on function public.require_platform_admin() from public;
revoke execute on function public.require_platform_admin() from anon;
revoke execute on function public.require_platform_admin() from authenticated;

create function public.get_platform_overview() returns table (
  organization_count bigint,
  human_member_count bigint,
  active_contact_count bigint,
  active_conversation_count bigint,
  connected_whatsapp_account_count bigint,
  connected_instagram_account_count bigint
)
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  perform public.require_platform_admin();

  return query
  select
    (select count(*) from public.organizations),
    (
      select count(*)
      from public.agents as agent
      where agent.ai = false
        and agent.user_id is not null
        and (
          agent.extra->'invitation' is null
          or agent.extra->'invitation'->>'status' = 'accepted'
        )
    ),
    (
      select count(*)
      from public.contacts as contact
      where contact.status = 'active'
    ),
    (
      select count(*)
      from public.conversations as conversation
      where conversation.status = 'active'
    ),
    (
      select count(*)
      from public.organizations_addresses as account
      where account.service = 'whatsapp'::public.service
        and account.status = 'connected'
    ),
    (
      select count(*)
      from public.organizations_addresses as account
      where account.service = 'instagram'::public.service
        and account.status = 'connected'
    );
end;
$$;

revoke execute on function public.get_platform_overview() from public;
grant execute on function public.get_platform_overview() to authenticated;

create function public.list_platform_organizations_page(
  p_page integer default 1,
  p_page_size integer default 10,
  p_search text default null
) returns table (
  organization_id uuid,
  organization_name text,
  organization_created_at timestamp with time zone,
  organization_updated_at timestamp with time zone,
  tier_id text,
  tier_name text,
  plan_id text,
  human_member_count bigint,
  active_contact_count bigint,
  active_conversation_count bigint,
  connected_whatsapp_account_count bigint,
  connected_instagram_account_count bigint,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  normalized_page integer;
  normalized_page_size integer;
  normalized_search text;
begin
  perform public.require_platform_admin();

  normalized_page := greatest(coalesce(p_page, 1), 1);
  normalized_page_size := least(greatest(coalesce(p_page_size, 10), 1), 50);
  normalized_search := lower(btrim(coalesce(p_search, '')));

  return query
  with member_counts as (
    select agent.organization_id, count(*) as value
    from public.agents as agent
    where agent.ai = false
      and agent.user_id is not null
      and (
        agent.extra->'invitation' is null
        or agent.extra->'invitation'->>'status' = 'accepted'
      )
    group by agent.organization_id
  ), contact_counts as (
    select contact.organization_id, count(*) as value
    from public.contacts as contact
    where contact.status = 'active'
    group by contact.organization_id
  ), conversation_counts as (
    select conversation.organization_id, count(*) as value
    from public.conversations as conversation
    where conversation.status = 'active'
    group by conversation.organization_id
  ), account_counts as (
    select
      account.organization_id,
      count(*) filter (
        where account.service = 'whatsapp'::public.service
          and account.status = 'connected'
      ) as whatsapp_count,
      count(*) filter (
        where account.service = 'instagram'::public.service
          and account.status = 'connected'
      ) as instagram_count
    from public.organizations_addresses as account
    group by account.organization_id
  ), organizations_with_metrics as (
    select
      organization.id,
      organization.name,
      organization.created_at,
      organization.updated_at,
      subscription.tier_id,
      tier.name as tier_name,
      subscription.plan_id,
      coalesce(member_count.value, 0) as human_members,
      coalesce(contact_count.value, 0) as active_contacts,
      coalesce(conversation_count.value, 0) as active_conversations,
      coalesce(account_count.whatsapp_count, 0) as whatsapp_accounts,
      coalesce(account_count.instagram_count, 0) as instagram_accounts
    from public.organizations as organization
    left join member_counts as member_count
      on member_count.organization_id = organization.id
    left join contact_counts as contact_count
      on contact_count.organization_id = organization.id
    left join conversation_counts as conversation_count
      on conversation_count.organization_id = organization.id
    left join account_counts as account_count
      on account_count.organization_id = organization.id
    left join billing.subscriptions as subscription
      on subscription.organization_id = organization.id
    left join billing.tiers as tier
      on tier.id = subscription.tier_id
    where normalized_search = ''
      or lower(organization.name) like '%' || normalized_search || '%'
      or organization.id::text like '%' || normalized_search || '%'
  )
  select
    organization.id,
    organization.name,
    organization.created_at,
    organization.updated_at,
    organization.tier_id,
    organization.tier_name,
    organization.plan_id,
    organization.human_members,
    organization.active_contacts,
    organization.active_conversations,
    organization.whatsapp_accounts,
    organization.instagram_accounts,
    count(*) over()
  from organizations_with_metrics as organization
  order by organization.updated_at desc, organization.id desc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$$;

revoke execute on function public.list_platform_organizations_page(
  integer,
  integer,
  text
) from public;

grant execute on function public.list_platform_organizations_page(
  integer,
  integer,
  text
) to authenticated;

create function public.get_platform_tenant_summary(
  p_organization_id uuid
) returns table (
  organization_id uuid,
  organization_name text,
  organization_created_at timestamp with time zone,
  organization_updated_at timestamp with time zone,
  tier_id text,
  tier_name text,
  plan_id text,
  human_member_count bigint,
  active_contact_count bigint,
  active_conversation_count bigint,
  connected_whatsapp_account_count bigint,
  connected_instagram_account_count bigint
)
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  perform public.require_platform_admin();

  if p_organization_id is null then
    raise exception using
      errcode = '22023',
      message = 'organization id is required';
  end if;

  return query
  select
    organization.id,
    organization.name,
    organization.created_at,
    organization.updated_at,
    subscription.tier_id,
    tier.name,
    subscription.plan_id,
    (
      select count(*)
      from public.agents as agent
      where agent.organization_id = organization.id
        and agent.ai = false
        and agent.user_id is not null
        and (
          agent.extra->'invitation' is null
          or agent.extra->'invitation'->>'status' = 'accepted'
        )
    ),
    (
      select count(*)
      from public.contacts as contact
      where contact.organization_id = organization.id
        and contact.status = 'active'
    ),
    (
      select count(*)
      from public.conversations as conversation
      where conversation.organization_id = organization.id
        and conversation.status = 'active'
    ),
    (
      select count(*)
      from public.organizations_addresses as account
      where account.organization_id = organization.id
        and account.service = 'whatsapp'::public.service
        and account.status = 'connected'
    ),
    (
      select count(*)
      from public.organizations_addresses as account
      where account.organization_id = organization.id
        and account.service = 'instagram'::public.service
        and account.status = 'connected'
    )
  from public.organizations as organization
  left join billing.subscriptions as subscription
    on subscription.organization_id = organization.id
  left join billing.tiers as tier
    on tier.id = subscription.tier_id
  where organization.id = p_organization_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'organization not found';
  end if;
end;
$$;

revoke execute on function public.get_platform_tenant_summary(uuid) from public;
grant execute on function public.get_platform_tenant_summary(uuid) to authenticated;

create function public.record_platform_access(
  p_organization_id uuid default null,
  p_scope text default 'global',
  p_request_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  authenticated_user_id uuid;
  normalized_scope text;
  existing_event public.platform_admin_access_events;
  event_id uuid;
begin
  authenticated_user_id := public.require_platform_admin();
  normalized_scope := lower(btrim(coalesce(p_scope, '')));

  if p_request_id is null then
    raise exception using
      errcode = '22023',
      message = 'request id is required';
  end if;

  if normalized_scope not in ('global', 'tenant') then
    raise exception using
      errcode = '22023',
      message = 'platform access scope must be global or tenant';
  end if;

  if normalized_scope = 'global' and p_organization_id is not null then
    raise exception using
      errcode = '22023',
      message = 'global platform access cannot specify an organization';
  end if;

  if normalized_scope = 'tenant' and p_organization_id is null then
    raise exception using
      errcode = '22023',
      message = 'tenant platform access requires an organization';
  end if;

  if p_organization_id is not null and not exists (
    select 1
    from public.organizations as organization
    where organization.id = p_organization_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'organization not found';
  end if;

  select * into existing_event
  from public.platform_admin_access_events as access_event
  where access_event.platform_admin_user_id = authenticated_user_id
    and access_event.request_id = p_request_id;

  if found then
    if existing_event.scope <> normalized_scope
      or existing_event.organization_id is distinct from p_organization_id
    then
      raise exception using
        errcode = '22023',
        message = 'request id was already used for a different platform access';
    end if;

    return existing_event.id;
  end if;

  insert into public.platform_admin_access_events (
    platform_admin_user_id,
    organization_id,
    scope,
    request_id
  ) values (
    authenticated_user_id,
    p_organization_id,
    normalized_scope,
    p_request_id
  )
  returning id into event_id;

  return event_id;
end;
$$;

revoke execute on function public.record_platform_access(
  uuid,
  text,
  uuid
) from public;

grant execute on function public.record_platform_access(
  uuid,
  text,
  uuid
) to authenticated;
