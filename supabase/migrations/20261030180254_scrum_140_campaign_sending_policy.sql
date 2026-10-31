drop trigger if exists "enforce_campaign_draft_rules" on "public"."campaigns";

alter table "public"."campaign_deliveries" drop constraint "campaign_deliveries_status_check";

alter table "public"."campaign_dispatch_jobs" drop constraint "campaign_dispatch_jobs_phase_check";

alter table "public"."campaigns" drop constraint "campaigns_delivery_counts_check";

alter table "public"."campaigns" drop constraint "campaigns_status_check";

alter table "public"."platform_admin_action_events" drop constraint "platform_admin_action_events_action_check";

alter table "public"."platform_admin_action_events" drop constraint "platform_admin_action_events_target_check";

drop function if exists "public"."list_campaigns_page"(p_organization_id uuid, p_page integer, p_page_size integer, p_search text, p_audience_type public.campaign_audience_type, p_readiness text);


  create table "public"."campaign_send_ledger" (
    "id" uuid not null default gen_random_uuid(),
    "organization_id" uuid not null,
    "job_id" uuid,
    "delivery_id" uuid,
    "legacy_delivery_id" uuid,
    "organization_address" text not null,
    "recipient_key" text not null,
    "submitted_at" timestamp with time zone not null default clock_timestamp(),
    "accepted_at" timestamp with time zone,
    "state" text not null
      );


alter table "public"."campaign_send_ledger" enable row level security;


  create table "public"."campaign_sending_policies" (
    "organization_id" uuid not null,
    "enabled" boolean not null default false,
    "daily_limit" integer,
    "max_sends_per_minute" integer,
    "recipient_cap" integer,
    "budget_timezone" text not null default 'UTC'::text,
    "revision" bigint not null default 0,
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."campaign_sending_policies" enable row level security;

alter table "public"."campaign_dispatch_jobs" add column "waiting_reason" text;

alter table "public"."campaigns" add column "cancelled_at" timestamp with time zone;

alter table "public"."campaigns" add column "cancelled_count" integer not null default 0;

alter table "public"."campaigns" add column "expired_count" integer not null default 0;

alter table "public"."campaigns" add column "expires_at" timestamp with time zone;

alter table "public"."campaigns" add column "max_sends_per_minute" integer;

alter table "public"."campaigns" add column "policy_required" boolean not null default false;

alter table "public"."campaigns" add column "schedule_timezone" text not null default 'UTC'::text;

alter table "public"."campaigns" add column "scheduled_start_at" timestamp with time zone;

alter table "public"."campaigns" add column "send_window_end" time without time zone;

alter table "public"."campaigns" add column "send_window_start" time without time zone;

CREATE INDEX campaign_dispatch_jobs_org_publication_idx ON public.campaign_dispatch_jobs USING btree (organization_id, publish_after, id) WHERE (phase = 'pending'::text);

CREATE INDEX campaign_send_ledger_daily_idx ON public.campaign_send_ledger USING btree (organization_id, submitted_at) WHERE (state <> 'released'::text);

CREATE UNIQUE INDEX campaign_send_ledger_job_id_key ON public.campaign_send_ledger USING btree (job_id);

CREATE UNIQUE INDEX campaign_send_ledger_legacy_delivery_id_key ON public.campaign_send_ledger USING btree (legacy_delivery_id);

CREATE UNIQUE INDEX campaign_send_ledger_pkey ON public.campaign_send_ledger USING btree (id);

CREATE INDEX campaign_send_ledger_rate_idx ON public.campaign_send_ledger USING btree (organization_id, organization_address, submitted_at);

CREATE INDEX campaign_send_ledger_recipient_idx ON public.campaign_send_ledger USING btree (organization_id, recipient_key, submitted_at) WHERE (state <> 'released'::text);

CREATE UNIQUE INDEX campaign_sending_policies_pkey ON public.campaign_sending_policies USING btree (organization_id);

alter table "public"."campaign_send_ledger" add constraint "campaign_send_ledger_pkey" PRIMARY KEY using index "campaign_send_ledger_pkey";

alter table "public"."campaign_sending_policies" add constraint "campaign_sending_policies_pkey" PRIMARY KEY using index "campaign_sending_policies_pkey";

alter table "public"."campaign_dispatch_jobs" add constraint "campaign_dispatch_jobs_waiting_reason_check" CHECK ((waiting_reason = ANY (ARRAY['scheduled'::text, 'sending_window'::text, 'daily_allowance'::text, 'number_rate'::text, 'recipient_frequency'::text, 'policy_unavailable'::text]))) not valid;

alter table "public"."campaign_dispatch_jobs" validate constraint "campaign_dispatch_jobs_waiting_reason_check";

alter table "public"."campaign_send_ledger" add constraint "campaign_send_ledger_delivery_id_fkey" FOREIGN KEY (delivery_id) REFERENCES public.campaign_deliveries(id) ON DELETE SET NULL not valid;

alter table "public"."campaign_send_ledger" validate constraint "campaign_send_ledger_delivery_id_fkey";

alter table "public"."campaign_send_ledger" add constraint "campaign_send_ledger_job_id_fkey" FOREIGN KEY (job_id) REFERENCES public.campaign_dispatch_jobs(id) ON DELETE SET NULL not valid;

alter table "public"."campaign_send_ledger" validate constraint "campaign_send_ledger_job_id_fkey";

alter table "public"."campaign_send_ledger" add constraint "campaign_send_ledger_job_id_key" UNIQUE using index "campaign_send_ledger_job_id_key";

alter table "public"."campaign_send_ledger" add constraint "campaign_send_ledger_legacy_delivery_id_key" UNIQUE using index "campaign_send_ledger_legacy_delivery_id_key";

alter table "public"."campaign_send_ledger" add constraint "campaign_send_ledger_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."campaign_send_ledger" validate constraint "campaign_send_ledger_organization_id_fkey";

alter table "public"."campaign_send_ledger" add constraint "campaign_send_ledger_state_check" CHECK ((state = ANY (ARRAY['reserved'::text, 'accepted'::text, 'released'::text]))) not valid;

alter table "public"."campaign_send_ledger" validate constraint "campaign_send_ledger_state_check";

alter table "public"."campaign_sending_policies" add constraint "campaign_sending_policies_check" CHECK (((NOT enabled) OR ((daily_limit IS NOT NULL) AND (max_sends_per_minute IS NOT NULL) AND (recipient_cap IS NOT NULL)))) not valid;

alter table "public"."campaign_sending_policies" validate constraint "campaign_sending_policies_check";

alter table "public"."campaign_sending_policies" add constraint "campaign_sending_policies_daily_limit_check" CHECK (((daily_limit >= 1) AND (daily_limit <= 1000000000))) not valid;

alter table "public"."campaign_sending_policies" validate constraint "campaign_sending_policies_daily_limit_check";

alter table "public"."campaign_sending_policies" add constraint "campaign_sending_policies_max_sends_per_minute_check" CHECK (((max_sends_per_minute >= 1) AND (max_sends_per_minute <= 60000))) not valid;

alter table "public"."campaign_sending_policies" validate constraint "campaign_sending_policies_max_sends_per_minute_check";

alter table "public"."campaign_sending_policies" add constraint "campaign_sending_policies_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."campaign_sending_policies" validate constraint "campaign_sending_policies_organization_id_fkey";

alter table "public"."campaign_sending_policies" add constraint "campaign_sending_policies_recipient_cap_check" CHECK (((recipient_cap >= 1) AND (recipient_cap <= 1000000))) not valid;

alter table "public"."campaign_sending_policies" validate constraint "campaign_sending_policies_recipient_cap_check";

alter table "public"."campaigns" add constraint "campaigns_schedule_check" CHECK ((((expires_at IS NULL) OR (scheduled_start_at IS NULL) OR (expires_at > scheduled_start_at)) AND (((send_window_start IS NULL) AND (send_window_end IS NULL)) OR ((send_window_start IS NOT NULL) AND (send_window_end IS NOT NULL) AND (send_window_start <> send_window_end))) AND ((max_sends_per_minute IS NULL) OR ((max_sends_per_minute >= 1) AND (max_sends_per_minute <= 60000))))) not valid;

alter table "public"."campaigns" validate constraint "campaigns_schedule_check";

alter table "public"."campaign_deliveries" add constraint "campaign_deliveries_status_check" CHECK ((status = ANY (ARRAY['queued'::text, 'processing'::text, 'accepted'::text, 'failed'::text, 'needs_review'::text, 'expired'::text, 'cancelled'::text]))) not valid;

alter table "public"."campaign_deliveries" validate constraint "campaign_deliveries_status_check";

alter table "public"."campaign_dispatch_jobs" add constraint "campaign_dispatch_jobs_phase_check" CHECK ((phase = ANY (ARRAY['pending'::text, 'preparing'::text, 'submitting'::text, 'accepted'::text, 'failed'::text, 'retry_scheduled'::text, 'needs_review'::text, 'expired'::text, 'cancelled'::text]))) not valid;

alter table "public"."campaign_dispatch_jobs" validate constraint "campaign_dispatch_jobs_phase_check";

alter table "public"."campaigns" add constraint "campaigns_delivery_counts_check" CHECK (((queued_count >= 0) AND (processing_count >= 0) AND (accepted_count >= 0) AND (failed_count >= 0) AND (needs_review_count >= 0) AND (expired_count >= 0) AND (cancelled_count >= 0))) not valid;

alter table "public"."campaigns" validate constraint "campaigns_delivery_counts_check";

alter table "public"."campaigns" add constraint "campaigns_status_check" CHECK ((status = ANY (ARRAY['draft'::text, 'queued'::text, 'running'::text, 'completed'::text, 'failed'::text, 'needs_review'::text, 'expired'::text, 'cancelled'::text]))) not valid;

alter table "public"."campaigns" validate constraint "campaigns_status_check";

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_action_check" CHECK ((action_type = ANY (ARRAY['routing_queue.create'::text, 'routing_queue.update'::text, 'organization_agent_capacity.update'::text, 'organization_agent.invite'::text, 'organization_agent.update'::text, 'organization_agent.remove'::text, 'organization_member.invite'::text, 'organization_member.update'::text, 'organization_member.remove'::text, 'organization_automation.update'::text, 'organization_module_permissions.update'::text, 'organization_integrations.update'::text, 'organization_campaign_policy.update'::text, 'organization_media_storage.quota_update'::text, 'organization_media_storage.reconcile'::text, 'whatsapp.health_check'::text, 'whatsapp.profile_refresh'::text, 'whatsapp.template_sync'::text]))) not valid;

alter table "public"."platform_admin_action_events" validate constraint "platform_admin_action_events_action_check";

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_target_check" CHECK ((((target_type = 'routing_queue'::text) AND (action_type ~~ 'routing_queue.%'::text)) OR ((target_type = 'organization_agent_capacity'::text) AND (action_type = 'organization_agent_capacity.update'::text)) OR ((target_type = 'organization_agent'::text) AND (action_type ~~ 'organization_agent.%'::text)) OR ((target_type = 'organization_member'::text) AND (action_type ~~ 'organization_member.%'::text)) OR ((target_type = 'organization_automation'::text) AND (action_type = 'organization_automation.update'::text)) OR ((target_type = 'organization_media_storage'::text) AND (action_type ~~ 'organization_media_storage.%'::text)) OR ((target_type = 'organization_module_permissions'::text) AND (action_type = 'organization_module_permissions.update'::text)) OR ((target_type = 'organization_integrations'::text) AND (action_type = 'organization_integrations.update'::text)) OR ((target_type = 'organization_campaign_policy'::text) AND (action_type = 'organization_campaign_policy.update'::text)) OR ((target_type = 'whatsapp_account'::text) AND (action_type ~~ 'whatsapp.%'::text)))) not valid;

alter table "public"."platform_admin_action_events" validate constraint "platform_admin_action_events_target_check";

set check_function_bodies = off;

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

CREATE OR REPLACE FUNCTION public.campaign_recipient_key(p_address text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case when btrim(p_address) ~ '^\+?[0-9 ()-]+$'
    then regexp_replace(p_address, '[^0-9]', '', 'g') else lower(btrim(p_address)) end;
$function$
;

CREATE OR REPLACE FUNCTION public.campaign_window_next_at(p_at timestamp with time zone, p_timezone text, p_start time without time zone, p_end time without time zone)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare local_at timestamp; candidate timestamptz;
begin
  if p_start is null then return p_at; end if;
  local_at := p_at at time zone p_timezone;
  if p_start < p_end then
    if local_at::time >= p_start and local_at::time < p_end then return p_at; end if;
    candidate := ((local_at::date + case when local_at::time >= p_end then 1 else 0 end) + p_start) at time zone p_timezone;
  else
    if local_at::time >= p_start or local_at::time < p_end then return p_at; end if;
    candidate := (local_at::date + p_start) at time zone p_timezone;
  end if;
  -- A skipped local time is resolved forward by PostgreSQL, never before p_at.
  return greatest(p_at, candidate);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.cancel_campaign(p_organization_id uuid, p_campaign_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c public.campaigns;
begin
  if public.get_request_organization_role(p_organization_id) is null or public.get_request_organization_role(p_organization_id) not in ('owner','admin','member') then
    raise exception 'Campaign management access required' using errcode='42501'; end if;
  perform public.lock_campaign_sending_policy(p_organization_id);
  select * into c from public.campaigns where id=p_campaign_id and organization_id=p_organization_id for update;
  if not found then raise exception 'Campaign not found' using errcode='P0002'; end if;
  if c.dispatch_transport <> 'cloudamqp' or c.status='draft' then
    raise exception 'Only started CloudAMQP campaigns can be cancelled' using errcode='23514'; end if;
  if c.cancelled_at is null and c.queued_count+c.processing_count>0 then
    update public.campaigns set cancelled_at=clock_timestamp(),status=case when needs_review_count>0 then 'needs_review' else 'cancelled' end where id=c.id;
  end if;
  return jsonb_build_object('cancelled_at',(select cancelled_at from public.campaigns where id=c.id));
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
    due_at=(p_eligibility->>'next_at')::timestamptz,publish_after=(p_eligibility->>'next_at')::timestamptz,
    lease_token=null,lease_expires_at=null,publication_token=null,publication_expires_at=null,updated_at=clock_timestamp() where id=j.id;
  perform public.set_campaign_dispatch_delivery(j.delivery_id,'queued');
  return jsonb_build_object('phase','deferred','reason',p_eligibility->>'reason','next_at',p_eligibility->>'next_at');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_campaign_sending_policy(p_organization_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p public.campaign_sending_policies; used bigint; resets timestamptz;
begin
  if public.get_request_organization_role(p_organization_id) not in ('owner','admin','member')
    or public.get_request_organization_role(p_organization_id) is null then
    raise exception 'Campaign access required' using errcode='42501'; end if;
  select * into p from public.campaign_sending_policies where organization_id=p_organization_id;
  if not found then return jsonb_build_object('enabled',false,'revision',0,'budget_timezone','UTC',
    'cloudamqp_enabled',exists(select 1 from public.campaign_dispatch_settings where organization_id=p_organization_id and enabled)); end if;
  resets := (((clock_timestamp() at time zone p.budget_timezone)::date+1)::timestamp) at time zone p.budget_timezone;
  select count(*) into used from public.campaign_send_ledger where organization_id=p_organization_id and state <> 'released'
    and submitted_at >= (((clock_timestamp() at time zone p.budget_timezone)::date)::timestamp at time zone p.budget_timezone);
  return to_jsonb(p) || jsonb_build_object('used',used,'remaining',greatest(0,p.daily_limit-used),'resets_at',resets,
    'cloudamqp_enabled',exists(select 1 from public.campaign_dispatch_settings where organization_id=p_organization_id and enabled));
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
  return result;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_platform_campaign_policy(p_organization_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;
begin
  perform public.require_platform_admin();
  if not exists (select 1 from public.organizations where id=p_organization_id) then
    raise exception 'Organization not found' using errcode='P0002'; end if;
  select to_jsonb(p) into result from public.campaign_sending_policies p where organization_id=p_organization_id;
  return coalesce(result, jsonb_build_object('organization_id',p_organization_id,'enabled',false,'revision',0,
    'daily_limit',null,'max_sends_per_minute',null,'recipient_cap',null,'budget_timezone','UTC')) ||
    jsonb_build_object('cloudamqp_enabled',exists(select 1 from public.campaign_dispatch_settings where organization_id=p_organization_id and enabled));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.lock_campaign_sending_policy(p_organization_id uuid)
 RETURNS void
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  select pg_advisory_xact_lock(hashtextextended('campaign-policy:' || p_organization_id::text, 0));
$function$
;

CREATE OR REPLACE FUNCTION public.update_platform_campaign_policy(p_organization_id uuid, p_policy jsonb, p_expected_revision bigint, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid; previous jsonb; result jsonb; event public.platform_admin_action_events;
  current_revision bigint; enabled_value boolean; zone text;
begin
  actor := public.require_platform_admin();
  if p_request_id is null or p_expected_revision is null or jsonb_typeof(p_policy) is distinct from 'object'
    or jsonb_typeof(p_policy->'enabled') is distinct from 'boolean'
    or exists (select 1 from jsonb_object_keys(p_policy) k where k not in ('enabled','daily_limit','max_sends_per_minute','recipient_cap','budget_timezone')) then
    raise exception 'Complete valid policy, revision and request ID required' using errcode='22023'; end if;
  enabled_value := (p_policy->>'enabled')::boolean;
  if exists(select 1 from jsonb_each(p_policy) v where v.key in ('daily_limit','max_sends_per_minute','recipient_cap')
    and jsonb_typeof(v.value) not in ('number','null')) then
    raise exception 'Campaign limits must be numeric' using errcode='22023'; end if;
  zone := p_policy->>'budget_timezone';
  if zone is null or not exists (select 1 from pg_timezone_names where name=zone) then
    raise exception 'Valid budget time zone required' using errcode='22023'; end if;
  if enabled_value and (coalesce(p_policy->>'daily_limit','') !~ '^[1-9][0-9]{0,8}$'
    or coalesce(p_policy->>'max_sends_per_minute','') !~ '^[1-9][0-9]{0,4}$'
    or coalesce(p_policy->>'recipient_cap','') !~ '^[1-9][0-9]{0,5}$') then
    raise exception 'Positive finite campaign limits required' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text||':'||p_request_id::text,0));
  select * into event from public.platform_admin_action_events where platform_admin_user_id=actor and request_id=p_request_id;
  if found then
    if event.action_type <> 'organization_campaign_policy.update' or event.organization_id is distinct from p_organization_id
      or event.after_state->'request_policy' is distinct from p_policy
      or (event.after_state->>'expected_revision')::bigint is distinct from p_expected_revision then
      raise exception 'Request ID already used for a different action' using errcode='22023'; end if;
    return event.after_state->'result';
  end if;
  perform public.lock_campaign_sending_policy(p_organization_id);
  previous := public.get_platform_campaign_policy(p_organization_id);
  current_revision := (previous->>'revision')::bigint;
  if current_revision <> p_expected_revision then raise exception 'Campaign policy changed. Reload before saving.' using errcode='40001'; end if;
  if enabled_value is distinct from (previous->>'enabled')::boolean and exists (
    select 1 from public.campaigns c where c.organization_id=p_organization_id
      and (c.queued_count+c.processing_count+c.needs_review_count > 0)
  ) then raise exception 'Drain or reconcile active campaigns before changing policy enforcement' using errcode='23514'; end if;
  if enabled_value and not exists (select 1 from public.campaign_dispatch_settings where organization_id=p_organization_id and enabled) then
    raise exception 'CloudAMQP campaign processing must be enabled first' using errcode='23514'; end if;
  if zone is distinct from previous->>'budget_timezone' and exists (
    select 1 from public.campaign_send_ledger where organization_id=p_organization_id and submitted_at>clock_timestamp()-interval '48 hours'
  ) then raise exception 'Budget time zone cannot change within 48 hours of campaign submissions' using errcode='23514'; end if;
  -- Seed trustworthy historical acceptance before enforcement, never reset usage.
  insert into public.campaign_send_ledger(organization_id,delivery_id,legacy_delivery_id,organization_address,recipient_key,submitted_at,accepted_at,state)
  select d.organization_id,d.id,d.id,c.organization_address,public.campaign_recipient_key(d.contact_address),d.updated_at,d.updated_at,'accepted'
  from public.campaign_deliveries d join public.campaigns c on c.id=d.campaign_id
  where d.organization_id=p_organization_id and d.status='accepted' and d.updated_at>clock_timestamp()-interval '48 hours'
    and not exists (select 1 from public.campaign_send_ledger l where l.delivery_id=d.id and l.state <> 'released')
  on conflict (legacy_delivery_id) do nothing;
  insert into public.campaign_sending_policies(organization_id,enabled,daily_limit,max_sends_per_minute,recipient_cap,budget_timezone,revision)
  values (p_organization_id,enabled_value,(p_policy->>'daily_limit')::integer,(p_policy->>'max_sends_per_minute')::integer,
    (p_policy->>'recipient_cap')::integer,zone,current_revision+1)
  on conflict (organization_id) do update set enabled=excluded.enabled,daily_limit=excluded.daily_limit,
    max_sends_per_minute=excluded.max_sends_per_minute,recipient_cap=excluded.recipient_cap,
    budget_timezone=excluded.budget_timezone,revision=excluded.revision,updated_at=clock_timestamp();
  -- Wake deferred work on policy edits, but never release its existing reservations.
  update public.campaign_dispatch_jobs set due_at=least(due_at,clock_timestamp()),publish_after=clock_timestamp(),
    publication_token=null,publication_expires_at=null
  where organization_id=p_organization_id and phase='pending' and waiting_reason is not null;
  result := public.get_platform_campaign_policy(p_organization_id);
  insert into public.platform_admin_action_events(platform_admin_user_id,organization_id,action_type,target_type,target_id,request_id,before_state,after_state)
  values(actor,p_organization_id,'organization_campaign_policy.update','organization_campaign_policy',p_organization_id::text,p_request_id,previous,
    jsonb_build_object('result',result,'request_policy',p_policy,'expected_revision',p_expected_revision));
  perform realtime.send('{}'::jsonb,'module-permissions','module-permissions:'||p_organization_id::text,true);
  return result;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.begin_campaign_dispatch_send(p_job_id uuid, p_token uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare j public.campaign_dispatch_jobs; c public.campaigns; eligibility jsonb;
begin
  select campaign_id,organization_id into j.campaign_id,j.organization_id from public.campaign_dispatch_jobs where id = p_job_id;
  if not found then return false; end if;
  perform public.lock_campaign_sending_policy(j.organization_id);
  select * into strict c from public.campaigns where id = j.campaign_id for update;
  select * into strict j from public.campaign_dispatch_jobs where id = p_job_id for update;
  if j.phase <> 'preparing' or j.lease_token is distinct from p_token
    or j.lease_expires_at <= clock_timestamp() then return false; end if;
  if not public.is_organization_active(j.organization_id) or not exists (
    select 1 from public.organizations_addresses a where a.organization_id = j.organization_id
      and a.address = c.organization_address and a.service = 'whatsapp' and a.status = 'connected'
  ) then return false; end if;
  eligibility := public.campaign_dispatch_eligibility(j.id);
  if eligibility <> '{}'::jsonb then
    perform public.defer_campaign_dispatch_job(j.id,eligibility); return false;
  end if;
  update public.campaign_dispatch_jobs set phase = 'submitting', send_started_at = clock_timestamp(),
    lease_expires_at = clock_timestamp() + interval '2 minutes', updated_at = clock_timestamp() where id = j.id;
  update public.campaign_deliveries set attempts = attempts + 1 where id = j.delivery_id;
  insert into public.campaign_send_ledger(organization_id,job_id,delivery_id,organization_address,recipient_key,state)
  select j.organization_id,j.id,j.delivery_id,c.organization_address,public.campaign_recipient_key(d.contact_address),'reserved'
  from public.campaign_deliveries d where d.id=j.delivery_id;
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
declare j public.campaign_dispatch_jobs; c public.campaigns; eligibility jsonb;
begin
  select campaign_id,organization_id into j.campaign_id,j.organization_id from public.campaign_dispatch_jobs where id = p_job_id;
  if not found then return null; end if;
  perform public.lock_campaign_sending_policy(j.organization_id);
  select * into strict c from public.campaigns where id = j.campaign_id for update;
  select * into strict j from public.campaign_dispatch_jobs where id = p_job_id for update;
  if c.dispatch_transport <> 'cloudamqp' then raise exception 'wrong campaign transport'; end if;
  if j.phase <> 'pending' then return jsonb_build_object('phase', j.phase); end if;
  eligibility := public.campaign_dispatch_eligibility(j.id);
  if eligibility <> '{}'::jsonb then return public.defer_campaign_dispatch_job(j.id,eligibility); end if;
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
  update public.campaign_dispatch_jobs set phase = 'preparing', waiting_reason=null, lease_token = gen_random_uuid(),
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
  with organizations as (
    select j.organization_id,min(j.publish_after) as oldest from public.campaign_dispatch_jobs j
    where j.phase='pending' and j.due_at<=clock_timestamp() and j.publish_after<=clock_timestamp()
      and (j.publication_expires_at is null or j.publication_expires_at<clock_timestamp())
    group by j.organization_id order by min(j.publish_after),j.organization_id limit 100
  ), pool as (
    select batch.id,row_number() over(partition by o.organization_id order by batch.campaign_ordinal,batch.publish_after,batch.id) as ordinal
    from organizations o cross join lateral (
      select j.campaign_id,min(j.publish_after) as oldest from public.campaign_dispatch_jobs j
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
      or new.template_variable_mapping is distinct from old.template_variable_mapping
      or (new.organization_id,new.organization_address,new.audience_type,new.scheduled_start_at,new.expires_at,
        new.schedule_timezone,new.send_window_start,new.send_window_end,new.max_sends_per_minute,new.policy_required)
      is distinct from (old.organization_id,old.organization_address,old.audience_type,old.scheduled_start_at,old.expires_at,
        old.schedule_timezone,old.send_window_start,old.send_window_end,old.max_sends_per_minute,old.policy_required)) then
    raise exception 'Queued campaign content is immutable' using errcode = '23514';
  end if;
  if not exists(select 1 from pg_timezone_names where name=new.schedule_timezone) then
    raise exception 'Valid campaign time zone required' using errcode='22023'; end if;
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
  select campaign_id,organization_id into j.campaign_id,j.organization_id from public.campaign_dispatch_jobs where id = p_job_id;
  if not found then raise exception 'job not found'; end if;
  perform public.lock_campaign_sending_policy(j.organization_id);
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
  update public.campaign_send_ledger set state=case when result='accepted' then 'accepted'
    when result='needs_review' then 'reserved' else 'released' end,
    accepted_at=case when result='accepted' then clock_timestamp() else accepted_at end
  where job_id=j.id;
  if result in ('failed','retry_scheduled') and j.send_started_at is not null then
    -- Rejections can free allowance before tomorrow; wake a bounded group.
    update public.campaign_dispatch_jobs set due_at=clock_timestamp(),publish_after=clock_timestamp(),
      publication_token=null,publication_expires_at=null where id in (
        select id from public.campaign_dispatch_jobs where organization_id=j.organization_id
          and phase='pending' and waiting_reason in ('daily_allowance','recipient_frequency')
        order by due_at,id limit 100
      );
  end if;
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

CREATE OR REPLACE FUNCTION public.list_campaigns_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text, p_audience_type public.campaign_audience_type DEFAULT NULL::public.campaign_audience_type, p_readiness text DEFAULT NULL::text)
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
    needs_review_count = needs_review_count - (d.status = 'needs_review')::integer + (p_status = 'needs_review')::integer,
    expired_count = expired_count - (d.status = 'expired')::integer + (p_status = 'expired')::integer,
    cancelled_count = cancelled_count - (d.status = 'cancelled')::integer + (p_status = 'cancelled')::integer
  where id = d.campaign_id;
  update public.campaigns set status = case
    when needs_review_count > 0 then 'needs_review'
    when queued_count + processing_count = 0 then case when cancelled_at is not null then 'cancelled'
      when expired_count>0 then 'expired' else 'completed' end else 'running' end
  where id = d.campaign_id;
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
  enforce_policy boolean;
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

  perform public.lock_campaign_sending_policy(p_organization_id);
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
  select coalesce(p.enabled,false) into enforce_policy from public.campaign_sending_policies p where organization_id=p_organization_id;
  enforce_policy := coalesce(enforce_policy,false);
  if campaign.expires_at <= clock_timestamp() then
    raise exception 'Campaign expiry must be in the future' using errcode='23514'; end if;
  if enforce_policy and campaign.expires_at is null then
    raise exception 'Campaign expiry required while sending policy is enabled' using errcode='23514'; end if;
  if (enforce_policy or campaign.scheduled_start_at is not null or campaign.expires_at is not null or campaign.send_window_start is not null)
    and not exists(select 1 from public.campaign_dispatch_settings where organization_id=p_organization_id and enabled) then
    raise exception 'Scheduled or policy-managed campaigns require CloudAMQP' using errcode='23514'; end if;

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
    policy_required = enforce_policy,
    dispatch_transport = case when exists (
      select 1 from public.campaign_dispatch_settings s
      where s.organization_id = p_organization_id and s.enabled
    ) then 'cloudamqp' else 'postgres' end
  where id = p_campaign_id
    and organization_id = p_organization_id;

  insert into public.campaign_dispatch_jobs (organization_id, campaign_id, delivery_id, due_at, publish_after, waiting_reason)
  select d.organization_id, d.campaign_id, d.id,
    greatest(clock_timestamp(),coalesce(c.scheduled_start_at,clock_timestamp())),
    greatest(clock_timestamp(),coalesce(c.scheduled_start_at,clock_timestamp())),
    case when c.scheduled_start_at>clock_timestamp() then 'scheduled' end
  from public.campaign_deliveries d join public.campaigns c on c.id = d.campaign_id
  where d.campaign_id = p_campaign_id and c.dispatch_transport = 'cloudamqp'
  on conflict (delivery_id, attempt_no) do nothing;

  return snapshot_count;
end;
$function$
;

grant delete on table "public"."campaign_send_ledger" to "service_role";

grant insert on table "public"."campaign_send_ledger" to "service_role";

grant references on table "public"."campaign_send_ledger" to "service_role";

grant select on table "public"."campaign_send_ledger" to "service_role";

grant trigger on table "public"."campaign_send_ledger" to "service_role";

grant truncate on table "public"."campaign_send_ledger" to "service_role";

grant update on table "public"."campaign_send_ledger" to "service_role";

grant delete on table "public"."campaign_sending_policies" to "service_role";

grant insert on table "public"."campaign_sending_policies" to "service_role";

grant references on table "public"."campaign_sending_policies" to "service_role";

grant select on table "public"."campaign_sending_policies" to "service_role";

grant trigger on table "public"."campaign_sending_policies" to "service_role";

grant truncate on table "public"."campaign_sending_policies" to "service_role";

grant update on table "public"."campaign_sending_policies" to "service_role";

CREATE TRIGGER enforce_campaign_draft_rules BEFORE INSERT OR UPDATE OF organization_id, organization_address, created_by, template, carousel_media, template_variable_mapping, audience_type, scheduled_start_at, expires_at, schedule_timezone, send_window_start, send_window_end, max_sends_per_minute, policy_required ON public.campaigns FOR EACH ROW EXECUTE FUNCTION public.enforce_campaign_draft_rules();



-- Preserve explicit worker-only and tenant/platform RPC execution privileges.
revoke all on function public.lock_campaign_sending_policy(uuid) from public, anon, authenticated;

grant execute on function public.lock_campaign_sending_policy(uuid) to service_role;

revoke all on function public.campaign_recipient_key(text) from public;

grant execute on function public.campaign_recipient_key(text) to service_role;

revoke all on function public.campaign_window_next_at(timestamptz,text,time,time) from public;

grant execute on function public.campaign_window_next_at(timestamptz,text,time,time) to service_role;

revoke all on function public.get_platform_campaign_policy(uuid), public.update_platform_campaign_policy(uuid,jsonb,bigint,uuid), public.get_campaign_sending_policy(uuid), public.get_campaign_sending_state(uuid,uuid) from public;

grant execute on function public.get_platform_campaign_policy(uuid), public.update_platform_campaign_policy(uuid,jsonb,bigint,uuid), public.get_campaign_sending_policy(uuid), public.get_campaign_sending_state(uuid,uuid) to authenticated;

grant execute on function public.get_campaign_sending_policy(uuid), public.get_campaign_sending_state(uuid,uuid) to anon;

revoke all on function public.campaign_dispatch_eligibility(uuid), public.defer_campaign_dispatch_job(uuid,jsonb) from public, anon, authenticated;

grant execute on function public.campaign_dispatch_eligibility(uuid), public.defer_campaign_dispatch_job(uuid,jsonb) to service_role;

revoke all on function public.cancel_campaign(uuid,uuid) from public;

grant execute on function public.cancel_campaign(uuid,uuid) to authenticated, anon;

revoke all on public.campaign_sending_policies from public, anon, authenticated;

grant all on public.campaign_sending_policies to service_role;

revoke all on public.campaign_send_ledger from public, anon, authenticated;

grant all on public.campaign_send_ledger to service_role;


