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

create function public.list_platform_conversation_report_rows(
  p_organization_id uuid,
  p_month date,
  p_page integer default 1,
  p_page_size integer default 500
) returns table (
  organization_id uuid,
  organization_name text,
  report_month date,
  period_start_utc timestamp with time zone,
  period_end_utc timestamp with time zone,
  conversation_id uuid,
  service public.service,
  organization_address text,
  contact_id uuid,
  customer_name text,
  contact_address text,
  conversation_status text,
  assigned_agent_id uuid,
  assigned_agent_name text,
  conversation_created_at timestamp with time zone,
  first_activity_at_utc timestamp with time zone,
  last_activity_at_utc timestamp with time zone,
  incoming_message_count bigint,
  outgoing_message_count bigint,
  total_message_count bigint,
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
  period_start timestamp with time zone;
  period_end timestamp with time zone;
begin
  perform public.require_platform_admin();

  if p_organization_id is null or not exists (
    select 1
    from public.organizations as organization
    where organization.id = p_organization_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'organization not found';
  end if;

  if p_month is null
    or p_month <> date_trunc('month', p_month)::date
  then
    raise exception using
      errcode = '22023',
      message = 'report month must be the first day of a calendar month';
  end if;

  normalized_page := greatest(coalesce(p_page, 1), 1);
  normalized_page_size := least(greatest(coalesce(p_page_size, 500), 1), 500);
  period_start := p_month::timestamp at time zone 'UTC';
  period_end := (p_month + interval '1 month')::timestamp at time zone 'UTC';

  return query
  with monthly_activity as materialized (
    select
      message.conversation_id,
      min(message.timestamp) as first_activity,
      max(message.timestamp) as last_activity,
      count(*) filter (
        where message.direction = 'incoming'::public.direction
      ) as incoming_count,
      count(*) filter (
        where message.direction = 'outgoing'::public.direction
      ) as outgoing_count,
      count(*) as message_count
    from public.messages as message
    where message.organization_id = p_organization_id
      and message.direction in (
        'incoming'::public.direction,
        'outgoing'::public.direction
      )
      and message.timestamp >= period_start
      and message.timestamp < period_end
    group by message.conversation_id
  ), report_rows as (
    select
      organization.id as tenant_id,
      organization.name as tenant_name,
      conversation.id as target_conversation_id,
      conversation.service as conversation_service,
      conversation.organization_address as business_address,
      contact.id as target_contact_id,
      coalesce(contact.name, conversation.name) as target_customer_name,
      conversation.contact_address as target_contact_address,
      conversation.status as current_status,
      conversation.assigned_agent_id as current_assigned_agent_id,
      assigned_agent.name as current_assigned_agent_name,
      conversation.created_at as conversation_created,
      activity.first_activity,
      activity.last_activity,
      activity.incoming_count,
      activity.outgoing_count,
      activity.message_count
    from monthly_activity as activity
    join public.conversations as conversation
      on conversation.organization_id = p_organization_id
      and conversation.id = activity.conversation_id
    join public.organizations as organization
      on organization.id = conversation.organization_id
    left join public.contacts_addresses as contact_address_row
      on contact_address_row.organization_id = conversation.organization_id
      and contact_address_row.address = conversation.contact_address
    left join public.contacts as contact
      on contact.organization_id = conversation.organization_id
      and contact.id = contact_address_row.contact_id
    left join public.agents as assigned_agent
      on assigned_agent.organization_id = conversation.organization_id
      and assigned_agent.id = conversation.assigned_agent_id
  )
  select
    report_row.tenant_id,
    report_row.tenant_name,
    p_month,
    period_start,
    period_end,
    report_row.target_conversation_id,
    report_row.conversation_service,
    report_row.business_address,
    report_row.target_contact_id,
    report_row.target_customer_name,
    report_row.target_contact_address,
    report_row.current_status,
    report_row.current_assigned_agent_id,
    report_row.current_assigned_agent_name,
    report_row.conversation_created,
    report_row.first_activity,
    report_row.last_activity,
    report_row.incoming_count,
    report_row.outgoing_count,
    report_row.message_count,
    count(*) over()
  from report_rows as report_row
  order by
    report_row.last_activity desc,
    report_row.target_conversation_id desc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$$;

revoke execute on function public.list_platform_conversation_report_rows(
  uuid,
  date,
  integer,
  integer
) from public;

grant execute on function public.list_platform_conversation_report_rows(
  uuid,
  date,
  integer,
  integer
) to authenticated;

create function public.list_platform_campaign_report_rows(
  p_organization_id uuid,
  p_month date,
  p_page integer default 1,
  p_page_size integer default 500
) returns table (
  organization_id uuid,
  organization_name text,
  report_month date,
  period_start_utc timestamp with time zone,
  period_end_utc timestamp with time zone,
  campaign_id uuid,
  campaign_name text,
  organization_address text,
  audience_type public.campaign_audience_type,
  campaign_status text,
  created_by_agent_id uuid,
  created_by_agent_name text,
  template_name text,
  template_language text,
  launched_at_utc timestamp with time zone,
  last_updated_at_utc timestamp with time zone,
  queued_count bigint,
  processing_count bigint,
  accepted_count bigint,
  failed_count bigint,
  total_recipient_count bigint,
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
  period_start timestamp with time zone;
  period_end timestamp with time zone;
begin
  perform public.require_platform_admin();

  if p_organization_id is null or not exists (
    select 1
    from public.organizations as organization
    where organization.id = p_organization_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'organization not found';
  end if;

  if p_month is null
    or p_month <> date_trunc('month', p_month)::date
  then
    raise exception using
      errcode = '22023',
      message = 'report month must be the first day of a calendar month';
  end if;

  normalized_page := greatest(coalesce(p_page, 1), 1);
  normalized_page_size := least(greatest(coalesce(p_page_size, 500), 1), 500);
  period_start := p_month::timestamp at time zone 'UTC';
  period_end := (p_month + interval '1 month')::timestamp at time zone 'UTC';

  return query
  with delivery_summary as materialized (
    select
      delivery.campaign_id,
      min(delivery.created_at) as launched_at,
      count(*) filter (where delivery.status = 'queued') as queued,
      count(*) filter (where delivery.status = 'processing') as processing,
      count(*) filter (where delivery.status = 'accepted') as accepted,
      count(*) filter (where delivery.status = 'failed') as failed,
      count(*) as recipients
    from public.campaign_deliveries as delivery
    where delivery.organization_id = p_organization_id
    group by delivery.campaign_id
  ), report_rows as (
    select
      organization.id as tenant_id,
      organization.name as tenant_name,
      campaign.id as target_campaign_id,
      campaign.name as target_campaign_name,
      campaign.organization_address as business_address,
      campaign.audience_type as target_audience_type,
      campaign.status as current_status,
      campaign.created_by as creator_id,
      creator.name as creator_name,
      campaign.template->>'name' as target_template_name,
      campaign.template->>'language' as target_template_language,
      delivery.launched_at,
      campaign.updated_at as last_updated_at,
      delivery.queued,
      delivery.processing,
      delivery.accepted,
      delivery.failed,
      delivery.recipients
    from delivery_summary as delivery
    join public.campaigns as campaign
      on campaign.organization_id = p_organization_id
      and campaign.id = delivery.campaign_id
    join public.organizations as organization
      on organization.id = campaign.organization_id
    left join public.agents as creator
      on creator.organization_id = campaign.organization_id
      and creator.id = campaign.created_by
    where delivery.launched_at >= period_start
      and delivery.launched_at < period_end
  )
  select
    report_row.tenant_id,
    report_row.tenant_name,
    p_month,
    period_start,
    period_end,
    report_row.target_campaign_id,
    report_row.target_campaign_name,
    report_row.business_address,
    report_row.target_audience_type,
    report_row.current_status,
    report_row.creator_id,
    report_row.creator_name,
    report_row.target_template_name,
    report_row.target_template_language,
    report_row.launched_at,
    report_row.last_updated_at,
    report_row.queued,
    report_row.processing,
    report_row.accepted,
    report_row.failed,
    report_row.recipients,
    count(*) over()
  from report_rows as report_row
  order by report_row.launched_at desc, report_row.target_campaign_id desc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$$;

revoke execute on function public.list_platform_campaign_report_rows(
  uuid,
  date,
  integer,
  integer
) from public;

grant execute on function public.list_platform_campaign_report_rows(
  uuid,
  date,
  integer,
  integer
) to authenticated;

create function public.record_platform_report_export(
  p_organization_id uuid,
  p_report_type text,
  p_month date,
  p_request_id uuid,
  p_row_count bigint
) returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  authenticated_user_id uuid;
  normalized_report_type text;
  event_id uuid;
  existing_event public.platform_report_export_events;
begin
  authenticated_user_id := public.require_platform_admin();
  normalized_report_type := lower(btrim(coalesce(p_report_type, '')));

  if p_organization_id is null or not exists (
    select 1
    from public.organizations as organization
    where organization.id = p_organization_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'organization not found';
  end if;

  if normalized_report_type not in ('conversations', 'campaigns') then
    raise exception using
      errcode = '22023',
      message = 'report type must be conversations or campaigns';
  end if;

  if p_month is null
    or p_month <> date_trunc('month', p_month)::date
  then
    raise exception using
      errcode = '22023',
      message = 'report month must be the first day of a calendar month';
  end if;

  if p_request_id is null then
    raise exception using
      errcode = '22023',
      message = 'request id is required';
  end if;

  if p_row_count is null or p_row_count < 0 then
    raise exception using
      errcode = '22023',
      message = 'row count must be zero or greater';
  end if;

  insert into public.platform_report_export_events (
    platform_admin_user_id,
    organization_id,
    report_type,
    report_month,
    request_id,
    row_count
  ) values (
    authenticated_user_id,
    p_organization_id,
    normalized_report_type,
    p_month,
    p_request_id,
    p_row_count
  )
  on conflict (platform_admin_user_id, request_id) do nothing
  returning id into event_id;

  if event_id is not null then
    return event_id;
  end if;

  select * into existing_event
  from public.platform_report_export_events as export_event
  where export_event.platform_admin_user_id = authenticated_user_id
    and export_event.request_id = p_request_id;

  if existing_event.organization_id <> p_organization_id
    or existing_event.report_type <> normalized_report_type
    or existing_event.report_month <> p_month
    or existing_event.row_count <> p_row_count
  then
    raise exception using
      errcode = '22023',
      message = 'request id was already used for a different report export';
  end if;

  return existing_event.id;
end;
$$;

revoke execute on function public.record_platform_report_export(
  uuid,
  text,
  date,
  uuid,
  bigint
) from public;

grant execute on function public.record_platform_report_export(
  uuid,
  text,
  date,
  uuid,
  bigint
) to authenticated;
