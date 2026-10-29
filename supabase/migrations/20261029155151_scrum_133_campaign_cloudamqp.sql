alter table "public"."campaign_deliveries" drop constraint "campaign_deliveries_status_check";

alter table "public"."campaigns" drop constraint "campaigns_delivery_counts_check";

alter table "public"."campaigns" drop constraint "campaigns_status_check";

drop function if exists "public"."list_campaigns_page"(p_organization_id uuid, p_page integer, p_page_size integer, p_search text, p_audience_type public.campaign_audience_type, p_readiness text);


  create table "public"."campaign_dispatch_jobs" (
    "id" uuid not null default gen_random_uuid(),
    "organization_id" uuid not null,
    "campaign_id" uuid not null,
    "delivery_id" uuid not null,
    "attempt_no" integer not null default 1,
    "phase" text not null default 'pending'::text,
    "due_at" timestamp with time zone not null default now(),
    "publish_after" timestamp with time zone not null default now(),
    "publication_token" uuid,
    "publication_expires_at" timestamp with time zone,
    "lease_token" uuid,
    "lease_expires_at" timestamp with time zone,
    "send_started_at" timestamp with time zone,
    "external_id" text,
    "error_code" text,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."campaign_dispatch_jobs" enable row level security;


  create table "public"."campaign_dispatch_settings" (
    "organization_id" uuid not null,
    "enabled" boolean not null default false
      );


alter table "public"."campaign_dispatch_settings" enable row level security;

alter table "public"."campaigns" add column "dispatch_transport" text not null default 'postgres'::text;

alter table "public"."campaigns" add column "needs_review_count" integer not null default 0;

CREATE UNIQUE INDEX campaign_deliveries_job_identity_key ON public.campaign_deliveries USING btree (organization_id, campaign_id, id);

CREATE UNIQUE INDEX campaign_dispatch_jobs_delivery_id_attempt_no_key ON public.campaign_dispatch_jobs USING btree (delivery_id, attempt_no);

CREATE UNIQUE INDEX campaign_dispatch_jobs_pkey ON public.campaign_dispatch_jobs USING btree (id);

CREATE INDEX campaign_dispatch_jobs_publication_idx ON public.campaign_dispatch_jobs USING btree (publish_after, id) WHERE (phase = 'pending'::text);

CREATE INDEX campaign_dispatch_jobs_recovery_idx ON public.campaign_dispatch_jobs USING btree (lease_expires_at, id) WHERE (phase = ANY (ARRAY['preparing'::text, 'submitting'::text]));

CREATE UNIQUE INDEX campaign_dispatch_settings_pkey ON public.campaign_dispatch_settings USING btree (organization_id);

alter table "public"."campaign_dispatch_jobs" add constraint "campaign_dispatch_jobs_pkey" PRIMARY KEY using index "campaign_dispatch_jobs_pkey";

alter table "public"."campaign_dispatch_settings" add constraint "campaign_dispatch_settings_pkey" PRIMARY KEY using index "campaign_dispatch_settings_pkey";

alter table "public"."campaign_deliveries" add constraint "campaign_deliveries_job_identity_key" UNIQUE using index "campaign_deliveries_job_identity_key";

alter table "public"."campaign_dispatch_jobs" add constraint "campaign_dispatch_jobs_attempt_no_check" CHECK (((attempt_no >= 1) AND (attempt_no <= 3))) not valid;

alter table "public"."campaign_dispatch_jobs" validate constraint "campaign_dispatch_jobs_attempt_no_check";

alter table "public"."campaign_dispatch_jobs" add constraint "campaign_dispatch_jobs_delivery_id_attempt_no_key" UNIQUE using index "campaign_dispatch_jobs_delivery_id_attempt_no_key";

alter table "public"."campaign_dispatch_jobs" add constraint "campaign_dispatch_jobs_organization_id_campaign_id_deliver_fkey" FOREIGN KEY (organization_id, campaign_id, delivery_id) REFERENCES public.campaign_deliveries(organization_id, campaign_id, id) ON DELETE CASCADE not valid;

alter table "public"."campaign_dispatch_jobs" validate constraint "campaign_dispatch_jobs_organization_id_campaign_id_deliver_fkey";

alter table "public"."campaign_dispatch_jobs" add constraint "campaign_dispatch_jobs_organization_id_campaign_id_fkey" FOREIGN KEY (organization_id, campaign_id) REFERENCES public.campaigns(organization_id, id) ON DELETE CASCADE not valid;

alter table "public"."campaign_dispatch_jobs" validate constraint "campaign_dispatch_jobs_organization_id_campaign_id_fkey";

alter table "public"."campaign_dispatch_jobs" add constraint "campaign_dispatch_jobs_phase_check" CHECK ((phase = ANY (ARRAY['pending'::text, 'preparing'::text, 'submitting'::text, 'accepted'::text, 'failed'::text, 'retry_scheduled'::text, 'needs_review'::text]))) not valid;

alter table "public"."campaign_dispatch_jobs" validate constraint "campaign_dispatch_jobs_phase_check";

alter table "public"."campaign_dispatch_settings" add constraint "campaign_dispatch_settings_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."campaign_dispatch_settings" validate constraint "campaign_dispatch_settings_organization_id_fkey";

alter table "public"."campaigns" add constraint "campaigns_dispatch_transport_check" CHECK ((dispatch_transport = ANY (ARRAY['postgres'::text, 'cloudamqp'::text]))) not valid;

alter table "public"."campaigns" validate constraint "campaigns_dispatch_transport_check";

alter table "public"."campaign_deliveries" add constraint "campaign_deliveries_status_check" CHECK ((status = ANY (ARRAY['queued'::text, 'processing'::text, 'accepted'::text, 'failed'::text, 'needs_review'::text]))) not valid;

alter table "public"."campaign_deliveries" validate constraint "campaign_deliveries_status_check";

alter table "public"."campaigns" add constraint "campaigns_delivery_counts_check" CHECK (((queued_count >= 0) AND (processing_count >= 0) AND (accepted_count >= 0) AND (failed_count >= 0) AND (needs_review_count >= 0))) not valid;

alter table "public"."campaigns" validate constraint "campaigns_delivery_counts_check";

alter table "public"."campaigns" add constraint "campaigns_status_check" CHECK ((status = ANY (ARRAY['draft'::text, 'queued'::text, 'running'::text, 'completed'::text, 'failed'::text, 'needs_review'::text]))) not valid;

alter table "public"."campaigns" validate constraint "campaigns_status_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.begin_campaign_dispatch_send(p_job_id uuid, p_token uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare j public.campaign_dispatch_jobs; c public.campaigns;
begin
  select campaign_id into j.campaign_id from public.campaign_dispatch_jobs where id = p_job_id;
  if not found then return false; end if;
  select * into strict c from public.campaigns where id = j.campaign_id for update;
  select * into strict j from public.campaign_dispatch_jobs where id = p_job_id for update;
  if j.phase <> 'preparing' or j.lease_token is distinct from p_token
    or j.lease_expires_at <= clock_timestamp() then return false; end if;
  if not public.is_organization_active(j.organization_id) or not exists (
    select 1 from public.organizations_addresses a where a.organization_id = j.organization_id
      and a.address = c.organization_address and a.service = 'whatsapp' and a.status = 'connected'
  ) then return false; end if;
  update public.campaign_dispatch_jobs set phase = 'submitting', send_started_at = clock_timestamp(),
    lease_expires_at = clock_timestamp() + interval '2 minutes', updated_at = clock_timestamp() where id = j.id;
  update public.campaign_deliveries set attempts = attempts + 1 where id = j.delivery_id;
  return true;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.claim_campaign_dispatch_job(p_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare j public.campaign_dispatch_jobs; c public.campaigns;
begin
  select campaign_id into j.campaign_id from public.campaign_dispatch_jobs where id = p_job_id;
  if not found then return null; end if;
  select * into strict c from public.campaigns where id = j.campaign_id for update;
  select * into strict j from public.campaign_dispatch_jobs where id = p_job_id for update;
  if c.dispatch_transport <> 'cloudamqp' then raise exception 'wrong campaign transport'; end if;
  if j.phase <> 'pending' then return jsonb_build_object('phase', j.phase); end if;
  if j.due_at > clock_timestamp() then
    update public.campaign_dispatch_jobs set publish_after = due_at where id = j.id;
    return jsonb_build_object('phase', 'deferred');
  end if;
  if not public.is_organization_active(j.organization_id) or not exists (
    select 1 from public.organizations_addresses a where a.organization_id = j.organization_id
      and a.address = c.organization_address and a.service = 'whatsapp' and a.status = 'connected'
  ) then
    update public.campaign_dispatch_jobs set phase = 'failed', error_code = 'account_unavailable', updated_at = clock_timestamp() where id = j.id;
    update public.campaign_deliveries set error = jsonb_build_object('code', 'account_unavailable', 'job_id', j.id) where id = j.delivery_id;
    perform public.set_campaign_dispatch_delivery(j.delivery_id, 'failed');
    return jsonb_build_object('phase', 'failed');
  end if;
  update public.campaign_dispatch_jobs set phase = 'preparing', lease_token = gen_random_uuid(),
    lease_expires_at = clock_timestamp() + interval '3 minutes', updated_at = clock_timestamp()
  where id = j.id returning * into j;
  perform public.set_campaign_dispatch_delivery(j.delivery_id, 'processing');
  return jsonb_build_object('phase', 'claimed', 'lease_token', j.lease_token);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.claim_campaign_dispatch_publications(p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;
begin
  with candidates as (
    select j.id from public.campaign_dispatch_jobs j
    join public.campaigns c on c.id = j.campaign_id and c.dispatch_transport = 'cloudamqp'
    where j.phase = 'pending' and j.publish_after <= clock_timestamp()
      and (j.publication_expires_at is null or j.publication_expires_at < clock_timestamp())
      and public.is_organization_active(j.organization_id)
    order by j.publish_after, j.id for update of j skip locked
    limit least(greatest(coalesce(p_limit, 25), 1), 100)
  ), claimed as (
    update public.campaign_dispatch_jobs j set publication_token = gen_random_uuid(),
      publication_expires_at = clock_timestamp() + interval '60 seconds', updated_at = clock_timestamp()
    from candidates c where c.id = j.id returning j.*
  ) select coalesce(jsonb_agg(jsonb_build_object(
      'version', 1, 'job_id', id, 'organization_id', organization_id,
      'campaign_id', campaign_id, 'delivery_id', delivery_id,
      'publication_token', publication_token,
      'delay_ms', greatest(0, ceil(extract(epoch from (due_at - clock_timestamp())) * 1000))::integer
    )), '[]'::jsonb) into result from claimed;
  return result;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.confirm_campaign_dispatch_publication(p_job_id uuid, p_token uuid)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with changed as (
    update public.campaign_dispatch_jobs set
      publish_after = greatest(due_at, clock_timestamp()) + interval '5 minutes',
      publication_token = null, publication_expires_at = null, updated_at = clock_timestamp()
    where id = p_job_id and publication_token = p_token and phase = 'pending'
    returning id
  ) select exists (select 1 from changed);
$function$
;

CREATE OR REPLACE FUNCTION public.finish_campaign_dispatch_job(p_job_id uuid, p_token uuid, p_outcome text, p_external_id text DEFAULT NULL::text, p_error_code text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare j public.campaign_dispatch_jobs; c public.campaigns; next_due timestamptz; result text;
begin
  if p_outcome not in ('accepted', 'failed', 'retry', 'needs_review')
    or (p_error_code is not null and p_error_code !~ '^[a-zA-Z0-9_.:-]{1,100}$') then
    raise exception 'invalid dispatch result';
  end if;
  select campaign_id into j.campaign_id from public.campaign_dispatch_jobs where id = p_job_id;
  if not found then raise exception 'job not found'; end if;
  select * into strict c from public.campaigns where id = j.campaign_id for update;
  select * into strict j from public.campaign_dispatch_jobs where id = p_job_id for update;
  if j.lease_token is distinct from p_token or p_token is null then raise exception 'stale dispatch lease'; end if;
  if j.phase in ('accepted', 'failed', 'retry_scheduled') then return j.phase; end if;
  -- A late known WAMID may resolve this exact attempt's uncertainty, never a new attempt.
  if j.phase = 'needs_review' and p_outcome <> 'accepted' then return j.phase; end if;
  if j.phase not in ('preparing', 'submitting', 'needs_review') then raise exception 'job not processing'; end if;
  if p_outcome = 'accepted' and (j.send_started_at is null or coalesce(p_external_id, '') = '') then
    raise exception 'accepted send requires message ID and submission';
  end if;
  result := p_outcome;
  if p_outcome = 'retry' then
    if j.attempt_no < 3 then
      next_due := clock_timestamp() + make_interval(secs => (30 * power(2, j.attempt_no - 1) * (1 + random() * 0.2)));
      insert into public.campaign_dispatch_jobs (organization_id, campaign_id, delivery_id, attempt_no, due_at)
      values (j.organization_id, j.campaign_id, j.delivery_id, j.attempt_no + 1, next_due)
      on conflict (delivery_id, attempt_no) do nothing;
      result := 'retry_scheduled';
    else result := 'failed'; end if;
  end if;
  update public.campaign_dispatch_jobs set phase = result, external_id = p_external_id,
    error_code = p_error_code, lease_expires_at = null, updated_at = clock_timestamp() where id = j.id;
  update public.campaign_deliveries set external_id = coalesce(p_external_id, external_id),
    error = case when result = 'accepted' then null else jsonb_build_object('code', coalesce(p_error_code, result), 'job_id', j.id) end
  where id = j.delivery_id;
  perform public.set_campaign_dispatch_delivery(j.delivery_id, case when result = 'retry_scheduled' then 'queued' else result end);
  return result;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.guard_campaign_dispatch_transport()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'UPDATE' and old.status <> 'draft'
    and new.dispatch_transport is distinct from old.dispatch_transport then
    raise exception 'campaign transport is immutable after start' using errcode = '23514';
  end if;
  if current_user in ('anon', 'authenticated') and (
    (tg_op = 'INSERT' and new.dispatch_transport <> 'postgres')
    or (tg_op = 'UPDATE' and new.dispatch_transport is distinct from old.dispatch_transport)
  ) then
    raise exception 'campaign transport is deployment managed' using errcode = '42501';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.recover_campaign_dispatch_jobs()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare candidate record; j public.campaign_dispatch_jobs; recovered integer := 0;
begin
  for candidate in select id, campaign_id from public.campaign_dispatch_jobs
    where phase in ('preparing', 'submitting') and lease_expires_at < clock_timestamp()
    order by lease_expires_at, id limit 100
  loop
    -- Same parent -> job lock order as dispatch, including recheck after waiting.
    perform 1 from public.campaigns where id = candidate.campaign_id for update;
    select * into j from public.campaign_dispatch_jobs where id = candidate.id for update;
    if j.phase not in ('preparing', 'submitting') or j.lease_expires_at >= clock_timestamp() then continue; end if;
    if j.phase = 'submitting' then
      perform public.finish_campaign_dispatch_job(j.id, j.lease_token, 'needs_review', null, 'submission_outcome_unknown');
    else
      update public.campaign_dispatch_jobs set phase = 'pending', lease_token = null, lease_expires_at = null,
        publication_token = null, publication_expires_at = null, publish_after = clock_timestamp(), updated_at = clock_timestamp()
      where id = j.id;
      perform public.set_campaign_dispatch_delivery(j.delivery_id, 'queued');
    end if;
    recovered := recovered + 1;
  end loop;
  return recovered;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_campaign_dispatch_delivery(p_delivery_id uuid, p_status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare d public.campaign_deliveries;
begin
  select * into strict d from public.campaign_deliveries where id = p_delivery_id for update;
  if d.status = p_status then return; end if;
  update public.campaign_deliveries set status = p_status where id = d.id;
  update public.campaigns set
    queued_count = queued_count - (d.status = 'queued')::integer + (p_status = 'queued')::integer,
    processing_count = processing_count - (d.status = 'processing')::integer + (p_status = 'processing')::integer,
    accepted_count = accepted_count - (d.status = 'accepted')::integer + (p_status = 'accepted')::integer,
    failed_count = failed_count - (d.status = 'failed')::integer + (p_status = 'failed')::integer,
    needs_review_count = needs_review_count - (d.status = 'needs_review')::integer + (p_status = 'needs_review')::integer
  where id = d.campaign_id;
  update public.campaigns set status = case
    when needs_review_count > 0 then 'needs_review'
    when queued_count + processing_count = 0 then 'completed' else 'running' end
  where id = d.campaign_id;
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
    and c.dispatch_transport = 'postgres'
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

CREATE OR REPLACE FUNCTION public.list_campaigns_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text, p_audience_type public.campaign_audience_type DEFAULT NULL::public.campaign_audience_type, p_readiness text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, id uuid, created_by uuid, name text, service public.service, organization_address text, template jsonb, template_variable_mapping jsonb, header_media jsonb, carousel_media jsonb, audience_type public.campaign_audience_type, status text, queued_count integer, processing_count integer, accepted_count integer, failed_count integer, needs_review_count integer, created_at timestamp with time zone, updated_at timestamp with time zone, audience_count bigint, readiness text, total_count bigint)
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
    classified.needs_review_count,
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
    failed_count = 0,
    dispatch_transport = case when exists (
      select 1 from public.campaign_dispatch_settings s
      where s.organization_id = p_organization_id and s.enabled
    ) then 'cloudamqp' else 'postgres' end
  where id = p_campaign_id
    and organization_id = p_organization_id;

  insert into public.campaign_dispatch_jobs (organization_id, campaign_id, delivery_id)
  select d.organization_id, d.campaign_id, d.id
  from public.campaign_deliveries d join public.campaigns c on c.id = d.campaign_id
  where d.campaign_id = p_campaign_id and c.dispatch_transport = 'cloudamqp'
  on conflict (delivery_id, attempt_no) do nothing;

  return snapshot_count;
end;
$function$
;

grant delete on table "public"."campaign_dispatch_jobs" to "service_role";

grant insert on table "public"."campaign_dispatch_jobs" to "service_role";

grant references on table "public"."campaign_dispatch_jobs" to "service_role";

grant select on table "public"."campaign_dispatch_jobs" to "service_role";

grant trigger on table "public"."campaign_dispatch_jobs" to "service_role";

grant truncate on table "public"."campaign_dispatch_jobs" to "service_role";

grant update on table "public"."campaign_dispatch_jobs" to "service_role";

grant delete on table "public"."campaign_dispatch_settings" to "service_role";

grant insert on table "public"."campaign_dispatch_settings" to "service_role";

grant references on table "public"."campaign_dispatch_settings" to "service_role";

grant select on table "public"."campaign_dispatch_settings" to "service_role";

grant trigger on table "public"."campaign_dispatch_settings" to "service_role";

grant truncate on table "public"."campaign_dispatch_settings" to "service_role";

grant update on table "public"."campaign_dispatch_settings" to "service_role";

CREATE TRIGGER guard_campaign_dispatch_transport BEFORE INSERT OR UPDATE ON public.campaigns FOR EACH ROW EXECUTE FUNCTION public.guard_campaign_dispatch_transport();

-- Explicit worker ACLs omitted by the diff engine.
revoke all on function public.set_campaign_dispatch_delivery(uuid, text) from public, anon, authenticated;
grant execute on function public.set_campaign_dispatch_delivery(uuid, text) to service_role;
revoke all on function public.claim_campaign_dispatch_publications(integer) from public, anon, authenticated;
grant execute on function public.claim_campaign_dispatch_publications(integer) to service_role;
revoke all on function public.confirm_campaign_dispatch_publication(uuid, uuid) from public, anon, authenticated;
grant execute on function public.confirm_campaign_dispatch_publication(uuid, uuid) to service_role;
revoke all on function public.claim_campaign_dispatch_job(uuid) from public, anon, authenticated;
grant execute on function public.claim_campaign_dispatch_job(uuid) to service_role;
revoke all on function public.begin_campaign_dispatch_send(uuid, uuid) from public, anon, authenticated;
grant execute on function public.begin_campaign_dispatch_send(uuid, uuid) to service_role;
revoke all on function public.finish_campaign_dispatch_job(uuid, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.finish_campaign_dispatch_job(uuid, uuid, text, text, text) to service_role;
revoke all on function public.recover_campaign_dispatch_jobs() from public, anon, authenticated;
grant execute on function public.recover_campaign_dispatch_jobs() to service_role;


