create function public.list_campaigns_page(
  p_organization_id uuid,
  p_page integer default 1,
  p_page_size integer default 10,
  p_search text default null,
  p_audience_type public.campaign_audience_type default null,
  p_readiness text default null
) returns table (
  organization_id uuid,
  id uuid,
  created_by uuid,
  name text,
  service public.service,
  organization_address text,
  template jsonb,
  template_variable_mapping jsonb,
  audience_type public.campaign_audience_type,
  status text,
  queued_count integer,
  processing_count integer,
  accepted_count integer,
  failed_count integer,
  created_at timestamp with time zone,
  updated_at timestamp with time zone,
  audience_count bigint,
  readiness text,
  total_count bigint
)
language plpgsql
stable
security invoker
set search_path to ''
as $$
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
$$;
