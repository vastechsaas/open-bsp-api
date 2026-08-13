alter table "public"."platform_admin_action_events" drop constraint "platform_admin_action_events_action_check";

alter table "public"."platform_admin_action_events" drop constraint "platform_admin_action_events_target_check";


  create table "public"."whatsapp_integration_health" (
    "organization_id" uuid not null,
    "phone_number_id" text not null,
    "last_check_attempted_at" timestamp with time zone,
    "last_check_succeeded_at" timestamp with time zone,
    "token_status" text not null default 'unknown'::text,
    "token_validated_at" timestamp with time zone,
    "token_expires_at" timestamp with time zone,
    "webhook_subscription_status" text not null default 'unknown'::text,
    "webhook_validated_at" timestamp with time zone,
    "last_webhook_received_at" timestamp with time zone,
    "last_webhook_succeeded_at" timestamp with time zone,
    "last_webhook_error_at" timestamp with time zone,
    "failure_code" text,
    "failure_message" text,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."whatsapp_integration_health" enable row level security;

alter table "public"."platform_admin_action_events" alter column "target_id" set data type text using "target_id"::text;

CREATE INDEX logs_whatsapp_account_recent_idx ON public.logs USING btree (organization_id, organization_address, created_at DESC) WHERE ((service = 'whatsapp'::public.service) AND (level = 'error'::public.log_level));

CREATE INDEX messages_whatsapp_account_activity_idx ON public.messages USING btree (organization_id, organization_address, direction, "timestamp" DESC) WHERE ((service = 'whatsapp'::public.service) AND (direction = ANY (ARRAY['incoming'::public.direction, 'outgoing'::public.direction])));

CREATE INDEX whatsapp_integration_health_check_idx ON public.whatsapp_integration_health USING btree (last_check_attempted_at DESC);

CREATE UNIQUE INDEX whatsapp_integration_health_pkey ON public.whatsapp_integration_health USING btree (organization_id, phone_number_id);

alter table "public"."whatsapp_integration_health" add constraint "whatsapp_integration_health_pkey" PRIMARY KEY using index "whatsapp_integration_health_pkey";

alter table "public"."whatsapp_integration_health" add constraint "whatsapp_integration_health_account_fkey" FOREIGN KEY (organization_id, phone_number_id) REFERENCES public.organizations_addresses(organization_id, address) ON DELETE CASCADE not valid;

alter table "public"."whatsapp_integration_health" validate constraint "whatsapp_integration_health_account_fkey";

alter table "public"."whatsapp_integration_health" add constraint "whatsapp_integration_health_token_status_check" CHECK ((token_status = ANY (ARRAY['unknown'::text, 'valid'::text, 'invalid'::text, 'expired'::text, 'error'::text]))) not valid;

alter table "public"."whatsapp_integration_health" validate constraint "whatsapp_integration_health_token_status_check";

alter table "public"."whatsapp_integration_health" add constraint "whatsapp_integration_health_webhook_status_check" CHECK ((webhook_subscription_status = ANY (ARRAY['unknown'::text, 'subscribed'::text, 'unsubscribed'::text, 'error'::text]))) not valid;

alter table "public"."whatsapp_integration_health" validate constraint "whatsapp_integration_health_webhook_status_check";

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_action_check" CHECK ((action_type = ANY (ARRAY['routing_queue.create'::text, 'routing_queue.update'::text, 'whatsapp.health_check'::text, 'whatsapp.profile_refresh'::text, 'whatsapp.template_sync'::text]))) not valid;

alter table "public"."platform_admin_action_events" validate constraint "platform_admin_action_events_action_check";

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_target_check" CHECK ((((target_type = 'routing_queue'::text) AND (action_type ~~ 'routing_queue.%'::text)) OR ((target_type = 'whatsapp_account'::text) AND (action_type ~~ 'whatsapp.%'::text)))) not valid;

alter table "public"."platform_admin_action_events" validate constraint "platform_admin_action_events_target_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.get_platform_whatsapp_action_result(p_organization_id uuid, p_phone_number_id text, p_action_type text, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  authenticated_user_id uuid;
  event public.platform_admin_action_events;
begin
  authenticated_user_id := public.require_platform_admin();
  select * into event
  from public.platform_admin_action_events action_event
  where action_event.platform_admin_user_id = authenticated_user_id
    and action_event.request_id = p_request_id;
  if not found then return null; end if;
  if event.organization_id <> p_organization_id
    or event.target_type <> 'whatsapp_account'
    or event.target_id <> p_phone_number_id
    or event.action_type <> p_action_type then
    raise exception using errcode = '22023', message = 'request id was already used for a different platform action';
  end if;
  return event.after_state;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_platform_whatsapp_health(p_organization_id uuid, p_phone_number_id text)
 RETURNS TABLE(organization_id uuid, phone_number_id text, display_name text, display_phone text, connection_status text, health_status text, webhook_status text, token_status text, quality_rating text, messaging_limit_tier text, phone_number_status text, waba_id text, business_id text, application_id text, profile_synced_at timestamp with time zone, last_incoming_message_at timestamp with time zone, last_outgoing_message_at timestamp with time zone, last_message_activity_at timestamp with time zone, last_check_attempted_at timestamp with time zone, last_check_succeeded_at timestamp with time zone, token_validated_at timestamp with time zone, token_expires_at timestamp with time zone, webhook_validated_at timestamp with time zone, last_webhook_received_at timestamp with time zone, last_webhook_succeeded_at timestamp with time zone, last_webhook_error_at timestamp with time zone, webhook_error_count_24h bigint, failure_code text, failure_message text, template_status_summary jsonb, total_count bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select row.*
  from public.list_platform_whatsapp_health_page(p_organization_id, 1, 50, p_phone_number_id, null) row
  where row.phone_number_id = p_phone_number_id;
$function$
;

CREATE OR REPLACE FUNCTION public.list_platform_whatsapp_health_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, phone_number_id text, display_name text, display_phone text, connection_status text, health_status text, webhook_status text, token_status text, quality_rating text, messaging_limit_tier text, phone_number_status text, waba_id text, business_id text, application_id text, profile_synced_at timestamp with time zone, last_incoming_message_at timestamp with time zone, last_outgoing_message_at timestamp with time zone, last_message_activity_at timestamp with time zone, last_check_attempted_at timestamp with time zone, last_check_succeeded_at timestamp with time zone, token_validated_at timestamp with time zone, token_expires_at timestamp with time zone, webhook_validated_at timestamp with time zone, last_webhook_received_at timestamp with time zone, last_webhook_succeeded_at timestamp with time zone, last_webhook_error_at timestamp with time zone, webhook_error_count_24h bigint, failure_code text, failure_message text, template_status_summary jsonb, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  normalized_page integer := greatest(coalesce(p_page, 1), 1);
  normalized_page_size integer := least(greatest(coalesce(p_page_size, 10), 1), 50);
  normalized_search text := nullif(btrim(coalesce(p_search, '')), '');
  normalized_status text := nullif(lower(btrim(coalesce(p_status, ''))), '');
begin
  perform public.require_platform_admin();

  if p_organization_id is null then
    raise exception using errcode = '22023', message = 'organization id is required';
  end if;
  if not exists (select 1 from public.organizations where id = p_organization_id) then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;
  if normalized_status is not null and normalized_status not in ('healthy', 'warning', 'disconnected', 'unknown') then
    raise exception using errcode = '22023', message = 'invalid WhatsApp health status';
  end if;

  return query
  with account_rows as (
    select
      account.organization_id,
      account.address as phone_number_id,
      coalesce(account.extra->>'verified_name', account.extra->>'phone_number', account.address) as display_name,
      account.extra->>'phone_number' as display_phone,
      account.status as connection_status,
      public.platform_whatsapp_health_state(
        account.status,
        coalesce(health.token_status, 'unknown'),
        coalesce(health.webhook_subscription_status, 'unknown'),
        health.last_check_attempted_at,
        health.last_check_succeeded_at,
        health.token_expires_at,
        account.extra->>'quality_rating',
        greatest(health.last_webhook_error_at, recent_errors.last_error_at),
        health.failure_code
      ) as health_status,
      coalesce(health.webhook_subscription_status, 'unknown') as webhook_status,
      coalesce(health.token_status, 'unknown') as token_status,
      account.extra->>'quality_rating' as quality_rating,
      account.extra->>'messaging_limit_tier' as messaging_limit_tier,
      account.extra->>'phone_number_status' as phone_number_status,
      account.extra->>'waba_id' as waba_id,
      account.extra->>'business_id' as business_id,
      account.extra->>'application_id' as application_id,
      nullif(account.extra->>'profile_synced_at', '')::timestamptz as profile_synced_at,
      activity.last_incoming_message_at,
      activity.last_outgoing_message_at,
      greatest(activity.last_incoming_message_at, activity.last_outgoing_message_at) as last_message_activity_at,
      health.last_check_attempted_at,
      health.last_check_succeeded_at,
      health.token_validated_at,
      health.token_expires_at,
      health.webhook_validated_at,
      health.last_webhook_received_at,
      health.last_webhook_succeeded_at,
      greatest(health.last_webhook_error_at, recent_errors.last_error_at) as last_webhook_error_at,
      coalesce(recent_errors.error_count, 0) as webhook_error_count_24h,
      health.failure_code,
      health.failure_message,
      coalesce(templates.status_summary, '{}'::jsonb) as template_status_summary
    from public.organizations_addresses account
    left join public.whatsapp_integration_health health
      on health.organization_id = account.organization_id
      and health.phone_number_id = account.address
    left join lateral (
      select
        max(message.timestamp) filter (where message.direction = 'incoming') as last_incoming_message_at,
        max(message.timestamp) filter (where message.direction = 'outgoing') as last_outgoing_message_at
      from public.messages message
      where message.organization_id = account.organization_id
        and message.organization_address = account.address
        and message.service = 'whatsapp'::public.service
        and message.direction in ('incoming', 'outgoing')
    ) activity on true
    left join lateral (
      select jsonb_object_agg(grouped.status, grouped.status_count) as status_summary
      from (
        select template.status, count(*) as status_count
        from public.message_templates template
        where template.organization_id = account.organization_id
          and template.organization_address = account.address
        group by template.status
      ) grouped
    ) templates on true
    left join lateral (
      select count(*) as error_count, max(log.created_at) as last_error_at
      from public.logs log
      where log.organization_id = account.organization_id
        and log.organization_address = account.address
        and log.service = 'whatsapp'::public.service
        and log.level = 'error'::public.log_level
        and log.created_at >= now() - interval '24 hours'
        and log.category in ('messages', 'history', 'webhook')
    ) recent_errors on true
    where account.organization_id = p_organization_id
      and account.service = 'whatsapp'::public.service
  ), filtered as (
    select * from account_rows row
    where (normalized_search is null
      or row.display_name ilike '%' || normalized_search || '%'
      or coalesce(row.display_phone, '') ilike '%' || normalized_search || '%'
      or row.phone_number_id ilike '%' || normalized_search || '%'
      or coalesce(row.waba_id, '') ilike '%' || normalized_search || '%')
      and (normalized_status is null or row.health_status = normalized_status)
  )
  select filtered.*, count(*) over() as total_count
  from filtered
  order by filtered.display_name asc, filtered.phone_number_id asc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.platform_whatsapp_health_state(p_connection_status text, p_token_status text, p_webhook_status text, p_last_check_attempted_at timestamp with time zone, p_last_check_succeeded_at timestamp with time zone, p_token_expires_at timestamp with time zone, p_quality_rating text, p_last_webhook_error_at timestamp with time zone, p_failure_code text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select case
    when p_connection_status <> 'connected'
      or p_token_status in ('invalid', 'expired')
      or p_failure_code = 'PHONE_NOT_OPERATIONAL' then 'disconnected'
    when p_last_check_attempted_at is null then 'unknown'
    when p_last_check_succeeded_at is null
      or p_last_check_attempted_at > p_last_check_succeeded_at
      or p_last_check_attempted_at < now() - interval '5 minutes'
      or p_webhook_status <> 'subscribed'
      or p_token_status <> 'valid'
      or (p_token_expires_at is not null and p_token_expires_at < now() + interval '7 days')
      or upper(coalesce(p_quality_rating, 'UNKNOWN')) not in ('GREEN', 'UNKNOWN')
      or p_last_webhook_error_at > coalesce(p_last_check_succeeded_at, '-infinity'::timestamptz)
      then 'warning'
    else 'healthy'
  end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_platform_whatsapp_action(p_organization_id uuid, p_phone_number_id text, p_action_type text, p_request_id uuid, p_after_state jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  authenticated_user_id uuid;
  existing_event public.platform_admin_action_events;
  event_id uuid;
begin
  authenticated_user_id := public.require_platform_admin();
  if p_action_type not in ('whatsapp.health_check', 'whatsapp.profile_refresh', 'whatsapp.template_sync') then
    raise exception using errcode = '22023', message = 'invalid WhatsApp platform action';
  end if;
  if p_after_state is null then
    raise exception using errcode = '22023', message = 'action result is required';
  end if;
  if not exists (
    select 1 from public.organizations_addresses account
    where account.organization_id = p_organization_id
      and account.address = p_phone_number_id
      and account.service = 'whatsapp'::public.service
  ) then
    raise exception using errcode = 'P0002', message = 'WhatsApp integration not found';
  end if;

  select * into existing_event
  from public.platform_admin_action_events event
  where event.platform_admin_user_id = authenticated_user_id
    and event.request_id = p_request_id;

  if found then
    if existing_event.organization_id <> p_organization_id
      or existing_event.target_type <> 'whatsapp_account'
      or existing_event.target_id <> p_phone_number_id
      or existing_event.action_type <> p_action_type then
      raise exception using errcode = '22023', message = 'request id was already used for a different platform action';
    end if;
    return existing_event.id;
  end if;

  insert into public.platform_admin_action_events (
    platform_admin_user_id, organization_id, action_type, target_type,
    target_id, request_id, after_state
  ) values (
    authenticated_user_id, p_organization_id, p_action_type,
    'whatsapp_account', p_phone_number_id, p_request_id, p_after_state
  ) returning id into event_id;
  return event_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_platform_routing_queue(p_organization_id uuid, p_name text, p_agent_ids uuid[] DEFAULT ARRAY[]::uuid[], p_request_id uuid DEFAULT NULL::uuid)
 RETURNS public.routing_queues
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  authenticated_user_id uuid;
  normalized_name text := btrim(coalesce(p_name, ''));
  created_queue public.routing_queues;
  existing_event public.platform_admin_action_events;
begin
  authenticated_user_id := public.require_platform_admin();

  if p_request_id is null then
    raise exception using errcode = '22023', message = 'request id is required';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(authenticated_user_id::text || ':' || p_request_id::text, 0)
  );

  select * into existing_event
  from public.platform_admin_action_events event
  where event.platform_admin_user_id = authenticated_user_id
    and event.request_id = p_request_id;

  if found then
    if existing_event.action_type <> 'routing_queue.create'
      or existing_event.organization_id <> p_organization_id
    then
      raise exception using
        errcode = '22023',
        message = 'request id was already used for a different platform action';
    end if;

    select queue.* into created_queue
    from public.routing_queues queue
    where queue.id = existing_event.target_id::uuid;
    return created_queue;
  end if;

  if not exists (
    select 1 from public.organizations organization
    where organization.id = p_organization_id
  ) then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;

  if char_length(normalized_name) not between 1 and 80 then
    raise exception using
      errcode = '22023',
      message = 'routing queue name must contain between 1 and 80 characters';
  end if;

  perform public.validate_routing_queue_agent_ids(p_organization_id, p_agent_ids);

  insert into public.routing_queues (organization_id, name)
  values (p_organization_id, normalized_name)
  returning * into created_queue;

  perform public.replace_routing_queue_members(
    created_queue.organization_id,
    created_queue.id,
    p_agent_ids
  );

  insert into public.platform_admin_action_events (
    platform_admin_user_id,
    organization_id,
    action_type,
    target_type,
    target_id,
    request_id,
    after_state
  ) values (
    authenticated_user_id,
    created_queue.organization_id,
    'routing_queue.create',
    'routing_queue',
    created_queue.id::text,
    p_request_id,
    public.get_routing_queue_audit_state(created_queue.id)
  );

  return created_queue;
exception
  when unique_violation then
    raise exception using
      errcode = '23505',
      message = 'routing queue name already exists in this organization';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_platform_routing_queue(p_routing_queue_id uuid, p_name text, p_status text, p_agent_ids uuid[] DEFAULT ARRAY[]::uuid[], p_request_id uuid DEFAULT NULL::uuid)
 RETURNS public.routing_queues
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  authenticated_user_id uuid;
  normalized_name text := btrim(coalesce(p_name, ''));
  existing_queue public.routing_queues;
  updated_queue public.routing_queues;
  existing_event public.platform_admin_action_events;
  before_state jsonb;
begin
  authenticated_user_id := public.require_platform_admin();

  if p_request_id is null then
    raise exception using errcode = '22023', message = 'request id is required';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(authenticated_user_id::text || ':' || p_request_id::text, 0)
  );

  select * into existing_event
  from public.platform_admin_action_events event
  where event.platform_admin_user_id = authenticated_user_id
    and event.request_id = p_request_id;

  if found then
    if existing_event.action_type <> 'routing_queue.update'
      or existing_event.target_id <> p_routing_queue_id::text
    then
      raise exception using
        errcode = '22023',
        message = 'request id was already used for a different platform action';
    end if;

    select queue.* into updated_queue
    from public.routing_queues queue
    where queue.id = p_routing_queue_id;
    return updated_queue;
  end if;

  select queue.* into existing_queue
  from public.routing_queues queue
  where queue.id = p_routing_queue_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'routing queue not found';
  end if;

  if char_length(normalized_name) not between 1 and 80 then
    raise exception using
      errcode = '22023',
      message = 'routing queue name must contain between 1 and 80 characters';
  end if;

  if p_status not in ('active', 'archived') then
    raise exception using
      errcode = '22023',
      message = 'routing queue status must be active or archived';
  end if;

  perform public.validate_routing_queue_agent_ids(
    existing_queue.organization_id,
    p_agent_ids
  );

  before_state := public.get_routing_queue_audit_state(existing_queue.id);

  update public.routing_queues queue
  set name = normalized_name,
      status = p_status
  where queue.id = p_routing_queue_id
  returning * into updated_queue;

  perform public.replace_routing_queue_members(
    updated_queue.organization_id,
    updated_queue.id,
    p_agent_ids
  );

  insert into public.platform_admin_action_events (
    platform_admin_user_id,
    organization_id,
    action_type,
    target_type,
    target_id,
    request_id,
    before_state,
    after_state
  ) values (
    authenticated_user_id,
    updated_queue.organization_id,
    'routing_queue.update',
    'routing_queue',
    updated_queue.id::text,
    p_request_id,
    before_state,
    public.get_routing_queue_audit_state(updated_queue.id)
  );

  return updated_queue;
exception
  when unique_violation then
    raise exception using
      errcode = '23505',
      message = 'routing queue name already exists in this organization';
end;
$function$
;

grant references on table "public"."whatsapp_integration_health" to "service_role";

grant trigger on table "public"."whatsapp_integration_health" to "service_role";

grant truncate on table "public"."whatsapp_integration_health" to "service_role";

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.whatsapp_integration_health FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');

revoke execute on function public.platform_whatsapp_health_state(text,text,text,timestamptz,timestamptz,timestamptz,text,timestamptz,text) from public;
revoke execute on function public.list_platform_whatsapp_health_page(uuid,integer,integer,text,text) from public;
revoke execute on function public.get_platform_whatsapp_health(uuid,text) from public;
revoke execute on function public.record_platform_whatsapp_action(uuid,text,text,uuid,jsonb) from public;
revoke execute on function public.get_platform_whatsapp_action_result(uuid,text,text,uuid) from public;

grant execute on function public.list_platform_whatsapp_health_page(uuid,integer,integer,text,text) to authenticated;
grant execute on function public.get_platform_whatsapp_health(uuid,text) to authenticated;
grant execute on function public.record_platform_whatsapp_action(uuid,text,text,uuid,jsonb) to authenticated;
grant execute on function public.get_platform_whatsapp_action_result(uuid,text,text,uuid) to authenticated;
