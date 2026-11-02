alter table "public"."campaign_dispatch_jobs" drop constraint "campaign_dispatch_jobs_waiting_reason_check";

drop function if exists "public"."list_campaigns_page"(p_organization_id uuid, p_page integer, p_page_size integer, p_search text, p_audience_type public.campaign_audience_type, p_readiness text);

drop function if exists "public"."list_campaign_activity_page"(p_organization_id uuid, p_campaign_id uuid, p_page integer, p_page_size integer);

alter table "public"."campaign_activity" add column "actor_name" text;

alter table "public"."campaign_activity" add column "actor_user_id" uuid;

alter table "public"."campaign_activity" add column "control_revision" bigint;

alter table "public"."campaign_activity" add column "request_id" uuid;

alter table "public"."campaigns" add column "control_revision" bigint not null default 0;

alter table "public"."campaigns" add column "paused_at" timestamp with time zone;

alter table "public"."campaigns" add column "paused_by_name" text;

alter table "public"."campaigns" add constraint "campaigns_control_revision_check" CHECK ((control_revision >= 0)) not valid;

alter table "public"."campaigns" validate constraint "campaigns_control_revision_check";

alter table "public"."campaign_dispatch_jobs" add constraint "campaign_dispatch_jobs_waiting_reason_check" CHECK ((waiting_reason = ANY (ARRAY['scheduled'::text, 'sending_window'::text, 'daily_allowance'::text, 'number_rate'::text, 'recipient_frequency'::text, 'policy_unavailable'::text, 'manual_pause'::text]))) not valid;

alter table "public"."campaign_dispatch_jobs" validate constraint "campaign_dispatch_jobs_waiting_reason_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.list_campaigns_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text, p_audience_type public.campaign_audience_type DEFAULT NULL::public.campaign_audience_type, p_readiness text DEFAULT NULL::text, p_status text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, id uuid, created_by uuid, name text, service public.service, organization_address text, template jsonb, template_variable_mapping jsonb, header_media jsonb, carousel_media jsonb, audience_type public.campaign_audience_type, status text, queued_count integer, processing_count integer, accepted_count integer, failed_count integer, needs_review_count integer, expired_count integer, cancelled_count integer, scheduled_start_at timestamp with time zone, expires_at timestamp with time zone, sending_state jsonb, created_at timestamp with time zone, updated_at timestamp with time zone, audience_count bigint, readiness text, total_count bigint)
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
  if p_status is not null and p_status <> 'paused' then
    raise exception 'Campaign status filter is invalid' using errcode='22023'; end if;

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
      and (p_status is null or (c.dispatch_transport='cloudamqp' and c.paused_at is not null
        and c.cancelled_at is null and c.status in ('queued','running','needs_review')
        and (c.expires_at is null or c.expires_at>clock_timestamp()) and c.queued_count+c.processing_count>0))
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
    classified.expired_count,
    classified.cancelled_count,
    classified.scheduled_start_at,
    classified.expires_at,
    public.get_campaign_sending_state(classified.organization_id,classified.id),
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

CREATE OR REPLACE FUNCTION public.pause_campaign(p_organization_id uuid, p_campaign_id uuid, p_expected_revision bigint, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select public.set_campaign_paused(p_organization_id,p_campaign_id,true,p_expected_revision,p_request_id);
$function$
;

CREATE OR REPLACE FUNCTION public.resume_campaign(p_organization_id uuid, p_campaign_id uuid, p_expected_revision bigint, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select public.set_campaign_paused(p_organization_id,p_campaign_id,false,p_expected_revision,p_request_id);
$function$
;

CREATE OR REPLACE FUNCTION public.set_campaign_paused(p_organization_id uuid, p_campaign_id uuid, p_paused boolean, p_expected_revision bigint, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c public.campaigns; previous public.campaign_activity; actor_name_value text; action text;
begin
  if public.get_request_organization_role(p_organization_id) is null or
    public.get_request_organization_role(p_organization_id) not in ('owner','admin','member') then
    raise exception 'Campaign management access required' using errcode='42501'; end if;
  if p_request_id is null or p_expected_revision is null or p_paused is null then
    raise exception 'Request ID, revision and action are required' using errcode='22023'; end if;
  perform public.lock_campaign_sending_policy(p_organization_id);
  select * into c from public.campaigns where organization_id=p_organization_id and id=p_campaign_id for update;
  if not found then raise exception 'Campaign not found' using errcode='P0002'; end if;
  action:=case when p_paused then 'campaign_paused' else 'campaign_resumed' end;
  select * into previous from public.campaign_activity
    where deduplication_key='campaign-control:'||c.id::text||':'||p_request_id::text;
  if found then
    if previous.event_type<>action or previous.actor_user_id is distinct from auth.uid() then
      raise exception 'Request ID was already used for another action' using errcode='22023'; end if;
    -- Reconcile current state, never reapply an old request after a later action.
    return jsonb_build_object('control_revision',c.control_revision,'paused_at',c.paused_at,
      'paused_by_name',c.paused_by_name,'request_revision',previous.control_revision);
  end if;
  if c.control_revision<>p_expected_revision then
    raise exception 'Campaign controls changed. Refresh before trying again.' using errcode='40001'; end if;
  if c.dispatch_transport<>'cloudamqp' or c.status not in ('queued','running','needs_review') or
    c.cancelled_at is not null or c.expires_at<=clock_timestamp() or c.queued_count+c.processing_count=0 then
    raise exception 'Only unfinished CloudAMQP campaigns can be paused or resumed' using errcode='23514'; end if;
  if (c.paused_at is not null)=p_paused then
    raise exception 'Campaign pause state already changed. Refresh before trying again.' using errcode='40001'; end if;
  select coalesce(nullif(btrim(a.name),''),'User') into actor_name_value from public.agents a
    where a.organization_id=p_organization_id and a.user_id=auth.uid() and not a.ai limit 1;
  actor_name_value:=coalesce(actor_name_value,'API key');
  update public.campaigns set paused_at=case when p_paused then clock_timestamp() else null end,
    paused_by_name=case when p_paused then actor_name_value else null end,control_revision=control_revision+1
    where id=c.id returning * into c;
  if not p_paused then
    -- Wake only provably unsent work; keep retry/schedule due_at intact.
    update public.campaign_dispatch_jobs set publication_token=null,publication_expires_at=null,
      publish_after=greatest(due_at,clock_timestamp()),
      waiting_reason=case when waiting_reason='manual_pause' then null else waiting_reason end,
      updated_at=clock_timestamp() where campaign_id=c.id and phase='pending';
  end if;
  insert into public.campaign_activity(organization_id,campaign_id,event_type,actor_user_id,actor_name,
    request_id,control_revision,deduplication_key)
    values(c.organization_id,c.id,action,auth.uid(),actor_name_value,p_request_id,c.control_revision,
      'campaign-control:'||c.id::text||':'||p_request_id::text);
  return jsonb_build_object('control_revision',c.control_revision,'paused_at',c.paused_at,
    'paused_by_name',c.paused_by_name,'request_revision',c.control_revision);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.campaign_dispatch_eligibility(p_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare j public.campaign_dispatch_jobs; c public.campaigns; p public.campaign_sending_policies;
  current_at timestamptz := clock_timestamp(); candidate timestamptz; boundary timestamptz;
  earliest timestamptz; latest timestamptz; used bigint; effective_rate integer;
  reason text; recipient text;
begin
  select * into strict j from public.campaign_dispatch_jobs where id=p_job_id;
  select * into strict c from public.campaigns where id=j.campaign_id;
  if c.cancelled_at is not null then return jsonb_build_object('terminal','cancelled'); end if;
  if c.expires_at <= current_at then return jsonb_build_object('terminal','expired'); end if;
  if c.paused_at is not null then return jsonb_build_object('reason','manual_pause'); end if;
  candidate := greatest(current_at,coalesce(c.scheduled_start_at,current_at));
  if candidate > current_at then reason := 'scheduled'; end if;
  select * into p from public.campaign_sending_policies where organization_id=j.organization_id;
  if c.policy_required and (not found or not p.enabled) then
    return jsonb_build_object('reason','policy_unavailable','next_at',current_at+interval '1 minute'); end if;
  if p.enabled then
    boundary := (((current_at at time zone p.budget_timezone)::date)::timestamp) at time zone p.budget_timezone;
    select count(*) into used from public.campaign_send_ledger
      where organization_id=j.organization_id and state <> 'released' and submitted_at >= boundary;
    if used >= p.daily_limit then
      candidate := greatest(candidate,(((current_at at time zone p.budget_timezone)::date+1)::timestamp) at time zone p.budget_timezone);
      reason := 'daily_allowance';
    end if;
    select public.campaign_recipient_key(contact_address) into recipient from public.campaign_deliveries where id=j.delivery_id;
    select count(*),min(greatest(submitted_at,coalesce(accepted_at,submitted_at))) into used,earliest
    from public.campaign_send_ledger where organization_id=j.organization_id and recipient_key=recipient and state <> 'released'
      and greatest(submitted_at,coalesce(accepted_at,submitted_at)) > current_at-interval '24 hours';
    if used >= p.recipient_cap then
      -- If the cap was lowered, enough oldest reservations must age out.
      select greatest(submitted_at,coalesce(accepted_at,submitted_at))+interval '24 hours' into earliest
      from public.campaign_send_ledger where organization_id=j.organization_id and recipient_key=recipient and state <> 'released'
        and greatest(submitted_at,coalesce(accepted_at,submitted_at)) > current_at-interval '24 hours'
      order by greatest(submitted_at,coalesce(accepted_at,submitted_at)),id offset (used-p.recipient_cap) limit 1;
      if earliest > candidate then candidate:=earliest; reason:='recipient_frequency'; end if;
    end if;
  end if;
  effective_rate := least(case when p.enabled then p.max_sends_per_minute else null end,c.max_sends_per_minute);
  if effective_rate is not null then
    select max(submitted_at),count(*) into latest,used from public.campaign_send_ledger
      where organization_id=j.organization_id and organization_address=c.organization_address and submitted_at>current_at-interval '60 seconds';
    earliest := latest + interval '1 second' * (60.0/effective_rate);
    if used >= effective_rate then
      select submitted_at+interval '60 seconds' into boundary from public.campaign_send_ledger
      where organization_id=j.organization_id and organization_address=c.organization_address and submitted_at>current_at-interval '60 seconds'
      order by submitted_at,id offset (used-effective_rate) limit 1;
      earliest := greatest(earliest,boundary);
    end if;
    if earliest > candidate then candidate:=earliest; reason:='number_rate'; end if;
  end if;
  boundary := public.campaign_window_next_at(candidate,c.schedule_timezone,c.send_window_start,c.send_window_end);
  if boundary > candidate then candidate:=boundary; if reason is null then reason:='sending_window'; end if; end if;
  if c.expires_at is not null and candidate >= c.expires_at then
    -- Keep waiting visible until expiry; do not report expiration before its time.
    candidate:=c.expires_at;
  end if;
  if candidate > current_at then return jsonb_build_object('reason',coalesce(reason,'scheduled'),'next_at',candidate); end if;
  return '{}'::jsonb;
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
  with organizations as (
    select j.organization_id,min(j.publish_after) as oldest from public.campaign_dispatch_jobs j
    join public.campaigns active on active.id=j.campaign_id and (active.paused_at is null or active.cancelled_at is not null or active.expires_at<=clock_timestamp())
    where j.phase='pending' and j.due_at<=clock_timestamp() and j.publish_after<=clock_timestamp()
      and (j.publication_expires_at is null or j.publication_expires_at<clock_timestamp())
    group by j.organization_id order by min(j.publish_after),j.organization_id limit 100
  ), pool as (
    select batch.id,row_number() over(partition by o.organization_id order by batch.campaign_ordinal,batch.publish_after,batch.id) as ordinal
    from organizations o cross join lateral (
      select j.campaign_id,min(j.publish_after) as oldest from public.campaign_dispatch_jobs j
      join public.campaigns active on active.id=j.campaign_id and (active.paused_at is null or active.cancelled_at is not null or active.expires_at<=clock_timestamp())
      where j.organization_id=o.organization_id and j.phase='pending' and j.due_at<=clock_timestamp()
        and j.publish_after<=clock_timestamp() and (j.publication_expires_at is null or j.publication_expires_at<clock_timestamp())
      group by j.campaign_id order by min(j.publish_after),j.campaign_id limit 25
    ) campaigns cross join lateral (
      select ready.id,ready.publish_after,row_number() over(order by ready.publish_after,ready.id) as campaign_ordinal
      from (select j.id,j.publish_after from public.campaign_dispatch_jobs j where j.campaign_id=campaigns.campaign_id
        and j.phase='pending' and j.due_at<=clock_timestamp() and j.publish_after<=clock_timestamp()
        and (j.publication_expires_at is null or j.publication_expires_at<clock_timestamp())
        order by j.publish_after,j.id limit 4) ready
    ) batch
  ), candidates as (
    select j.id from pool p join public.campaign_dispatch_jobs j on j.id=p.id
    join public.campaigns c on c.id = j.campaign_id and c.dispatch_transport = 'cloudamqp'
    where j.phase = 'pending' and j.publish_after <= clock_timestamp()
      and (c.paused_at is null or c.cancelled_at is not null or c.expires_at<=clock_timestamp())
      and j.due_at <= clock_timestamp()
      and (j.publication_expires_at is null or j.publication_expires_at < clock_timestamp())
      and public.is_organization_active(j.organization_id)
    order by p.ordinal,j.publish_after, j.id for update of j skip locked
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

CREATE OR REPLACE FUNCTION public.defer_campaign_dispatch_job(p_job_id uuid, p_eligibility jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare j public.campaign_dispatch_jobs; terminal text := p_eligibility->>'terminal';
begin
  select * into strict j from public.campaign_dispatch_jobs where id=p_job_id;
  if terminal is not null then
    update public.campaign_dispatch_jobs set phase=terminal,waiting_reason=null,lease_expires_at=null,
      publication_token=null,publication_expires_at=null,updated_at=clock_timestamp() where id=j.id;
    perform public.set_campaign_dispatch_delivery(j.delivery_id,terminal);
    return jsonb_build_object('phase',terminal);
  end if;
  update public.campaign_dispatch_jobs set phase='pending',waiting_reason=p_eligibility->>'reason',
    due_at=coalesce((p_eligibility->>'next_at')::timestamptz,due_at),publish_after=coalesce((p_eligibility->>'next_at')::timestamptz,publish_after),
    lease_token=null,lease_expires_at=null,publication_token=null,publication_expires_at=null,updated_at=clock_timestamp() where id=j.id;
  perform public.set_campaign_dispatch_delivery(j.delivery_id,'queued');
  return jsonb_build_object('phase','deferred','reason',p_eligibility->>'reason','next_at',p_eligibility->>'next_at');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_campaign_sending_state(p_organization_id uuid, p_campaign_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;
begin
  if public.get_request_organization_role(p_organization_id) is null or public.get_request_organization_role(p_organization_id) not in ('owner','admin','member') then
    raise exception 'Campaign access required' using errcode='42501'; end if;
  if not exists(select 1 from public.campaigns where id=p_campaign_id and organization_id=p_organization_id) then
    raise exception 'Campaign not found' using errcode='P0002'; end if;
  select jsonb_build_object('waiting_count',count(*),'next_at',min(due_at),
    'reason',(array_agg(waiting_reason order by due_at,id))[1]) into result from public.campaign_dispatch_jobs
    where organization_id=p_organization_id and campaign_id=p_campaign_id and phase='pending' and waiting_reason is not null;
  return result || (select jsonb_build_object('paused_at',c.paused_at,'paused_by_name',c.paused_by_name,'control_revision',c.control_revision)
    from public.campaigns c where c.id=p_campaign_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.guard_campaign_dispatch_transport()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if current_user in ('anon','authenticated') and (
    (tg_op='INSERT' and (new.paused_at is not null or new.paused_by_name is not null or new.control_revision<>0)) or
    (tg_op='UPDATE' and (new.paused_at,new.paused_by_name,new.control_revision) is distinct from (old.paused_at,old.paused_by_name,old.control_revision))
  ) then raise exception 'Campaign controls are backend managed' using errcode='42501'; end if;
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
  if current_user in ('anon','authenticated') and (
    (tg_op='INSERT' and (new.policy_required or new.cancelled_at is not null)) or
    (tg_op='UPDATE' and (new.policy_required is distinct from old.policy_required or new.cancelled_at is distinct from old.cancelled_at))
  ) then raise exception 'Campaign lifecycle is backend managed' using errcode='42501'; end if;
  if current_user in ('anon','authenticated') and (
    new.queued_count<>0 or new.processing_count<>0 or new.accepted_count<>0 or new.failed_count<>0
    or new.needs_review_count<>0 or new.expired_count<>0 or new.cancelled_count<>0
  ) then raise exception 'Campaign counters are backend managed' using errcode='42501'; end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_campaign_activity_page(p_organization_id uuid, p_campaign_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10)
 RETURNS TABLE(id bigint, delivery_id uuid, job_id uuid, attempt_no integer, event_type text, reason_code text, provider_at timestamp with time zone, recorded_at timestamp with time zone, actor_name text, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform public.get_campaign_receipt_summary(p_organization_id,p_campaign_id);
  return query select a.id,a.delivery_id,a.job_id,a.attempt_no,a.event_type,a.reason_code,a.provider_at,a.recorded_at,a.actor_name,count(*) over()
    from public.campaign_activity a where a.organization_id=p_organization_id and a.campaign_id=p_campaign_id
    order by a.recorded_at desc,a.id desc limit least(greatest(coalesce(p_page_size,10),1),50)
    offset (greatest(coalesce(p_page,1),1)::bigint-1)*least(greatest(coalesce(p_page_size,10),1),50);
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
  -- Expiry/cancellation does not depend on a broker delivery or original due date.
  for candidate in select jobs.id,jobs.campaign_id,jobs.organization_id from public.campaign_dispatch_jobs jobs
    join public.campaigns c on c.id=jobs.campaign_id
    where jobs.phase in ('pending','preparing') and (c.cancelled_at is not null or c.expires_at<=clock_timestamp())
    order by jobs.id limit 100
  loop
    perform public.lock_campaign_sending_policy(candidate.organization_id);
    perform 1 from public.campaigns where id=candidate.campaign_id for update;
    select * into j from public.campaign_dispatch_jobs where id=candidate.id for update;
    if j.phase not in ('pending','preparing') then continue; end if;
    perform public.defer_campaign_dispatch_job(j.id,public.campaign_dispatch_eligibility(j.id));
    recovered:=recovered+1;
  end loop;
  for candidate in select id, campaign_id, organization_id from public.campaign_dispatch_jobs
    where phase in ('preparing', 'submitting') and lease_expires_at < clock_timestamp()
    order by lease_expires_at, id limit 100
  loop
    -- Same parent -> job lock order as dispatch, including recheck after waiting.
    perform public.lock_campaign_sending_policy(candidate.organization_id);
    perform 1 from public.campaigns where id = candidate.campaign_id for update;
    select * into j from public.campaign_dispatch_jobs where id = candidate.id for update;
    if j.phase not in ('preparing', 'submitting') or j.lease_expires_at >= clock_timestamp() then continue; end if;
    if j.phase = 'submitting' then
      perform public.finish_campaign_dispatch_job(j.id, j.lease_token, 'needs_review', null, 'submission_outcome_unknown');
    else
      update public.campaign_dispatch_jobs set phase = 'pending', lease_token = null, lease_expires_at = null,
        publication_token = null, publication_expires_at = null,
        waiting_reason=case when exists(select 1 from public.campaigns where id=j.campaign_id and paused_at is not null) then 'manual_pause' else waiting_reason end,
        publish_after = greatest(due_at,clock_timestamp()), updated_at = clock_timestamp()
      where id = j.id;
      perform public.set_campaign_dispatch_delivery(j.delivery_id, 'queued');
    end if;
    recovered := recovered + 1;
  end loop;
  return recovered;
end;
$function$
;

-- Preserve RPC permissions when migra recreates functions; private helpers must not inherit PUBLIC execution.
revoke all on function public.set_campaign_paused(uuid,uuid,boolean,bigint,uuid) from public,anon,authenticated;
grant execute on function public.set_campaign_paused(uuid,uuid,boolean,bigint,uuid) to service_role;
revoke all on function public.pause_campaign(uuid,uuid,bigint,uuid),public.resume_campaign(uuid,uuid,bigint,uuid),
  public.list_campaigns_page(uuid,integer,integer,text,public.campaign_audience_type,text,text),
  public.list_campaign_activity_page(uuid,uuid,integer,integer) from public;
grant execute on function public.pause_campaign(uuid,uuid,bigint,uuid),public.resume_campaign(uuid,uuid,bigint,uuid),
  public.list_campaigns_page(uuid,integer,integer,text,public.campaign_audience_type,text,text),
  public.list_campaign_activity_page(uuid,uuid,integer,integer) to authenticated,anon,service_role;


