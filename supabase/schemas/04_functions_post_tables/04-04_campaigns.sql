create function public.enforce_campaign_draft_rules() returns trigger
language plpgsql
set search_path to ''
as $$
begin
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
$$;

create trigger enforce_campaign_draft_rules
before insert or update of organization_id, organization_address, created_by
on public.campaigns
for each row
execute function public.enforce_campaign_draft_rules();

create function public.enforce_campaign_csv_recipient() returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if not exists (
    select 1
    from public.campaigns
    where id = new.campaign_id
      and organization_id = new.organization_id
      and audience_type = 'csv_upload'::public.campaign_audience_type
  ) then
    raise exception 'CSV recipients require a CSV upload campaign in the same organization'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger enforce_campaign_csv_recipient
before insert or update of organization_id, campaign_id
on public.campaign_csv_recipients
for each row
execute function public.enforce_campaign_csv_recipient();

create function public.get_campaign_audience_count(
  p_organization_id uuid,
  p_campaign_id uuid
) returns bigint
language plpgsql
stable
security invoker
set search_path to ''
as $$
declare
  campaign public.campaigns;
  audience_count bigint;
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
$$;

create function public.get_campaign_audience_preview(
  p_organization_id uuid,
  p_campaign_id uuid,
  p_limit integer default 20
) returns table (
  contact_address text,
  name text,
  variables jsonb
)
language plpgsql
stable
security invoker
set search_path to ''
as $$
declare
  campaign public.campaigns;
  normalized_limit integer;
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
$$;

create function public.start_campaign(
  p_organization_id uuid,
  p_campaign_id uuid
) returns bigint
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  campaign public.campaigns;
  component jsonb;
  variable_match text[];
  mapping_key text;
  mapping_value text;
  csv_column text;
  queued_count bigint;
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

  get diagnostics queued_count = row_count;

  if queued_count = 0 then
    raise exception using
      errcode = '23514',
      message = 'campaign audience is empty';
  end if;

  update public.campaigns
  set status = 'queued'
  where id = p_campaign_id
    and organization_id = p_organization_id;

  return queued_count;
end;
$$;

revoke execute on function public.start_campaign(uuid, uuid) from public;
grant execute on function public.start_campaign(uuid, uuid)
to anon, authenticated, service_role;
