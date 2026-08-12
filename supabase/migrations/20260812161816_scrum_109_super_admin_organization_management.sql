drop function if exists "public"."get_platform_tenant_summary"(p_organization_id uuid);


  create table "public"."platform_admin_action_events" (
    "id" uuid not null default gen_random_uuid(),
    "platform_admin_user_id" uuid not null,
    "organization_id" uuid not null,
    "action_type" text not null,
    "target_type" text not null,
    "target_id" uuid not null,
    "request_id" uuid not null,
    "before_state" jsonb,
    "after_state" jsonb not null,
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."platform_admin_action_events" enable row level security;

revoke all on table "public"."platform_admin_action_events" from "anon";
revoke all on table "public"."platform_admin_action_events" from "authenticated";

CREATE INDEX platform_admin_action_events_organization_time_idx ON public.platform_admin_action_events USING btree (organization_id, created_at DESC);

CREATE UNIQUE INDEX platform_admin_action_events_pkey ON public.platform_admin_action_events USING btree (id);

CREATE UNIQUE INDEX platform_admin_action_events_request_key ON public.platform_admin_action_events USING btree (platform_admin_user_id, request_id);

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_pkey" PRIMARY KEY using index "platform_admin_action_events_pkey";

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_action_check" CHECK ((action_type = ANY (ARRAY['routing_queue.create'::text, 'routing_queue.update'::text]))) not valid;

alter table "public"."platform_admin_action_events" validate constraint "platform_admin_action_events_action_check";

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_admin_fkey" FOREIGN KEY (platform_admin_user_id) REFERENCES public.platform_admins(user_id) not valid;

alter table "public"."platform_admin_action_events" validate constraint "platform_admin_action_events_admin_fkey";

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_organization_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."platform_admin_action_events" validate constraint "platform_admin_action_events_organization_fkey";

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_request_key" UNIQUE using index "platform_admin_action_events_request_key";

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_target_check" CHECK ((target_type = 'routing_queue'::text)) not valid;

alter table "public"."platform_admin_action_events" validate constraint "platform_admin_action_events_target_check";

set check_function_bodies = off;

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
    where queue.id = existing_event.target_id;
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
    created_queue.id,
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

CREATE OR REPLACE FUNCTION public.get_routing_queue_audit_state(p_routing_queue_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'id', queue.id,
    'name', queue.name,
    'status', queue.status,
    'agent_ids', coalesce(
      (
        select jsonb_agg(member.agent_id order by member.agent_id)
        from public.routing_queue_members member
        where member.organization_id = queue.organization_id
          and member.routing_queue_id = queue.id
      ),
      '[]'::jsonb
    )
  )
  from public.routing_queues queue
  where queue.id = p_routing_queue_id;
$function$
;

CREATE OR REPLACE FUNCTION public.list_platform_organization_agents_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, id uuid, user_id uuid, name text, email text, picture text, queue_ids uuid[], queue_names text[], created_at timestamp with time zone, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  normalized_page integer := greatest(coalesce(p_page, 1), 1);
  normalized_page_size integer := least(greatest(coalesce(p_page_size, 10), 1), 50);
  normalized_search text := lower(btrim(coalesce(p_search, '')));
begin
  perform public.require_platform_admin();

  if not exists (
    select 1 from public.organizations organization
    where organization.id = p_organization_id
  ) then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;

  return query
  with accepted_agents as (
    select
      agent.*,
      coalesce(
        nullif(agent.extra->'invitation'->>'email', ''),
        auth_user.email
      ) as resolved_email
    from public.agents agent
    left join auth.users auth_user on auth_user.id = agent.user_id
    where agent.organization_id = p_organization_id
      and agent.ai = false
      and agent.user_id is not null
      and agent.extra->>'role' = 'agent'
      and coalesce(
        agent.extra->'invitation'->>'status',
        'accepted'
      ) = 'accepted'
  ), filtered as (
    select agent.*
    from accepted_agents agent
    where normalized_search = ''
      or lower(agent.name) like '%' || normalized_search || '%'
      or lower(coalesce(agent.resolved_email, '')) like '%' || normalized_search || '%'
  )
  select
    agent.organization_id,
    agent.id,
    agent.user_id,
    agent.name,
    agent.resolved_email,
    agent.picture,
    coalesce(queues.queue_ids, array[]::uuid[]),
    coalesce(queues.queue_names, array[]::text[]),
    agent.created_at,
    count(*) over()
  from filtered agent
  left join lateral (
    select
      array_agg(queue.id order by lower(queue.name), queue.id) as queue_ids,
      array_agg(queue.name order by lower(queue.name), queue.id) as queue_names
    from public.routing_queue_members member
    join public.routing_queues queue
      on queue.organization_id = member.organization_id
      and queue.id = member.routing_queue_id
    where member.organization_id = agent.organization_id
      and member.agent_id = agent.id
  ) queues on true
  order by lower(agent.name) asc, agent.id asc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_platform_routing_queues_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, organization_id uuid, name text, status text, member_ids uuid[], member_names text[], member_pictures text[], member_count bigint, created_at timestamp with time zone, updated_at timestamp with time zone, total_count bigint)
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

  if not exists (
    select 1 from public.organizations organization
    where organization.id = p_organization_id
  ) then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;

  if normalized_status is not null
    and normalized_status not in ('active', 'archived')
  then
    raise exception using
      errcode = '22023',
      message = 'routing queue status filter is invalid';
  end if;

  return query
  with filtered as (
    select queue.*
    from public.routing_queues queue
    where queue.organization_id = p_organization_id
      and (
        normalized_search is null
        or queue.name ilike '%' || normalized_search || '%'
      )
      and (normalized_status is null or queue.status = normalized_status)
  )
  select
    queue.id,
    queue.organization_id,
    queue.name,
    queue.status,
    coalesce(members.member_ids, array[]::uuid[]),
    coalesce(members.member_names, array[]::text[]),
    coalesce(members.member_pictures, array[]::text[]),
    coalesce(members.member_count, 0),
    queue.created_at,
    queue.updated_at,
    count(*) over()
  from filtered queue
  left join lateral (
    select
      array_agg(agent.id order by lower(agent.name), agent.id) as member_ids,
      array_agg(agent.name order by lower(agent.name), agent.id) as member_names,
      array_agg(coalesce(agent.picture, '') order by lower(agent.name), agent.id)
        as member_pictures,
      count(*) as member_count
    from public.routing_queue_members member
    join public.agents agent
      on agent.organization_id = member.organization_id
      and agent.id = member.agent_id
    where member.organization_id = queue.organization_id
      and member.routing_queue_id = queue.id
  ) members on true
  order by queue.name asc, queue.id asc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
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
      or existing_event.target_id <> p_routing_queue_id
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
    updated_queue.id,
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

CREATE OR REPLACE FUNCTION public.get_platform_tenant_summary(p_organization_id uuid)
 RETURNS TABLE(organization_id uuid, organization_name text, organization_created_at timestamp with time zone, organization_updated_at timestamp with time zone, tier_id text, tier_name text, plan_id text, human_member_count bigint, accepted_agent_count bigint, active_contact_count bigint, active_conversation_count bigint, connected_whatsapp_account_count bigint, connected_instagram_account_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform public.require_platform_admin();

  if p_organization_id is null then
    raise exception using
      errcode = '22023',
      message = 'organization id is required';
  end if;

  return query
  select
    organization.id,
    organization.name,
    organization.created_at,
    organization.updated_at,
    subscription.tier_id,
    tier.name,
    subscription.plan_id,
    (
      select count(*)
      from public.agents as agent
      where agent.organization_id = organization.id
        and agent.ai = false
        and agent.user_id is not null
        and (
          agent.extra->'invitation' is null
          or agent.extra->'invitation'->>'status' = 'accepted'
        )
    ),
    (
      select count(*)
      from public.agents as agent
      where agent.organization_id = organization.id
        and agent.ai = false
        and agent.user_id is not null
        and agent.extra->>'role' = 'agent'
        and coalesce(
          agent.extra->'invitation'->>'status',
          'accepted'
        ) = 'accepted'
    ),
    (
      select count(*)
      from public.contacts as contact
      where contact.organization_id = organization.id
        and contact.status = 'active'
    ),
    (
      select count(*)
      from public.conversations as conversation
      where conversation.organization_id = organization.id
        and conversation.status = 'active'
    ),
    (
      select count(*)
      from public.organizations_addresses as account
      where account.organization_id = organization.id
        and account.service = 'whatsapp'::public.service
        and account.status = 'connected'
    ),
    (
      select count(*)
      from public.organizations_addresses as account
      where account.organization_id = organization.id
        and account.service = 'instagram'::public.service
        and account.status = 'connected'
    )
  from public.organizations as organization
  left join billing.subscriptions as subscription
    on subscription.organization_id = organization.id
  left join billing.tiers as tier
    on tier.id = subscription.tier_id
  where organization.id = p_organization_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'organization not found';
  end if;
end;
$function$
;

grant references on table "public"."platform_admin_action_events" to "service_role";

grant trigger on table "public"."platform_admin_action_events" to "service_role";

grant truncate on table "public"."platform_admin_action_events" to "service_role";

revoke execute on function public.get_routing_queue_audit_state(uuid) from public;
revoke execute on function public.get_routing_queue_audit_state(uuid) from anon;
revoke execute on function public.get_routing_queue_audit_state(uuid) from authenticated;

revoke execute on function public.get_platform_tenant_summary(uuid) from public;
grant execute on function public.get_platform_tenant_summary(uuid) to authenticated;

revoke execute on function public.list_platform_routing_queues_page(
  uuid,
  integer,
  integer,
  text,
  text
) from public;
grant execute on function public.list_platform_routing_queues_page(
  uuid,
  integer,
  integer,
  text,
  text
) to authenticated;

revoke execute on function public.list_platform_organization_agents_page(
  uuid,
  integer,
  integer,
  text
) from public;
grant execute on function public.list_platform_organization_agents_page(
  uuid,
  integer,
  integer,
  text
) to authenticated;

revoke execute on function public.create_platform_routing_queue(
  uuid,
  text,
  uuid[],
  uuid
) from public;
grant execute on function public.create_platform_routing_queue(
  uuid,
  text,
  uuid[],
  uuid
) to authenticated;

revoke execute on function public.update_platform_routing_queue(
  uuid,
  text,
  text,
  uuid[],
  uuid
) from public;
grant execute on function public.update_platform_routing_queue(
  uuid,
  text,
  text,
  uuid[],
  uuid
) to authenticated;


