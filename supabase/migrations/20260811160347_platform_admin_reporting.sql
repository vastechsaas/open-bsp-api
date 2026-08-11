  create table "public"."platform_report_export_events" (
    "id" uuid not null default gen_random_uuid(),
    "platform_admin_user_id" uuid not null,
    "organization_id" uuid not null,
    "report_type" text not null,
    "report_month" date not null,
    "request_id" uuid not null,
    "row_count" bigint not null,
    "generated_at" timestamp with time zone not null default now()
      );


alter table "public"."platform_report_export_events" enable row level security;

CREATE INDEX campaign_deliveries_organization_created_campaign_idx ON public.campaign_deliveries USING btree (organization_id, created_at, campaign_id);

CREATE INDEX platform_report_export_events_admin_time_idx ON public.platform_report_export_events USING btree (platform_admin_user_id, generated_at DESC);

CREATE INDEX platform_report_export_events_organization_month_idx ON public.platform_report_export_events USING btree (organization_id, report_month DESC, report_type);

CREATE UNIQUE INDEX platform_report_export_events_pkey ON public.platform_report_export_events USING btree (id);

CREATE UNIQUE INDEX platform_report_export_events_request_key ON public.platform_report_export_events USING btree (platform_admin_user_id, request_id);

alter table "public"."platform_report_export_events" add constraint "platform_report_export_events_pkey" PRIMARY KEY using index "platform_report_export_events_pkey";

alter table "public"."platform_report_export_events" add constraint "platform_report_export_events_admin_fkey" FOREIGN KEY (platform_admin_user_id) REFERENCES public.platform_admins(user_id) not valid;

alter table "public"."platform_report_export_events" validate constraint "platform_report_export_events_admin_fkey";

alter table "public"."platform_report_export_events" add constraint "platform_report_export_events_month_check" CHECK ((report_month = (date_trunc('month'::text, (report_month)::timestamp with time zone))::date)) not valid;

alter table "public"."platform_report_export_events" validate constraint "platform_report_export_events_month_check";

alter table "public"."platform_report_export_events" add constraint "platform_report_export_events_request_key" UNIQUE using index "platform_report_export_events_request_key";

alter table "public"."platform_report_export_events" add constraint "platform_report_export_events_row_count_check" CHECK ((row_count >= 0)) not valid;

alter table "public"."platform_report_export_events" validate constraint "platform_report_export_events_row_count_check";

alter table "public"."platform_report_export_events" add constraint "platform_report_export_events_type_check" CHECK ((report_type = ANY (ARRAY['conversations'::text, 'campaigns'::text]))) not valid;

alter table "public"."platform_report_export_events" validate constraint "platform_report_export_events_type_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.list_platform_campaign_report_rows(p_organization_id uuid, p_month date, p_page integer DEFAULT 1, p_page_size integer DEFAULT 500)
 RETURNS TABLE(organization_id uuid, organization_name text, report_month date, period_start_utc timestamp with time zone, period_end_utc timestamp with time zone, campaign_id uuid, campaign_name text, organization_address text, audience_type public.campaign_audience_type, campaign_status text, created_by_agent_id uuid, created_by_agent_name text, template_name text, template_language text, launched_at_utc timestamp with time zone, last_updated_at_utc timestamp with time zone, queued_count bigint, processing_count bigint, accepted_count bigint, failed_count bigint, total_recipient_count bigint, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  normalized_page integer;
  normalized_page_size integer;
  period_start timestamp with time zone;
  period_end timestamp with time zone;
begin
  perform public.require_platform_admin();

  if p_organization_id is null or not exists (
    select 1
    from public.organizations as organization
    where organization.id = p_organization_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'organization not found';
  end if;

  if p_month is null
    or p_month <> date_trunc('month', p_month)::date
  then
    raise exception using
      errcode = '22023',
      message = 'report month must be the first day of a calendar month';
  end if;

  normalized_page := greatest(coalesce(p_page, 1), 1);
  normalized_page_size := least(greatest(coalesce(p_page_size, 500), 1), 500);
  period_start := p_month::timestamp at time zone 'UTC';
  period_end := (p_month + interval '1 month')::timestamp at time zone 'UTC';

  return query
  with delivery_summary as materialized (
    select
      delivery.campaign_id,
      min(delivery.created_at) as launched_at,
      count(*) filter (where delivery.status = 'queued') as queued,
      count(*) filter (where delivery.status = 'processing') as processing,
      count(*) filter (where delivery.status = 'accepted') as accepted,
      count(*) filter (where delivery.status = 'failed') as failed,
      count(*) as recipients
    from public.campaign_deliveries as delivery
    where delivery.organization_id = p_organization_id
    group by delivery.campaign_id
  ), report_rows as (
    select
      organization.id as tenant_id,
      organization.name as tenant_name,
      campaign.id as target_campaign_id,
      campaign.name as target_campaign_name,
      campaign.organization_address as business_address,
      campaign.audience_type as target_audience_type,
      campaign.status as current_status,
      campaign.created_by as creator_id,
      creator.name as creator_name,
      campaign.template->>'name' as target_template_name,
      campaign.template->>'language' as target_template_language,
      delivery.launched_at,
      campaign.updated_at as last_updated_at,
      delivery.queued,
      delivery.processing,
      delivery.accepted,
      delivery.failed,
      delivery.recipients
    from delivery_summary as delivery
    join public.campaigns as campaign
      on campaign.organization_id = p_organization_id
      and campaign.id = delivery.campaign_id
    join public.organizations as organization
      on organization.id = campaign.organization_id
    left join public.agents as creator
      on creator.organization_id = campaign.organization_id
      and creator.id = campaign.created_by
    where delivery.launched_at >= period_start
      and delivery.launched_at < period_end
  )
  select
    report_row.tenant_id,
    report_row.tenant_name,
    p_month,
    period_start,
    period_end,
    report_row.target_campaign_id,
    report_row.target_campaign_name,
    report_row.business_address,
    report_row.target_audience_type,
    report_row.current_status,
    report_row.creator_id,
    report_row.creator_name,
    report_row.target_template_name,
    report_row.target_template_language,
    report_row.launched_at,
    report_row.last_updated_at,
    report_row.queued,
    report_row.processing,
    report_row.accepted,
    report_row.failed,
    report_row.recipients,
    count(*) over()
  from report_rows as report_row
  order by report_row.launched_at desc, report_row.target_campaign_id desc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_platform_conversation_report_rows(p_organization_id uuid, p_month date, p_page integer DEFAULT 1, p_page_size integer DEFAULT 500)
 RETURNS TABLE(organization_id uuid, organization_name text, report_month date, period_start_utc timestamp with time zone, period_end_utc timestamp with time zone, conversation_id uuid, service public.service, organization_address text, contact_id uuid, customer_name text, contact_address text, conversation_status text, assigned_agent_id uuid, assigned_agent_name text, conversation_created_at timestamp with time zone, first_activity_at_utc timestamp with time zone, last_activity_at_utc timestamp with time zone, incoming_message_count bigint, outgoing_message_count bigint, total_message_count bigint, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  normalized_page integer;
  normalized_page_size integer;
  period_start timestamp with time zone;
  period_end timestamp with time zone;
begin
  perform public.require_platform_admin();

  if p_organization_id is null or not exists (
    select 1
    from public.organizations as organization
    where organization.id = p_organization_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'organization not found';
  end if;

  if p_month is null
    or p_month <> date_trunc('month', p_month)::date
  then
    raise exception using
      errcode = '22023',
      message = 'report month must be the first day of a calendar month';
  end if;

  normalized_page := greatest(coalesce(p_page, 1), 1);
  normalized_page_size := least(greatest(coalesce(p_page_size, 500), 1), 500);
  period_start := p_month::timestamp at time zone 'UTC';
  period_end := (p_month + interval '1 month')::timestamp at time zone 'UTC';

  return query
  with monthly_activity as materialized (
    select
      message.conversation_id,
      min(message.timestamp) as first_activity,
      max(message.timestamp) as last_activity,
      count(*) filter (
        where message.direction = 'incoming'::public.direction
      ) as incoming_count,
      count(*) filter (
        where message.direction = 'outgoing'::public.direction
      ) as outgoing_count,
      count(*) as message_count
    from public.messages as message
    where message.organization_id = p_organization_id
      and message.direction in (
        'incoming'::public.direction,
        'outgoing'::public.direction
      )
      and message.timestamp >= period_start
      and message.timestamp < period_end
    group by message.conversation_id
  ), report_rows as (
    select
      organization.id as tenant_id,
      organization.name as tenant_name,
      conversation.id as target_conversation_id,
      conversation.service as conversation_service,
      conversation.organization_address as business_address,
      contact.id as target_contact_id,
      coalesce(contact.name, conversation.name) as target_customer_name,
      conversation.contact_address as target_contact_address,
      conversation.status as current_status,
      conversation.assigned_agent_id as current_assigned_agent_id,
      assigned_agent.name as current_assigned_agent_name,
      conversation.created_at as conversation_created,
      activity.first_activity,
      activity.last_activity,
      activity.incoming_count,
      activity.outgoing_count,
      activity.message_count
    from monthly_activity as activity
    join public.conversations as conversation
      on conversation.organization_id = p_organization_id
      and conversation.id = activity.conversation_id
    join public.organizations as organization
      on organization.id = conversation.organization_id
    left join public.contacts_addresses as contact_address_row
      on contact_address_row.organization_id = conversation.organization_id
      and contact_address_row.address = conversation.contact_address
    left join public.contacts as contact
      on contact.organization_id = conversation.organization_id
      and contact.id = contact_address_row.contact_id
    left join public.agents as assigned_agent
      on assigned_agent.organization_id = conversation.organization_id
      and assigned_agent.id = conversation.assigned_agent_id
  )
  select
    report_row.tenant_id,
    report_row.tenant_name,
    p_month,
    period_start,
    period_end,
    report_row.target_conversation_id,
    report_row.conversation_service,
    report_row.business_address,
    report_row.target_contact_id,
    report_row.target_customer_name,
    report_row.target_contact_address,
    report_row.current_status,
    report_row.current_assigned_agent_id,
    report_row.current_assigned_agent_name,
    report_row.conversation_created,
    report_row.first_activity,
    report_row.last_activity,
    report_row.incoming_count,
    report_row.outgoing_count,
    report_row.message_count,
    count(*) over()
  from report_rows as report_row
  order by
    report_row.last_activity desc,
    report_row.target_conversation_id desc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_platform_report_export(p_organization_id uuid, p_report_type text, p_month date, p_request_id uuid, p_row_count bigint)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  authenticated_user_id uuid;
  normalized_report_type text;
  event_id uuid;
  existing_event public.platform_report_export_events;
begin
  authenticated_user_id := public.require_platform_admin();
  normalized_report_type := lower(btrim(coalesce(p_report_type, '')));

  if p_organization_id is null or not exists (
    select 1
    from public.organizations as organization
    where organization.id = p_organization_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'organization not found';
  end if;

  if normalized_report_type not in ('conversations', 'campaigns') then
    raise exception using
      errcode = '22023',
      message = 'report type must be conversations or campaigns';
  end if;

  if p_month is null
    or p_month <> date_trunc('month', p_month)::date
  then
    raise exception using
      errcode = '22023',
      message = 'report month must be the first day of a calendar month';
  end if;

  if p_request_id is null then
    raise exception using
      errcode = '22023',
      message = 'request id is required';
  end if;

  if p_row_count is null or p_row_count < 0 then
    raise exception using
      errcode = '22023',
      message = 'row count must be zero or greater';
  end if;

  insert into public.platform_report_export_events (
    platform_admin_user_id,
    organization_id,
    report_type,
    report_month,
    request_id,
    row_count
  ) values (
    authenticated_user_id,
    p_organization_id,
    normalized_report_type,
    p_month,
    p_request_id,
    p_row_count
  )
  on conflict (platform_admin_user_id, request_id) do nothing
  returning id into event_id;

  if event_id is not null then
    return event_id;
  end if;

  select * into existing_event
  from public.platform_report_export_events as export_event
  where export_event.platform_admin_user_id = authenticated_user_id
    and export_event.request_id = p_request_id;

  if existing_event.organization_id <> p_organization_id
    or existing_event.report_type <> normalized_report_type
    or existing_event.report_month <> p_month
    or existing_event.row_count <> p_row_count
  then
    raise exception using
      errcode = '22023',
      message = 'request id was already used for a different report export';
  end if;

  return existing_event.id;
end;
$function$
;

grant references on table "public"."platform_report_export_events" to "service_role";

grant trigger on table "public"."platform_report_export_events" to "service_role";

grant truncate on table "public"."platform_report_export_events" to "service_role";

revoke all on table "public"."platform_report_export_events"
from "anon", "authenticated";

grant select, insert, update, delete
on table "public"."platform_report_export_events" to "service_role";

revoke execute on function public.list_platform_conversation_report_rows(
  uuid,
  date,
  integer,
  integer
) from public;
grant execute on function public.list_platform_conversation_report_rows(
  uuid,
  date,
  integer,
  integer
) to authenticated;

revoke execute on function public.list_platform_campaign_report_rows(
  uuid,
  date,
  integer,
  integer
) from public;
grant execute on function public.list_platform_campaign_report_rows(
  uuid,
  date,
  integer,
  integer
) to authenticated;

revoke execute on function public.record_platform_report_export(
  uuid,
  text,
  date,
  uuid,
  bigint
) from public;
grant execute on function public.record_platform_report_export(
  uuid,
  text,
  date,
  uuid,
  bigint
) to authenticated;


