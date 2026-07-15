alter table "public"."campaigns" add column "accepted_count" integer not null default 0;

alter table "public"."campaigns" add column "failed_count" integer not null default 0;

alter table "public"."campaigns" add column "processing_count" integer not null default 0;

alter table "public"."campaigns" add column "queued_count" integer not null default 0;

with delivery_counts as (
  select
    campaign_id,
    count(*) filter (where status = 'queued')::integer as queued_count,
    count(*) filter (where status = 'processing')::integer as processing_count,
    count(*) filter (where status = 'accepted')::integer as accepted_count,
    count(*) filter (where status = 'failed')::integer as failed_count
  from public.campaign_deliveries
  group by campaign_id
)
update public.campaigns c
set
  queued_count = dc.queued_count,
  processing_count = dc.processing_count,
  accepted_count = dc.accepted_count,
  failed_count = dc.failed_count
from delivery_counts dc
where c.id = dc.campaign_id;

alter table "public"."campaigns" add constraint "campaigns_delivery_counts_check" CHECK (((queued_count >= 0) AND (processing_count >= 0) AND (accepted_count >= 0) AND (failed_count >= 0))) not valid;

alter table "public"."campaigns" validate constraint "campaigns_delivery_counts_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.claim_campaign_deliveries(p_limit integer DEFAULT 25)
 RETURNS TABLE(delivery_id uuid, campaign_id uuid, organization_id uuid, organization_address text, contact_address text, contact_name text, variables jsonb, template jsonb, template_variable_mapping jsonb, attempts integer)
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
      c.template_variable_mapping
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
    d.attempts
  from claimed d
  cross join campaign_update c
  order by d.created_at, d.id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_campaign_delivery_result(p_delivery_id uuid, p_external_id text DEFAULT NULL::text, p_error jsonb DEFAULT NULL::jsonb, p_retryable boolean DEFAULT false)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  delivery public.campaign_deliveries;
  target_campaign public.campaigns;
  target_campaign_id uuid;
  final_status text;
begin
  select d.campaign_id into target_campaign_id
  from public.campaign_deliveries d
  where d.id = p_delivery_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'campaign delivery not found';
  end if;

  select * into target_campaign
  from public.campaigns c
  where c.id = target_campaign_id
  for update;

  select * into delivery
  from public.campaign_deliveries d
  where d.id = p_delivery_id
  for update;

  if delivery.status <> 'processing' then
    raise exception using
      errcode = '23514',
      message = 'campaign delivery is not processing';
  end if;

  if p_external_id is not null then
    final_status := 'accepted';

    update public.campaign_deliveries
    set
      status = final_status,
      external_id = p_external_id,
      error = null
    where id = p_delivery_id;

    update public.campaigns
    set
      processing_count = processing_count - 1,
      accepted_count = accepted_count + 1
    where id = target_campaign_id
    returning * into target_campaign;
  elsif p_retryable and delivery.attempts < 3 then
    final_status := 'queued';

    update public.campaign_deliveries
    set
      status = final_status,
      error = p_error
    where id = p_delivery_id;

    update public.campaigns
    set
      processing_count = processing_count - 1,
      queued_count = queued_count + 1
    where id = target_campaign_id
    returning * into target_campaign;
  else
    final_status := 'failed';

    update public.campaign_deliveries
    set
      status = final_status,
      error = p_error
    where id = p_delivery_id;

    update public.campaigns
    set
      processing_count = processing_count - 1,
      failed_count = failed_count + 1
    where id = target_campaign_id
    returning * into target_campaign;
  end if;

  if target_campaign.queued_count = 0
    and target_campaign.processing_count = 0
  then
    update public.campaigns
    set status = 'completed'
    where id = target_campaign_id;
  end if;

  return final_status;
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
grant execute on function public.claim_campaign_deliveries(integer)
to service_role;

revoke execute on function public.record_campaign_delivery_result(
  uuid,
  text,
  jsonb,
  boolean
) from public;
grant execute on function public.record_campaign_delivery_result(
  uuid,
  text,
  jsonb,
  boolean
) to service_role;

-- Process one small campaign batch per minute. Recipient claiming remains
-- atomic when cron invocations overlap.
select
  cron.schedule(
    'process-campaign-delivery-batches',
    '* * * * *',
    $$
    select
      net.http_post(
        url:=(select decrypted_secret from vault.decrypted_secrets where name = 'edge_functions_url') || '/campaign-worker',
        headers:=jsonb_build_object(
          'content-type', 'application/json',
          'authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'edge_functions_token')
        ),
        body:='{}'::jsonb,
        timeout_milliseconds:=60000
      ) as request_id
    $$
  );
