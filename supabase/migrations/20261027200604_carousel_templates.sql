drop trigger if exists "enforce_campaign_draft_rules" on "public"."campaigns";

drop trigger if exists "enforce_message_template_rules" on "public"."message_templates";

drop function if exists "public"."claim_campaign_deliveries"(p_limit integer);

drop function if exists "public"."list_campaigns_page"(p_organization_id uuid, p_page integer, p_page_size integer, p_search text, p_audience_type public.campaign_audience_type, p_readiness text);

drop function if exists "public"."list_message_templates_page"(p_organization_id uuid, p_page integer, p_page_size integer, p_search text, p_organization_address text, p_category text, p_status text);

alter table "public"."campaigns" add column "carousel_media" jsonb not null default '[]'::jsonb;

alter table "public"."message_templates" add column "media_assets" jsonb not null default '[]'::jsonb;

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.carousel_campaign_ready(p_template jsonb, p_media jsonb, p_mapping jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare carousel jsonb; card jsonb; part jsonb; idx integer := 0; variable text[]; key text;
begin
  select value into carousel from jsonb_array_elements(coalesce(p_template->'components', '[]')) where value->>'type' = 'CAROUSEL';
  if carousel is null then return true; end if;
  if p_template->>'category' is distinct from 'MARKETING'
    or jsonb_typeof(carousel->'cards') is distinct from 'array'
    or jsonb_typeof(p_media) is distinct from 'array' then return false; end if;
  if jsonb_array_length(carousel->'cards') not between 2 and 10
    or jsonb_array_length(p_media) <> jsonb_array_length(carousel->'cards') then return false; end if;
  for card in select value from jsonb_array_elements(carousel->'cards') loop
    if jsonb_array_length(card->'components') <> 3
      or not card->'components' @> '[{"type":"HEADER","format":"IMAGE"}]'
      or not exists (select 1 from jsonb_array_elements(card->'components') p where p->>'type' = 'BODY' and length(btrim(p->>'text')) between 1 and 160)
      or not exists (select 1 from jsonb_array_elements(card->'components') p where p->>'type' = 'BUTTONS'
        and jsonb_array_length(p->'buttons') = 1 and p->'buttons'->0->>'type' = 'URL'
        and length(btrim(p->'buttons'->0->>'text')) between 1 and 25
        and p->'buttons'->0->>'url' like 'https://%')
      or coalesce(p_media->idx->>'card_index', '') <> idx::text then return false; end if;
    for part in select value from jsonb_array_elements(card->'components') loop
      for variable in select regexp_matches(case when part->>'type' = 'BODY' then part->>'text' else part->'buttons'->0->>'url' end, '\{\{\s*([0-9]+)\s*\}\}', 'g') loop
        key := 'carousel.' || idx || case when part->>'type' = 'BODY' then '.body.' || variable[1] else '.button.0.1' end;
        if coalesce(p_mapping->>key, '') !~ '^(contact\.(name|address)|csv\..+)$' then return false; end if;
      end loop;
    end loop;
    idx := idx + 1;
  end loop;
  return true;
exception when others then return false;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.valid_carousel_assets(p_assets jsonb, p_organization_id uuid, p_allow_empty boolean DEFAULT false)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare asset jsonb; ids text[] := '{}';
begin
  if jsonb_typeof(p_assets) is distinct from 'array' or jsonb_array_length(p_assets) > 10 then return false; end if;
  for asset in select value from jsonb_array_elements(p_assets) loop
    if jsonb_typeof(asset) is distinct from 'object'
      or coalesce(asset->>'card_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or asset->>'card_id' = any(ids) then return false; end if;
    ids := array_append(ids, asset->>'card_id');
    if not asset ? 'storage_uri' and p_allow_empty and asset = jsonb_build_object('card_id', asset->>'card_id') then continue; end if;
    if coalesce(asset->>'storage_uri', '') !~ ('^internal://media/organizations/' || p_organization_id::text || '/attachments/[A-Za-z0-9_-]{43}$')
      or coalesce(asset->>'mime_type', '') not in ('image/jpeg', 'image/png')
      or jsonb_typeof(asset->'file_name') is distinct from 'string'
      or coalesce(asset->>'size', '') !~ '^[0-9]{1,8}$'
    then return false; end if;
    if (asset->>'size')::bigint not between 1 and 5242880 then return false; end if;
  end loop;
  return true;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.claim_campaign_deliveries(p_limit integer DEFAULT 25)
 RETURNS TABLE(delivery_id uuid, campaign_id uuid, organization_id uuid, organization_address text, contact_address text, contact_name text, variables jsonb, template jsonb, template_variable_mapping jsonb, header_media jsonb, carousel_media jsonb, attempts integer)
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
    and public.is_organization_active(c.organization_id)
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
      c.header_media,
      c.carousel_media
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
    c.carousel_media,
    d.attempts
  from claimed d
  cross join campaign_update c
  order by d.created_at, d.id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.enforce_campaign_draft_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if not public.valid_carousel_assets(new.carousel_media, new.organization_id) then
    raise exception 'Carousel image reference is invalid or belongs to another organization' using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' and old.status <> 'draft'
    and (new.template is distinct from old.template or new.carousel_media is distinct from old.carousel_media
      or new.template_variable_mapping is distinct from old.template_variable_mapping) then
    raise exception 'Queued campaign content is immutable' using errcode = '23514';
  end if;
  if not exists (
    select 1
    from public.organizations_addresses
    where organization_id = new.organization_id
      and address = new.organization_address
      and service = 'whatsapp'::public.service
  ) then
    raise exception 'Campaign account must be a WhatsApp address in the same organization'
      using errcode = '23514';
  end if;

  if new.created_by is not null and not exists (
    select 1
    from public.agents
    where id = new.created_by
      and organization_id = new.organization_id
  ) then
    raise exception 'Campaign creator must belong to the campaign organization'
      using errcode = '23514';
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.enforce_message_template_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if not public.valid_carousel_assets(new.media_assets, new.organization_id, new.status = 'draft') then
    raise exception 'Carousel image reference is invalid or belongs to another organization' using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' and old.status <> 'draft'
    and old.components @> '[{"type":"CAROUSEL"}]'::jsonb
    and (new.components is distinct from old.components or new.media_assets is distinct from old.media_assets
      or new.name is distinct from old.name or new.language is distinct from old.language
      or new.category is distinct from old.category or new.external_id is distinct from old.external_id
      or new.organization_address is distinct from old.organization_address)
    and current_user <> 'service_role' and current_user <> 'postgres'
  then
    raise exception 'Carousel templates are read-only. Duplicate as draft to make changes.' using errcode = '23514';
  end if;
  if not exists (
    select 1
    from public.organizations_addresses
    where organization_id = new.organization_id
      and address = new.organization_address
      and service = 'whatsapp'::public.service
  ) then
    raise exception 'Template account must be a WhatsApp address in the same organization'
      using errcode = '23514';
  end if;

  if new.created_by is not null and not exists (
    select 1
    from public.agents
    where id = new.created_by
      and organization_id = new.organization_id
  ) then
    raise exception 'Template creator must belong to the template organization'
      using errcode = '23514';
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_campaigns_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text, p_audience_type public.campaign_audience_type DEFAULT NULL::public.campaign_audience_type, p_readiness text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, id uuid, created_by uuid, name text, service public.service, organization_address text, template jsonb, template_variable_mapping jsonb, header_media jsonb, carousel_media jsonb, audience_type public.campaign_audience_type, status text, queued_count integer, processing_count integer, accepted_count integer, failed_count integer, created_at timestamp with time zone, updated_at timestamp with time zone, audience_count bigint, readiness text, total_count bigint)
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
          and public.carousel_campaign_ready(counted.template, counted.carousel_media, counted.template_variable_mapping)
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
    classified.carousel_media,
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

CREATE OR REPLACE FUNCTION public.list_message_templates_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text, p_organization_address text DEFAULT NULL::text, p_category text DEFAULT NULL::text, p_status text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, id uuid, organization_address text, created_by uuid, external_id text, name text, language text, category text, status text, components jsonb, media_assets jsonb, rejection_reason text, submitted_at timestamp with time zone, synced_at timestamp with time zone, created_at timestamp with time zone, updated_at timestamp with time zone, total_count bigint)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  normalized_page integer;
  normalized_page_size integer;
  normalized_search text;
  normalized_account text;
  normalized_category text;
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
  normalized_page_size := least(greatest(coalesce(p_page_size, 10), 1), 100);
  normalized_search := lower(btrim(coalesce(p_search, '')));
  normalized_account := nullif(btrim(coalesce(p_organization_address, '')), '');
  normalized_category := nullif(lower(btrim(coalesce(p_category, ''))), '');
  normalized_status := nullif(lower(btrim(coalesce(p_status, ''))), '');

  if normalized_category is not null
    and normalized_category not in ('utility', 'marketing', 'authentication')
  then
    raise exception using
      errcode = '22023',
      message = 'template category filter is invalid';
  end if;

  if normalized_status is not null
    and normalized_status not in (
      'draft',
      'pending',
      'approved',
      'in_appeal',
      'rejected',
      'pending_deletion',
      'deleted',
      'disabled',
      'paused',
      'limit_exceeded'
    )
  then
    raise exception using
      errcode = '22023',
      message = 'template status filter is invalid';
  end if;

  return query
  select
    template.organization_id,
    template.id,
    template.organization_address,
    template.created_by,
    template.external_id,
    template.name,
    template.language,
    template.category,
    template.status,
    template.components,
    template.media_assets,
    template.rejection_reason,
    template.submitted_at,
    template.synced_at,
    template.created_at,
    template.updated_at,
    count(*) over() as total_count
  from public.message_templates template
  where template.organization_id = p_organization_id
    and (
      normalized_status is not null
      or template.status <> 'deleted'
    )
    and (
      normalized_account is null
      or template.organization_address = normalized_account
    )
    and (
      normalized_category is null
      or template.category = normalized_category
    )
    and (
      normalized_status is null
      or template.status = normalized_status
    )
    and (
      normalized_search = ''
      or position(normalized_search in lower(template.name)) > 0
      or position(
        normalized_search in lower(template.organization_address)
      ) > 0
    )
  order by template.updated_at desc, template.id desc
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

  if not public.carousel_campaign_ready(campaign.template, campaign.carousel_media, campaign.template_variable_mapping) then
    raise exception 'Carousel cards, retained images or variable mappings are incomplete or unsupported' using errcode = '23514';
  end if;
  if exists (select 1 from jsonb_array_elements(campaign.carousel_media) a
    where not exists (select 1 from storage.objects o where o.bucket_id = 'media'
      and o.name = replace(a->>'storage_uri', 'internal://media/', ''))) then
    raise exception 'A retained carousel image is missing. Upload it again.' using errcode = '23514';
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

CREATE TRIGGER enforce_campaign_draft_rules BEFORE INSERT OR UPDATE OF organization_id, organization_address, created_by, template, carousel_media, template_variable_mapping ON public.campaigns FOR EACH ROW EXECUTE FUNCTION public.enforce_campaign_draft_rules();

CREATE TRIGGER enforce_message_template_rules BEFORE INSERT OR UPDATE OF organization_id, organization_address, created_by, components, media_assets, name, language, category, external_id ON public.message_templates FOR EACH ROW EXECUTE FUNCTION public.enforce_message_template_rules();

-- Restore schema-defined RPC grants after generated DROP/CREATE return-type changes.
-- In particular, never inherit public/tenant execution on the worker claim RPC.
revoke execute on function public.claim_campaign_deliveries(integer) from public, anon, authenticated;
grant execute on function public.claim_campaign_deliveries(integer) to service_role;
grant execute on function public.list_campaigns_page(uuid, integer, integer, text, public.campaign_audience_type, text)
to anon, authenticated, service_role;
grant execute on function public.list_message_templates_page(uuid, integer, integer, text, text, text, text)
to anon, authenticated, service_role;


