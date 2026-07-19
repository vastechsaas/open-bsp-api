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
