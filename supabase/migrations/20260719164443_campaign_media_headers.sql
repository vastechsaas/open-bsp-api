drop function if exists "public"."claim_campaign_deliveries"(p_limit integer);

drop function if exists "public"."list_campaigns_page"(p_organization_id uuid, p_page integer, p_page_size integer, p_search text, p_audience_type public.campaign_audience_type, p_readiness text);

alter table "public"."campaigns" add column "header_media" jsonb;

alter table "public"."campaigns" add constraint "campaigns_header_media_check" CHECK (((header_media IS NULL) OR ((jsonb_typeof(header_media) = 'object'::text) AND ((header_media ->> 'format'::text) = ANY (ARRAY['IMAGE'::text, 'VIDEO'::text, 'DOCUMENT'::text])) AND (length(COALESCE((header_media ->> 'media_id'::text), ''::text)) > 0) AND (length(COALESCE((header_media ->> 'file_name'::text), ''::text)) > 0) AND (length(COALESCE((header_media ->> 'mime_type'::text), ''::text)) > 0) AND (((header_media ->> 'size'::text))::bigint > 0)))) not valid;

alter table "public"."campaigns" validate constraint "campaigns_header_media_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.claim_campaign_deliveries(p_limit integer DEFAULT 25)
 RETURNS TABLE(delivery_id uuid, campaign_id uuid, organization_id uuid, organization_address text, contact_address text, contact_name text, variables jsonb, template jsonb, template_variable_mapping jsonb, header_media jsonb, attempts integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  target_campaign_id uuid;
  normalized_limit integer;
begin
  normalized_limit := least(greatest(coalesce(p_limit, 25), 1), 25);

  select c.id into target_campaign_id
  from public.campaigns c
  where c.status in ('queued', 'running')
    and c.queued_count > 0
    and exists (
      select 1
      from public.campaign_deliveries d
      where d.campaign_id = c.id
        and d.status = 'queued'
    )
  order by c.created_at, c.id
  for update skip locked
  limit 1;

  if not found then
    return;
  end if;

  return query
  with candidates as (
    select d.id
    from public.campaign_deliveries d
    where d.campaign_id = target_campaign_id
      and d.status = 'queued'
    order by d.created_at, d.id
    for update skip locked
    limit normalized_limit
  ),
  claimed as (
    update public.campaign_deliveries d
    set
      status = 'processing',
      attempts = d.attempts + 1,
      error = null
    from candidates
    where d.id = candidates.id
    returning d.*
  ),
  campaign_update as (
    update public.campaigns c
    set
      status = 'running',
      queued_count = c.queued_count - (select count(*)::integer from claimed),
      processing_count = c.processing_count + (
        select count(*)::integer from claimed
      )
    where c.id = target_campaign_id
    returning
      c.id,
      c.organization_id,
      c.organization_address,
      c.template,
      c.template_variable_mapping,
      c.header_media
  )
  select
    d.id,
    d.campaign_id,
    c.organization_id,
    c.organization_address,
    d.contact_address,
    d.name,
    d.variables,
    c.template,
    c.template_variable_mapping,
    c.header_media,
    d.attempts
  from claimed d
  cross join campaign_update c
  order by d.created_at, d.id;
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
    from public.get_authorized_orgs('member') as authorized_orgs(id)
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

CREATE OR REPLACE FUNCTION public.start_campaign(p_organization_id uuid, p_campaign_id uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  campaign public.campaigns;
  component jsonb;
  variable_match text[];
  mapping_key text;
  mapping_value text;
  csv_column text;
  snapshot_count bigint;
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

revoke execute on function public.claim_campaign_deliveries(integer) from public;
grant execute on function public.claim_campaign_deliveries(integer) to service_role;

revoke execute on function public.list_campaigns_page(
  uuid, integer, integer, text, public.campaign_audience_type, text
) from public;
grant execute on function public.list_campaigns_page(
  uuid, integer, integer, text, public.campaign_audience_type, text
) to anon, authenticated, service_role;


