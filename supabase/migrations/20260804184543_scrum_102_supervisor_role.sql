drop policy "admins can manage their orgs quick replies" on "public"."quick_replies";

drop policy "members can read their org ledger" on "billing"."ledger";

drop policy "members can read their org subscription" on "billing"."subscriptions";

drop policy "members can read their org usage" on "billing"."usage";

drop policy "members can create CSV recipients for campaign drafts" on "public"."campaign_csv_recipients";

drop policy "members can delete CSV recipients for campaign drafts" on "public"."campaign_csv_recipients";

drop policy "members can read their orgs campaign CSV recipients" on "public"."campaign_csv_recipients";

drop policy "members can update CSV recipients for campaign drafts" on "public"."campaign_csv_recipients";

drop policy "members can read their orgs campaign deliveries" on "public"."campaign_deliveries";

drop policy "members can create their orgs campaign drafts" on "public"."campaigns";

drop policy "members can delete their orgs campaign drafts" on "public"."campaigns";

drop policy "members can read their orgs campaigns" on "public"."campaigns";

drop policy "members can update their orgs campaign drafts" on "public"."campaigns";

drop policy "members can read their orgs chatbot deployments" on "public"."chatbot_flow_deployments";

drop policy "members can read their orgs chatbot flow runs" on "public"."chatbot_flow_runs";

drop policy "members can read their orgs chatbot flow versions" on "public"."chatbot_flow_versions";

drop policy "members can read their orgs chatbot flows" on "public"."chatbot_flows";

drop policy "members can read their orgs logs" on "public"."logs";

alter table "public"."api_keys" add constraint "api_keys_role_check" CHECK ((role = ANY (ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]))) not valid;

alter table "public"."api_keys" validate constraint "api_keys_role_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.get_authorized_orgs_by_roles(roles public.role[])
 RETURNS SETOF uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_authorized_orgs(role public.role DEFAULT 'member'::public.role)
 RETURNS SETOF uuid
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select public.get_authorized_orgs_by_roles(
    case role
      when 'owner'::public.role then array['owner']::public.role[]
      when 'admin'::public.role then array['owner', 'admin']::public.role[]
      when 'supervisor'::public.role then array['owner', 'admin', 'supervisor']::public.role[]
      when 'member'::public.role then array['owner', 'admin', 'supervisor', 'member']::public.role[]
      else array[]::public.role[]
    end
  );
$function$
;

CREATE OR REPLACE FUNCTION public.get_campaign_audience_count(p_organization_id uuid, p_campaign_id uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  campaign public.campaigns;
  audience_count bigint;
begin
  if not exists (
    select 1
    from public.get_authorized_orgs_by_roles(
      array['owner', 'admin', 'member']::public.role[]
    ) as authorized_orgs(id)
    where authorized_orgs.id = p_organization_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  select * into campaign
  from public.campaigns
  where id = p_campaign_id
    and organization_id = p_organization_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'campaign not found';
  end if;

  case campaign.audience_type
    when 'all_contacts'::public.campaign_audience_type then
      select count(*) into audience_count
      from public.contacts_addresses ca
      join public.contacts c on c.id = ca.contact_id
      where ca.organization_id = p_organization_id
        and ca.service = 'whatsapp'::public.service
        and ca.status = 'active'
        and c.status = 'active';

    when 'active_24h'::public.campaign_audience_type then
      select count(*) into audience_count
      from public.contacts_addresses ca
      join public.contacts c on c.id = ca.contact_id
      where ca.organization_id = p_organization_id
        and ca.service = 'whatsapp'::public.service
        and ca.status = 'active'
        and c.status = 'active'
        and exists (
          select 1
          from public.messages m
          where m.organization_id = ca.organization_id
            and m.organization_address = campaign.organization_address
            and m.contact_address = ca.address
            and m.service = 'whatsapp'::public.service
            and m.direction = 'incoming'::public.direction
            and m.timestamp >= now() - interval '24 hours'
        );

    when 'csv_upload'::public.campaign_audience_type then
      select count(*) into audience_count
      from public.campaign_csv_recipients r
      where r.organization_id = p_organization_id
        and r.campaign_id = p_campaign_id;
  end case;

  return audience_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_campaign_audience_preview(p_organization_id uuid, p_campaign_id uuid, p_limit integer DEFAULT 20)
 RETURNS TABLE(contact_address text, name text, variables jsonb)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  campaign public.campaigns;
  normalized_limit integer;
begin
  if not exists (
    select 1
    from public.get_authorized_orgs_by_roles(
      array['owner', 'admin', 'member']::public.role[]
    ) as authorized_orgs(id)
    where authorized_orgs.id = p_organization_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  select * into campaign
  from public.campaigns
  where id = p_campaign_id
    and organization_id = p_organization_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'campaign not found';
  end if;

  normalized_limit := least(greatest(coalesce(p_limit, 20), 1), 500);

  case campaign.audience_type
    when 'all_contacts'::public.campaign_audience_type then
      return query
      select ca.address, c.name, '{}'::jsonb
      from public.contacts_addresses ca
      join public.contacts c on c.id = ca.contact_id
      where ca.organization_id = p_organization_id
        and ca.service = 'whatsapp'::public.service
        and ca.status = 'active'
        and c.status = 'active'
      order by c.name nulls last, ca.address
      limit normalized_limit;

    when 'active_24h'::public.campaign_audience_type then
      return query
      select ca.address, c.name, '{}'::jsonb
      from public.contacts_addresses ca
      join public.contacts c on c.id = ca.contact_id
      where ca.organization_id = p_organization_id
        and ca.service = 'whatsapp'::public.service
        and ca.status = 'active'
        and c.status = 'active'
        and exists (
          select 1
          from public.messages m
          where m.organization_id = ca.organization_id
            and m.organization_address = campaign.organization_address
            and m.contact_address = ca.address
            and m.service = 'whatsapp'::public.service
            and m.direction = 'incoming'::public.direction
            and m.timestamp >= now() - interval '24 hours'
        )
      order by c.name nulls last, ca.address
      limit normalized_limit;

    when 'csv_upload'::public.campaign_audience_type then
      return query
      select r.contact_address, r.name, r.variables
      from public.campaign_csv_recipients r
      where r.organization_id = p_organization_id
        and r.campaign_id = p_campaign_id
      order by r.name nulls last, r.contact_address
      limit normalized_limit;
  end case;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_campaigns_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text, p_audience_type public.campaign_audience_type DEFAULT NULL::public.campaign_audience_type, p_readiness text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, id uuid, created_by uuid, name text, service public.service, organization_address text, template jsonb, template_variable_mapping jsonb, header_media jsonb, audience_type public.campaign_audience_type, status text, queued_count integer, processing_count integer, accepted_count integer, failed_count integer, created_at timestamp with time zone, updated_at timestamp with time zone, audience_count bigint, readiness text, total_count bigint)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  normalized_page integer;
  normalized_page_size integer;
  normalized_search text;
  normalized_readiness text;
begin
  if not exists (
    select 1
    from public.get_authorized_orgs_by_roles(
      array['owner', 'admin', 'member']::public.role[]
    ) as authorized_orgs(id)
    where authorized_orgs.id = p_organization_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  normalized_page := greatest(coalesce(p_page, 1), 1);
  normalized_page_size := least(greatest(coalesce(p_page_size, 10), 1), 100);
  normalized_search := lower(btrim(coalesce(p_search, '')));
  normalized_readiness := nullif(lower(btrim(coalesce(p_readiness, ''))), '');

  if normalized_readiness is not null
    and normalized_readiness not in ('ready', 'needs_attention')
  then
    raise exception using
      errcode = '22023',
      message = 'campaign readiness filter is invalid';
  end if;

  return query
  with counted as materialized (
    select
      c.*,
      case c.audience_type
        when 'all_contacts'::public.campaign_audience_type then (
          select count(*)
          from public.contacts_addresses ca
          join public.contacts contact on contact.id = ca.contact_id
          where ca.organization_id = c.organization_id
            and ca.service = 'whatsapp'::public.service
            and ca.status = 'active'
            and contact.status = 'active'
        )
        when 'active_24h'::public.campaign_audience_type then (
          select count(*)
          from public.contacts_addresses ca
          join public.contacts contact on contact.id = ca.contact_id
          where ca.organization_id = c.organization_id
            and ca.service = 'whatsapp'::public.service
            and ca.status = 'active'
            and contact.status = 'active'
            and exists (
              select 1
              from public.messages m
              where m.organization_id = ca.organization_id
                and m.organization_address = c.organization_address
                and m.contact_address = ca.address
                and m.service = 'whatsapp'::public.service
                and m.direction = 'incoming'::public.direction
                and m.timestamp >= now() - interval '24 hours'
            )
        )
        when 'csv_upload'::public.campaign_audience_type then (
          select count(*)
          from public.campaign_csv_recipients recipient
          where recipient.organization_id = c.organization_id
            and recipient.campaign_id = c.id
        )
      end as campaign_audience_count
    from public.campaigns c
    where c.organization_id = p_organization_id
      and (p_audience_type is null or c.audience_type = p_audience_type)
      and (
        normalized_search = ''
        or position(normalized_search in lower(c.name)) > 0
        or position(normalized_search in lower(c.organization_address)) > 0
        or position(
          normalized_search in lower(coalesce(c.template->>'name', ''))
        ) > 0
      )
  ), classified as (
    select
      counted.*,
      case
        when counted.template->>'status' = 'APPROVED'
          and counted.campaign_audience_count > 0
          and not exists (
            select 1
            from jsonb_array_elements(
              case when jsonb_typeof(counted.template->'components') = 'array'
                then counted.template->'components' else '[]'::jsonb end
            ) as media_component(value)
            where media_component.value->>'type' = 'HEADER'
              and media_component.value->>'format' in ('IMAGE', 'VIDEO', 'DOCUMENT')
              and (
                counted.header_media is null
                or counted.header_media->>'format' <> media_component.value->>'format'
                or coalesce(counted.header_media->>'media_id', '') = ''
              )
          )
          and not exists (
            select 1
            from jsonb_array_elements(
              case
                when jsonb_typeof(counted.template->'components') = 'array'
                  then counted.template->'components'
                else '[]'::jsonb
              end
            ) as component(value)
            cross join lateral regexp_matches(
              coalesce(component.value->>'text', ''),
              '\{\{\s*([0-9]+)\s*\}\}',
              'g'
            ) as variable_match(match)
            where component.value->>'type' in ('HEADER', 'BODY')
              and coalesce(
                btrim(
                  counted.template_variable_mapping->>(
                    lower(component.value->>'type')
                    || '.'
                    || (variable_match.match)[1]
                  )
                ),
                ''
              ) = ''
          )
          and not exists (
            select 1
            from jsonb_array_elements(
              case
                when jsonb_typeof(counted.template->'components') = 'array'
                  then counted.template->'components'
                else '[]'::jsonb
              end
            ) as buttons_component(value)
            cross join lateral jsonb_array_elements(
              case
                when jsonb_typeof(buttons_component.value->'buttons') = 'array'
                  then buttons_component.value->'buttons'
                else '[]'::jsonb
              end
            ) with ordinality as button(value, position)
            where buttons_component.value->>'type' = 'BUTTONS'
              and button.value->>'type' = 'URL'
              and button.value->>'url' like '%{{1}}'
              and coalesce(
                btrim(
                  counted.template_variable_mapping->>(
                    'button.' || (button.position - 1)::text || '.1'
                  )
                ),
                ''
              ) = ''
          )
          then 'ready'
        else 'needs_attention'
      end as campaign_readiness
    from counted
  )
  select
    classified.organization_id,
    classified.id,
    classified.created_by,
    classified.name,
    classified.service,
    classified.organization_address,
    classified.template,
    classified.template_variable_mapping,
    classified.header_media,
    classified.audience_type,
    classified.status,
    classified.queued_count,
    classified.processing_count,
    classified.accepted_count,
    classified.failed_count,
    classified.created_at,
    classified.updated_at,
    classified.campaign_audience_count,
    classified.campaign_readiness,
    count(*) over() as total_count
  from classified
  where normalized_readiness is null
    or classified.campaign_readiness = normalized_readiness
  order by classified.updated_at desc, classified.id desc
  offset (normalized_page - 1) * normalized_page_size
  limit normalized_page_size;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_chatbot_flows_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, id uuid, created_by uuid, created_by_name text, name text, status text, created_at timestamp with time zone, updated_at timestamp with time zone, draft_id uuid, draft_version integer, draft_updated_at timestamp with time zone, published_version_id uuid, published_version integer, published_at timestamp with time zone, has_unpublished_changes boolean, total_count bigint)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  normalized_page integer;
  normalized_page_size integer;
  normalized_search text;
  normalized_status text;
begin
  if not exists (
    select 1
    from public.get_authorized_orgs_by_roles(
      array['owner', 'admin', 'member']::public.role[]
    ) as authorized_orgs(id)
    where authorized_orgs.id = p_organization_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  normalized_page := greatest(coalesce(p_page, 1), 1);
  normalized_page_size := least(
    greatest(coalesce(p_page_size, 10), 1),
    50
  );
  normalized_search := lower(btrim(coalesce(p_search, '')));
  normalized_status := nullif(lower(btrim(coalesce(p_status, ''))), '');

  if normalized_status is not null
    and normalized_status not in ('active', 'archived')
  then
    raise exception using
      errcode = '22023',
      message = 'chatbot flow status filter is invalid';
  end if;

  return query
  with listed as materialized (
    select
      flow.organization_id,
      flow.id,
      flow.created_by,
      creator.name as created_by_name,
      flow.name,
      flow.status,
      flow.created_at,
      greatest(
        flow.updated_at,
        coalesce(draft.updated_at, flow.updated_at),
        coalesce(published.updated_at, flow.updated_at)
      ) as updated_at,
      draft.id as draft_id,
      draft.version as draft_version,
      draft.updated_at as draft_updated_at,
      published.id as published_version_id,
      published.version as published_version,
      published.published_at,
      case
        when draft.id is null then false
        when published.id is null then true
        else draft.editor_graph is distinct from published.editor_graph
      end as has_unpublished_changes
    from public.chatbot_flows as flow
    left join public.agents as creator
      on creator.organization_id = flow.organization_id
      and creator.id = flow.created_by
    left join lateral (
      select
        version.id,
        version.version,
        version.editor_graph,
        version.updated_at
      from public.chatbot_flow_versions as version
      where version.organization_id = flow.organization_id
        and version.flow_id = flow.id
        and version.status = 'draft'
      order by version.version desc, version.id desc
      limit 1
    ) as draft on true
    left join lateral (
      select
        version.id,
        version.version,
        version.editor_graph,
        version.published_at,
        version.updated_at
      from public.chatbot_flow_versions as version
      where version.organization_id = flow.organization_id
        and version.flow_id = flow.id
        and version.status = 'published'
      order by version.version desc, version.id desc
      limit 1
    ) as published on true
    where flow.organization_id = p_organization_id
      and (
        normalized_status is null
        or flow.status = normalized_status
      )
      and (
        normalized_search = ''
        or position(normalized_search in lower(flow.name)) > 0
      )
  )
  select
    listed.organization_id,
    listed.id,
    listed.created_by,
    listed.created_by_name,
    listed.name,
    listed.status,
    listed.created_at,
    listed.updated_at,
    listed.draft_id,
    listed.draft_version,
    listed.draft_updated_at,
    listed.published_version_id,
    listed.published_version,
    listed.published_at,
    listed.has_unpublished_changes,
    count(*) over() as total_count
  from listed
  order by listed.updated_at desc, listed.id desc
  offset (normalized_page - 1) * normalized_page_size
  limit normalized_page_size;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_members_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text, p_role public.role DEFAULT NULL::public.role, p_status text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, id uuid, user_id uuid, name text, email text, picture text, role public.role, status text, is_last_owner boolean, created_at timestamp with time zone, updated_at timestamp with time zone, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  normalized_page integer;
  normalized_page_size integer;
  normalized_search text;
  normalized_status text;
begin
  if not exists (
    select 1
    from public.get_authorized_orgs('member') as authorized_orgs(id)
    where authorized_orgs.id = p_organization_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  normalized_page := greatest(coalesce(p_page, 1), 1);
  normalized_page_size := least(greatest(coalesce(p_page_size, 10), 1), 50);
  normalized_search := lower(btrim(coalesce(p_search, '')));
  normalized_status := nullif(lower(btrim(coalesce(p_status, ''))), '');

  if normalized_status is not null
    and normalized_status not in ('active', 'pending', 'rejected')
  then
    raise exception using
      errcode = '22023',
      message = 'member status filter is invalid';
  end if;

  return query
  with members as (
    select
      agent.organization_id,
      agent.id,
      agent.user_id,
      agent.name,
      coalesce(
        nullif(agent.extra->'invitation'->>'email', ''),
        auth_user.email
      ) as email,
      agent.picture,
      case agent.extra->>'role'
        when 'owner' then 'owner'::public.role
        when 'admin' then 'admin'::public.role
        when 'supervisor' then 'supervisor'::public.role
        else 'member'::public.role
      end as role,
      case agent.extra->'invitation'->>'status'
        when 'pending' then 'pending'
        when 'rejected' then 'rejected'
        else 'active'
      end as status,
      count(*) filter (
        where agent.extra->>'role' = 'owner'
          and (
            agent.extra->'invitation' is null
            or agent.extra->'invitation'->>'status' = 'accepted'
          )
      ) over () as owner_count,
      agent.created_at,
      agent.updated_at
    from public.agents as agent
    left join auth.users as auth_user on auth_user.id = agent.user_id
    where agent.organization_id = p_organization_id
      and agent.ai = false
  ),
  filtered_members as (
    select member_row.*
    from members as member_row
    where (
      normalized_search = ''
      or lower(member_row.name) like '%' || normalized_search || '%'
      or lower(coalesce(member_row.email, '')) like '%' || normalized_search || '%'
    )
      and (p_role is null or member_row.role = p_role)
      and (normalized_status is null or member_row.status = normalized_status)
  )
  select
    member.organization_id,
    member.id,
    member.user_id,
    member.name,
    member.email,
    member.picture,
    member.role,
    member.status,
    member.role = 'owner'::public.role
      and member.status = 'active'
      and member.owner_count = 1 as is_last_owner,
    member.created_at,
    member.updated_at,
    count(*) over() as total_count
  from filtered_members as member
  order by member.updated_at desc, member.id desc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.start_campaign(p_organization_id uuid, p_campaign_id uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  campaign public.campaigns;
  component jsonb;
  button record;
  variable_match text[];
  mapping_key text;
  mapping_value text;
  csv_column text;
  snapshot_count bigint;
begin
  if not exists (
    select 1
    from public.get_authorized_orgs_by_roles(
      array['owner', 'admin', 'member']::public.role[]
    ) as authorized_orgs(id)
    where authorized_orgs.id = p_organization_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  select * into campaign
  from public.campaigns
  where id = p_campaign_id
    and organization_id = p_organization_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'campaign not found';
  end if;

  if campaign.status <> 'draft' then
    raise exception using
      errcode = '23514',
      message = 'campaign has already been started';
  end if;

  if not exists (
    select 1
    from public.organizations_addresses oa
    where oa.organization_id = p_organization_id
      and oa.address = campaign.organization_address
      and oa.service = 'whatsapp'::public.service
      and oa.status = 'connected'
  ) then
    raise exception using
      errcode = '23514',
      message = 'campaign WhatsApp account is not connected';
  end if;

  if campaign.template->>'status' <> 'APPROVED' then
    raise exception using
      errcode = '23514',
      message = 'campaign template is not approved';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(
      case when jsonb_typeof(campaign.template->'components') = 'array'
        then campaign.template->'components' else '[]'::jsonb end
    ) component(value)
    where component.value->>'type' = 'HEADER'
      and component.value->>'format' in ('IMAGE', 'VIDEO', 'DOCUMENT')
      and (
        campaign.header_media is null
        or campaign.header_media->>'format' <> component.value->>'format'
        or coalesce(campaign.header_media->>'media_id', '') = ''
      )
  ) then
    raise exception using
      errcode = '23514',
      message = 'campaign media is missing or does not match the template header';
  end if;

  if jsonb_typeof(campaign.template->'components') = 'array' then
    for component in
      select value
      from jsonb_array_elements(campaign.template->'components')
      where value->>'type' in ('HEADER', 'BODY')
    loop
      for variable_match in
        select regexp_matches(
          coalesce(component->>'text', ''),
          '\{\{\s*([0-9]+)\s*\}\}',
          'g'
        )
      loop
        mapping_key := lower(component->>'type') || '.' || variable_match[1];
        mapping_value := campaign.template_variable_mapping->>mapping_key;

        if coalesce(btrim(mapping_value), '') = '' then
          raise exception using
            errcode = '23514',
            message = format('campaign template variable %s is not mapped', mapping_key);
        end if;

        if mapping_value in ('contact.name', 'contact.address') then
          continue;
        end if;

        if campaign.audience_type = 'csv_upload'::public.campaign_audience_type
          and mapping_value like 'csv.%'
        then
          csv_column := substring(mapping_value from 5);
          if coalesce(csv_column, '') <> '' and exists (
            select 1
            from public.campaign_csv_recipients r
            where r.organization_id = p_organization_id
              and r.campaign_id = p_campaign_id
              and r.variables ? csv_column
          ) then
            continue;
          end if;
        end if;

        raise exception using
          errcode = '23514',
          message = format('campaign template variable %s has an invalid mapping', mapping_key);
      end loop;
    end loop;

    for button in
      select button_value.value, button_value.position
      from jsonb_array_elements(campaign.template->'components') component(value)
      cross join lateral jsonb_array_elements(
        case
          when jsonb_typeof(component.value->'buttons') = 'array'
            then component.value->'buttons'
          else '[]'::jsonb
        end
      ) with ordinality button_value(value, position)
      where component.value->>'type' = 'BUTTONS'
        and button_value.value->>'type' = 'URL'
        and button_value.value->>'url' like '%{{1}}'
    loop
      mapping_key := 'button.' || (button.position - 1)::text || '.1';
      mapping_value := campaign.template_variable_mapping->>mapping_key;

      if coalesce(btrim(mapping_value), '') = '' then
        raise exception using
          errcode = '23514',
          message = format('campaign template variable %s is not mapped', mapping_key);
      end if;

      if mapping_value in ('contact.name', 'contact.address') then
        continue;
      end if;

      if campaign.audience_type = 'csv_upload'::public.campaign_audience_type
        and mapping_value like 'csv.%'
      then
        csv_column := substring(mapping_value from 5);
        if coalesce(csv_column, '') <> '' and exists (
          select 1
          from public.campaign_csv_recipients r
          where r.organization_id = p_organization_id
            and r.campaign_id = p_campaign_id
            and r.variables ? csv_column
        ) then
          continue;
        end if;
      end if;

      raise exception using
        errcode = '23514',
        message = format('campaign template variable %s has an invalid mapping', mapping_key);
    end loop;
  end if;

  case campaign.audience_type
    when 'all_contacts'::public.campaign_audience_type then
      insert into public.campaign_deliveries (
        organization_id,
        campaign_id,
        contact_address,
        name,
        variables
      )
      select distinct
        p_organization_id,
        p_campaign_id,
        ca.address,
        c.name,
        '{}'::jsonb
      from public.contacts_addresses ca
      join public.contacts c on c.id = ca.contact_id
      where ca.organization_id = p_organization_id
        and ca.service = 'whatsapp'::public.service
        and ca.status = 'active'
        and c.status = 'active'
      on conflict (campaign_id, contact_address) do nothing;

    when 'active_24h'::public.campaign_audience_type then
      insert into public.campaign_deliveries (
        organization_id,
        campaign_id,
        contact_address,
        name,
        variables
      )
      select distinct
        p_organization_id,
        p_campaign_id,
        ca.address,
        c.name,
        '{}'::jsonb
      from public.contacts_addresses ca
      join public.contacts c on c.id = ca.contact_id
      where ca.organization_id = p_organization_id
        and ca.service = 'whatsapp'::public.service
        and ca.status = 'active'
        and c.status = 'active'
        and exists (
          select 1
          from public.messages m
          where m.organization_id = ca.organization_id
            and m.organization_address = campaign.organization_address
            and m.contact_address = ca.address
            and m.service = 'whatsapp'::public.service
            and m.direction = 'incoming'::public.direction
            and m.timestamp >= now() - interval '24 hours'
        )
      on conflict (campaign_id, contact_address) do nothing;

    when 'csv_upload'::public.campaign_audience_type then
      insert into public.campaign_deliveries (
        organization_id,
        campaign_id,
        contact_address,
        name,
        variables
      )
      select
        r.organization_id,
        r.campaign_id,
        r.contact_address,
        r.name,
        r.variables
      from public.campaign_csv_recipients r
      where r.organization_id = p_organization_id
        and r.campaign_id = p_campaign_id
      on conflict (campaign_id, contact_address) do nothing;
  end case;

  get diagnostics snapshot_count = row_count;

  if snapshot_count = 0 then
    raise exception using
      errcode = '23514',
      message = 'campaign audience is empty';
  end if;

  update public.campaigns
  set
    status = 'queued',
    queued_count = snapshot_count,
    processing_count = 0,
    accepted_count = 0,
    failed_count = 0
  where id = p_campaign_id
    and organization_id = p_organization_id;

  return snapshot_count;
end;
$function$
;


  create policy "supervisors can manage their orgs quick replies"
  on "public"."quick_replies"
  as permissive
  for all
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs('supervisor'::public.role) AS get_authorized_orgs)));



  create policy "members can read their org ledger"
  on "billing"."ledger"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs_by_roles(ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]) AS get_authorized_orgs_by_roles)));


  create policy "members can read their org subscription"
  on "billing"."subscriptions"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs_by_roles(ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]) AS get_authorized_orgs_by_roles)));



  create policy "members can read their org usage"
  on "billing"."usage"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs_by_roles(ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]) AS get_authorized_orgs_by_roles)));



  create policy "members can create CSV recipients for campaign drafts"
  on "public"."campaign_csv_recipients"
  as permissive
  for insert
  to authenticated, anon
with check (((organization_id IN ( SELECT public.get_authorized_orgs_by_roles(ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]) AS get_authorized_orgs_by_roles)) AND (EXISTS ( SELECT 1
   FROM public.campaigns c
  WHERE ((c.organization_id = campaign_csv_recipients.organization_id) AND (c.id = campaign_csv_recipients.campaign_id) AND (c.status = 'draft'::text))))));



  create policy "members can delete CSV recipients for campaign drafts"
  on "public"."campaign_csv_recipients"
  as permissive
  for delete
  to authenticated, anon
using (((organization_id IN ( SELECT public.get_authorized_orgs_by_roles(ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]) AS get_authorized_orgs_by_roles)) AND (EXISTS ( SELECT 1
   FROM public.campaigns c
  WHERE ((c.organization_id = campaign_csv_recipients.organization_id) AND (c.id = campaign_csv_recipients.campaign_id) AND (c.status = 'draft'::text))))));



  create policy "members can read their orgs campaign CSV recipients"
  on "public"."campaign_csv_recipients"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs_by_roles(ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]) AS get_authorized_orgs_by_roles)));



  create policy "members can update CSV recipients for campaign drafts"
  on "public"."campaign_csv_recipients"
  as permissive
  for update
  to authenticated, anon
using (((organization_id IN ( SELECT public.get_authorized_orgs_by_roles(ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]) AS get_authorized_orgs_by_roles)) AND (EXISTS ( SELECT 1
   FROM public.campaigns c
  WHERE ((c.organization_id = campaign_csv_recipients.organization_id) AND (c.id = campaign_csv_recipients.campaign_id) AND (c.status = 'draft'::text))))))
with check (((organization_id IN ( SELECT public.get_authorized_orgs_by_roles(ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]) AS get_authorized_orgs_by_roles)) AND (EXISTS ( SELECT 1
   FROM public.campaigns c
  WHERE ((c.organization_id = campaign_csv_recipients.organization_id) AND (c.id = campaign_csv_recipients.campaign_id) AND (c.status = 'draft'::text))))));



  create policy "members can read their orgs campaign deliveries"
  on "public"."campaign_deliveries"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs_by_roles(ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]) AS get_authorized_orgs_by_roles)));



  create policy "members can create their orgs campaign drafts"
  on "public"."campaigns"
  as permissive
  for insert
  to authenticated, anon
with check (((organization_id IN ( SELECT public.get_authorized_orgs_by_roles(ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]) AS get_authorized_orgs_by_roles)) AND (status = 'draft'::text)));



  create policy "members can delete their orgs campaign drafts"
  on "public"."campaigns"
  as permissive
  for delete
  to authenticated, anon
using (((organization_id IN ( SELECT public.get_authorized_orgs_by_roles(ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]) AS get_authorized_orgs_by_roles)) AND (status = 'draft'::text)));



  create policy "members can read their orgs campaigns"
  on "public"."campaigns"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs_by_roles(ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]) AS get_authorized_orgs_by_roles)));



  create policy "members can update their orgs campaign drafts"
  on "public"."campaigns"
  as permissive
  for update
  to authenticated, anon
using (((organization_id IN ( SELECT public.get_authorized_orgs_by_roles(ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]) AS get_authorized_orgs_by_roles)) AND (status = 'draft'::text)))
with check (((organization_id IN ( SELECT public.get_authorized_orgs_by_roles(ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]) AS get_authorized_orgs_by_roles)) AND (status = 'draft'::text)));



  create policy "members can read their orgs chatbot deployments"
  on "public"."chatbot_flow_deployments"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs_by_roles(ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]) AS get_authorized_orgs_by_roles)));



  create policy "members can read their orgs chatbot flow runs"
  on "public"."chatbot_flow_runs"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs_by_roles(ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]) AS get_authorized_orgs_by_roles)));



  create policy "members can read their orgs chatbot flow versions"
  on "public"."chatbot_flow_versions"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs_by_roles(ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]) AS get_authorized_orgs_by_roles)));



  create policy "members can read their orgs chatbot flows"
  on "public"."chatbot_flows"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs_by_roles(ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]) AS get_authorized_orgs_by_roles)));



  create policy "members can read their orgs logs"
  on "public"."logs"
  as permissive
  for select
  to authenticated, anon
using ((organization_id IN ( SELECT public.get_authorized_orgs_by_roles(ARRAY['owner'::public.role, 'admin'::public.role, 'member'::public.role]) AS get_authorized_orgs_by_roles)));
