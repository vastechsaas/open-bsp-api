drop policy "owners can delete their orgs" on "public"."organizations";
































































































































































































  create table "public"."organization_lifecycle" (
    "organization_id" uuid not null,
    "status" text not null default 'active'::text,
    "archived_at" timestamp with time zone,
    "archived_by_user_id" uuid,
    "archived_by_scope" text,
    "archive_reason" text,
    "purge_eligible_at" timestamp with time zone,
    "restored_at" timestamp with time zone,
    "restored_by_user_id" uuid,
    "restored_by_scope" text,
    "restore_reason" text,
    "address_statuses" jsonb not null default '{}'::jsonb,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."organization_lifecycle" enable row level security;


  create table "public"."organization_lifecycle_events" (
    "id" uuid not null default gen_random_uuid(),
    "organization_id" uuid not null,
    "organization_name" text not null,
    "action_type" text not null,
    "actor_user_id" uuid not null,
    "actor_scope" text not null,
    "request_id" uuid not null,
    "reason" text not null,
    "before_state" jsonb,
    "after_state" jsonb,
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."organization_lifecycle_events" enable row level security;

CREATE INDEX organization_lifecycle_events_organization_time_idx ON public.organization_lifecycle_events USING btree (organization_id, created_at DESC, id DESC);

CREATE UNIQUE INDEX organization_lifecycle_events_pkey ON public.organization_lifecycle_events USING btree (id);

CREATE UNIQUE INDEX organization_lifecycle_events_request_key ON public.organization_lifecycle_events USING btree (request_id);

CREATE UNIQUE INDEX organization_lifecycle_pkey ON public.organization_lifecycle USING btree (organization_id);

CREATE INDEX organization_lifecycle_status_purge_idx ON public.organization_lifecycle USING btree (status, purge_eligible_at, organization_id);

alter table "public"."organization_lifecycle" add constraint "organization_lifecycle_pkey" PRIMARY KEY using index "organization_lifecycle_pkey";

alter table "public"."organization_lifecycle_events" add constraint "organization_lifecycle_events_pkey" PRIMARY KEY using index "organization_lifecycle_events_pkey";

alter table "public"."organization_lifecycle" add constraint "organization_lifecycle_archived_scope_check" CHECK (((archived_by_scope IS NULL) OR (archived_by_scope = ANY (ARRAY['owner'::text, 'platform_admin'::text])))) not valid;

alter table "public"."organization_lifecycle" validate constraint "organization_lifecycle_archived_scope_check";

alter table "public"."organization_lifecycle" add constraint "organization_lifecycle_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."organization_lifecycle" validate constraint "organization_lifecycle_organization_id_fkey";

alter table "public"."organization_lifecycle" add constraint "organization_lifecycle_restored_scope_check" CHECK (((restored_by_scope IS NULL) OR (restored_by_scope = ANY (ARRAY['owner'::text, 'platform_admin'::text])))) not valid;

alter table "public"."organization_lifecycle" validate constraint "organization_lifecycle_restored_scope_check";

alter table "public"."organization_lifecycle" add constraint "organization_lifecycle_status_check" CHECK ((status = ANY (ARRAY['active'::text, 'archived'::text]))) not valid;

alter table "public"."organization_lifecycle" validate constraint "organization_lifecycle_status_check";

alter table "public"."organization_lifecycle_events" add constraint "organization_lifecycle_events_action_check" CHECK ((action_type = ANY (ARRAY['organization.archive'::text, 'organization.restore'::text, 'organization.purge'::text]))) not valid;

alter table "public"."organization_lifecycle_events" validate constraint "organization_lifecycle_events_action_check";

alter table "public"."organization_lifecycle_events" add constraint "organization_lifecycle_events_request_key" UNIQUE using index "organization_lifecycle_events_request_key";

alter table "public"."organization_lifecycle_events" add constraint "organization_lifecycle_events_scope_check" CHECK ((actor_scope = ANY (ARRAY['owner'::text, 'platform_admin'::text]))) not valid;

alter table "public"."organization_lifecycle_events" validate constraint "organization_lifecycle_events_scope_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.archive_organization(p_organization_id uuid, p_expected_name text, p_reason text, p_request_id uuid)
 RETURNS TABLE(organization_id uuid, status text, archived_at timestamp with time zone, purge_eligible_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor_user_id uuid := auth.uid();
  actor_scope text;
  target public.organizations;
  lifecycle public.organization_lifecycle;
  previous_state jsonb;
  statuses jsonb;
begin
  if actor_user_id is null then
    raise exception using errcode = '42501', message = 'authentication required';
  end if;
  if p_request_id is null then
    raise exception using errcode = '22023', message = 'request id is required';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using errcode = '22023', message = 'archive reason is required';
  end if;

  select event.actor_scope into actor_scope
  from public.organization_lifecycle_events event
  where event.request_id = p_request_id
    and event.organization_id = p_organization_id
    and event.action_type = 'organization.archive';

  if actor_scope is not null then
    return query
    select state.organization_id, state.status, state.archived_at, state.purge_eligible_at
    from public.organization_lifecycle state
    where state.organization_id = p_organization_id;
    return;
  end if;

  select organization.* into target
  from public.organizations organization
  where organization.id = p_organization_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;
  if target.name <> p_expected_name then
    raise exception using errcode = '22023', message = 'organization name confirmation does not match';
  end if;

  if public.is_platform_admin() then
    actor_scope := 'platform_admin';
  elsif exists (
    select 1 from public.agents agent
    where agent.organization_id = p_organization_id
      and agent.user_id = actor_user_id
      and agent.ai = false
      and agent.extra->>'role' = 'owner'
      and (agent.extra->'invitation' is null or agent.extra->'invitation'->>'status' = 'accepted')
  ) then
    actor_scope := 'owner';
  else
    raise exception using errcode = '42501', message = 'owner or platform administrator access required';
  end if;

  select state.* into lifecycle
  from public.organization_lifecycle state
  where state.organization_id = p_organization_id
  for update;

  if lifecycle.status = 'archived' then
    return query select lifecycle.organization_id, lifecycle.status, lifecycle.archived_at, lifecycle.purge_eligible_at;
    return;
  end if;

  select coalesce(jsonb_object_agg(account.service::text || ':' || account.address, account.status), '{}'::jsonb)
  into statuses
  from public.organizations_addresses account
  where account.organization_id = p_organization_id;

  previous_state := to_jsonb(lifecycle);

  update public.organization_lifecycle state set
    status = 'archived',
    archived_at = clock_timestamp(),
    archived_by_user_id = actor_user_id,
    archived_by_scope = actor_scope,
    archive_reason = btrim(p_reason),
    purge_eligible_at = clock_timestamp() + interval '30 days',
    restored_at = null,
    restored_by_user_id = null,
    restored_by_scope = null,
    restore_reason = null,
    address_statuses = statuses
  where state.organization_id = p_organization_id
  returning state.* into lifecycle;

  update public.organizations_addresses account
  set status = 'archived'
  where account.organization_id = p_organization_id
    and account.status = 'connected';

  insert into public.organization_lifecycle_events (
    organization_id, organization_name, action_type, actor_user_id,
    actor_scope, request_id, reason, before_state, after_state
  ) values (
    p_organization_id, target.name, 'organization.archive', actor_user_id,
    actor_scope, p_request_id, btrim(p_reason), previous_state, to_jsonb(lifecycle)
  );

  return query select lifecycle.organization_id, lifecycle.status, lifecycle.archived_at, lifecycle.purge_eligible_at;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.is_organization_active(p_organization_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1
    from public.organization_lifecycle lifecycle
    where lifecycle.organization_id = p_organization_id
      and lifecycle.status = 'active'
  );
$function$
;

CREATE OR REPLACE FUNCTION public.list_my_archived_organizations_page(p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, organization_name text, archived_at timestamp with time zone, purge_eligible_at timestamp with time zone, archive_reason text, can_restore boolean, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  normalized_page integer := greatest(coalesce(p_page, 1), 1);
  normalized_page_size integer := least(greatest(coalesce(p_page_size, 10), 1), 50);
  normalized_search text := lower(btrim(coalesce(p_search, '')));
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'authentication required';
  end if;

  return query
  select organization.id, organization.name, lifecycle.archived_at,
    lifecycle.purge_eligible_at, lifecycle.archive_reason,
    lifecycle.purge_eligible_at > clock_timestamp(), count(*) over()
  from public.organizations organization
  join public.organization_lifecycle lifecycle on lifecycle.organization_id = organization.id
  join public.agents agent on agent.organization_id = organization.id
  where lifecycle.status = 'archived'
    and agent.user_id = auth.uid()
    and agent.ai = false
    and agent.extra->>'role' = 'owner'
    and (agent.extra->'invitation' is null or agent.extra->'invitation'->>'status' = 'accepted')
    and (normalized_search = '' or lower(organization.name) like '%' || normalized_search || '%')
  order by lifecycle.archived_at desc, organization.id desc
  limit normalized_page_size offset (normalized_page - 1) * normalized_page_size;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_platform_organization_lifecycle_page(p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, organization_name text, lifecycle_status text, archived_at timestamp with time zone, purge_eligible_at timestamp with time zone, archive_reason text, archived_by_scope text, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  normalized_page integer := greatest(coalesce(p_page, 1), 1);
  normalized_page_size integer := least(greatest(coalesce(p_page_size, 10), 1), 50);
  normalized_search text := lower(btrim(coalesce(p_search, '')));
  normalized_status text := nullif(lower(btrim(coalesce(p_status, ''))), '');
begin
  perform public.require_platform_admin();
  if normalized_status is not null and normalized_status not in ('active', 'archived') then
    raise exception using errcode = '22023', message = 'invalid lifecycle status';
  end if;

  return query
  select organization.id, organization.name, lifecycle.status,
    lifecycle.archived_at, lifecycle.purge_eligible_at,
    lifecycle.archive_reason, lifecycle.archived_by_scope, count(*) over()
  from public.organizations organization
  join public.organization_lifecycle lifecycle on lifecycle.organization_id = organization.id
  where (normalized_status is null or lifecycle.status = normalized_status)
    and (normalized_search = ''
      or lower(organization.name) like '%' || normalized_search || '%'
      or organization.id::text like '%' || normalized_search || '%')
  order by
    case when lifecycle.status = 'archived' then 0 else 1 end,
    lifecycle.archived_at desc nulls last,
    organization.updated_at desc,
    organization.id desc
  limit normalized_page_size offset (normalized_page - 1) * normalized_page_size;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.prevent_direct_organization_delete()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if coalesce(current_setting('app.organization_purge', true), '') <> 'on' then
    raise exception using
      errcode = '42501',
      message = 'direct organization deletion is disabled; archive the organization instead';
  end if;

  return old;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.purge_archived_organization(p_organization_id uuid, p_expected_name text, p_reason text, p_request_id uuid, p_actor_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  target public.organizations;
  lifecycle public.organization_lifecycle;
  prior_event public.organization_lifecycle_events;
begin
  select event.* into prior_event
  from public.organization_lifecycle_events event
  where event.request_id = p_request_id;
  if found then
    return prior_event.after_state;
  end if;

  if p_actor_user_id is null or not exists (
    select 1 from public.platform_admins admin
    where admin.user_id = p_actor_user_id and admin.active = true
  ) then
    raise exception using errcode = '42501', message = 'active platform administrator required';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using errcode = '22023', message = 'purge reason is required';
  end if;

  select organization.* into target
  from public.organizations organization
  where organization.id = p_organization_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;
  if target.name <> p_expected_name then
    raise exception using errcode = '22023', message = 'organization name confirmation does not match';
  end if;

  select state.* into lifecycle
  from public.organization_lifecycle state
  where state.organization_id = p_organization_id
  for update;
  if lifecycle.status <> 'archived' or lifecycle.purge_eligible_at > clock_timestamp() then
    raise exception using errcode = '22023', message = 'organization is not eligible for permanent purge';
  end if;

  insert into public.organization_lifecycle_events (
    organization_id, organization_name, action_type, actor_user_id,
    actor_scope, request_id, reason, before_state, after_state
  ) values (
    p_organization_id, target.name, 'organization.purge', p_actor_user_id,
    'platform_admin', p_request_id, btrim(p_reason), to_jsonb(lifecycle),
    jsonb_build_object('organization_id', p_organization_id, 'status', 'purged', 'purged_at', clock_timestamp())
  );

  perform set_config('app.organization_purge', 'on', true);
  delete from public.organizations where id = p_organization_id;

  return jsonb_build_object('organization_id', p_organization_id, 'status', 'purged');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.restore_organization(p_organization_id uuid, p_reason text, p_request_id uuid)
 RETURNS TABLE(organization_id uuid, status text, restored_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor_user_id uuid := auth.uid();
  actor_scope text;
  target public.organizations;
  lifecycle public.organization_lifecycle;
  previous_state jsonb;
begin
  if actor_user_id is null then
    raise exception using errcode = '42501', message = 'authentication required';
  end if;
  if p_request_id is null then
    raise exception using errcode = '22023', message = 'request id is required';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using errcode = '22023', message = 'restore reason is required';
  end if;

  if exists (
    select 1 from public.organization_lifecycle_events event
    where event.request_id = p_request_id
      and event.organization_id = p_organization_id
      and event.action_type = 'organization.restore'
  ) then
    return query
    select state.organization_id, state.status, state.restored_at
    from public.organization_lifecycle state
    where state.organization_id = p_organization_id;
    return;
  end if;

  select organization.* into target
  from public.organizations organization
  where organization.id = p_organization_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;

  select state.* into lifecycle
  from public.organization_lifecycle state
  where state.organization_id = p_organization_id
  for update;

  if public.is_platform_admin() then
    actor_scope := 'platform_admin';
  elsif lifecycle.purge_eligible_at > clock_timestamp() and exists (
    select 1 from public.agents agent
    where agent.organization_id = p_organization_id
      and agent.user_id = actor_user_id
      and agent.ai = false
      and agent.extra->>'role' = 'owner'
      and (agent.extra->'invitation' is null or agent.extra->'invitation'->>'status' = 'accepted')
  ) then
    actor_scope := 'owner';
  else
    raise exception using errcode = '42501', message = 'platform administrator access required after the recovery window';
  end if;

  if lifecycle.status = 'active' then
    return query select lifecycle.organization_id, lifecycle.status, lifecycle.restored_at;
    return;
  end if;

  previous_state := to_jsonb(lifecycle);

  update public.organizations_addresses account
  set status = coalesce(
    lifecycle.address_statuses->>(account.service::text || ':' || account.address),
    case when account.status = 'archived' then 'disconnected' else account.status end
  )
  where account.organization_id = p_organization_id
    and account.status = 'archived';

  update public.organization_lifecycle state set
    status = 'active',
    restored_at = clock_timestamp(),
    restored_by_user_id = actor_user_id,
    restored_by_scope = actor_scope,
    restore_reason = btrim(p_reason),
    purge_eligible_at = null,
    address_statuses = '{}'::jsonb
  where state.organization_id = p_organization_id
  returning state.* into lifecycle;

  insert into public.organization_lifecycle_events (
    organization_id, organization_name, action_type, actor_user_id,
    actor_scope, request_id, reason, before_state, after_state
  ) values (
    p_organization_id, target.name, 'organization.restore', actor_user_id,
    actor_scope, p_request_id, btrim(p_reason), previous_state, to_jsonb(lifecycle)
  );

  return query select lifecycle.organization_id, lifecycle.status, lifecycle.restored_at;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.after_insert_on_organizations()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  user_id uuid := auth.uid();
  user_name text;
begin
  insert into public.organizations_addresses (organization_id, service, address)
    values (new.id, 'local', new.id::text);

  insert into public.organization_lifecycle (organization_id)
    values (new.id);

  if user_id is not null then
    select coalesce(raw_user_meta_data->>'full_name', email, '?') into user_name
    from auth.users
    where id = user_id;

    insert into public.agents (organization_id, user_id, name, ai, extra)
    values (new.id, user_id, user_name, false, '{"role": "owner"}');
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.claim_campaign_deliveries(p_limit integer DEFAULT 25)
 RETURNS TABLE(delivery_id uuid, campaign_id uuid, organization_id uuid, organization_address text, contact_address text, contact_name text, variables jsonb, template jsonb, template_variable_mapping jsonb, header_media jsonb, attempts integer)
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
      c.header_media
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
    d.attempts
  from claimed d
  cross join campaign_update c
  order by d.created_at, d.id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_authorized_orgs_by_roles(roles public.role[])
 RETURNS SETOF uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  api_key text;
  org_id uuid;
begin
  -- First, try JWT authentication via auth.uid()
  if auth.uid() is not null then
    return query select agent.organization_id from public.agents agent
    join public.organization_lifecycle lifecycle
      on lifecycle.organization_id = agent.organization_id
      and lifecycle.status = 'active'
    where agent.user_id = auth.uid()
    and (
      agent.extra->'invitation' is null
      or agent.extra->'invitation'->>'status' = 'accepted'
    )
    and agent.extra->>'role' in (
      select allowed_role::text
      from unnest(roles) as allowed_role
    );

    -- Authenticated but lacking the requested role: return the empty set so RLS
    -- subqueries can fall through to other OR-combined policies (e.g. a member
    -- accepting their own invitation while an owner-only policy is also evaluated).
    -- Raising here would short-circuit the whole RLS evaluation.
    -- raise exception using
    --   errcode = '42501',
    --   message = format('insufficient permissions, %s role required', role::text);
    return;
  end if;

  -- Fallback to API key authentication
  api_key := current_setting('request.headers', true)::json->>'api-key';

  if api_key is not null then
    select a.organization_id into org_id
    from public.api_keys a
    join public.organization_lifecycle lifecycle
      on lifecycle.organization_id = a.organization_id
      and lifecycle.status = 'active'
    where a.key = api_key
    and a.role = any(roles);

    if org_id is not null then
      return next org_id;
    end if;
    -- Same reasoning as the JWT branch: invalid key or insufficient role returns
    -- the empty set, not a raise. Validate api-key existence at the request edge
    -- (e.g. a pre-request hook) if you want loud failure for missing/invalid keys.
    -- raise exception using
    --   errcode = '42501',
    --   message = format('invalid api key or insufficient permissions, %s role required', role::text);
    return;
  end if;

  raise exception using
    errcode = '42501',
    message = 'authentication required',
    hint = 'use api-key header or jwt authentication';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_current_human_agent_id(p_organization_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select a.id
  from public.agents a
  where a.organization_id = p_organization_id
    and public.is_organization_active(p_organization_id)
    and a.user_id = auth.uid()
    and a.ai = false
    and (
      a.extra->'invitation' is null
      or a.extra->'invitation'->>'status' = 'accepted'
    )
  limit 1;
$function$
;

CREATE OR REPLACE FUNCTION public.get_platform_overview()
 RETURNS TABLE(organization_count bigint, human_member_count bigint, active_contact_count bigint, active_conversation_count bigint, connected_whatsapp_account_count bigint, connected_instagram_account_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform public.require_platform_admin();

  return query
  select
    (
      select count(*)
      from public.organization_lifecycle lifecycle
      where lifecycle.status = 'active'
    ),
    (
      select count(*)
      from public.agents as agent
      join public.organization_lifecycle lifecycle
        on lifecycle.organization_id = agent.organization_id
        and lifecycle.status = 'active'
      where agent.ai = false
        and agent.user_id is not null
        and (
          agent.extra->'invitation' is null
          or agent.extra->'invitation'->>'status' = 'accepted'
        )
    ),
    (
      select count(*)
      from public.contacts as contact
      join public.organization_lifecycle lifecycle
        on lifecycle.organization_id = contact.organization_id
        and lifecycle.status = 'active'
      where contact.status = 'active'
    ),
    (
      select count(*)
      from public.conversations as conversation
      join public.organization_lifecycle lifecycle
        on lifecycle.organization_id = conversation.organization_id
        and lifecycle.status = 'active'
      where conversation.status = 'active'
    ),
    (
      select count(*)
      from public.organizations_addresses as account
      join public.organization_lifecycle lifecycle
        on lifecycle.organization_id = account.organization_id
        and lifecycle.status = 'active'
      where account.service = 'whatsapp'::public.service
        and account.status = 'connected'
    ),
    (
      select count(*)
      from public.organizations_addresses as account
      join public.organization_lifecycle lifecycle
        on lifecycle.organization_id = account.organization_id
        and lifecycle.status = 'active'
      where account.service = 'instagram'::public.service
        and account.status = 'connected'
    );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_request_organization_role(p_organization_id uuid)
 RETURNS public.role
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  request_role public.role;
  api_key text;
begin
  if not public.is_organization_active(p_organization_id) then
    return null;
  end if;

  if auth.uid() is not null then
    select (a.extra->>'role')::public.role into request_role
    from public.agents a
    where a.organization_id = p_organization_id
      and a.user_id = auth.uid()
      and a.ai = false
      and (
        a.extra->'invitation' is null
        or a.extra->'invitation'->>'status' = 'accepted'
      )
      and a.extra->>'role' in ('owner', 'admin', 'supervisor', 'member', 'agent')
    limit 1;

    return request_role;
  end if;

  api_key := current_setting('request.headers', true)::json->>'api-key';
  if api_key is not null then
    select a.role into request_role
    from public.api_keys a
    where a.organization_id = p_organization_id
      and a.key = api_key;
  end if;

  return request_role;
exception
  when invalid_text_representation then
    return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_platform_organizations_page(p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, organization_name text, organization_created_at timestamp with time zone, organization_updated_at timestamp with time zone, tier_id text, tier_name text, plan_id text, human_member_count bigint, active_contact_count bigint, active_conversation_count bigint, connected_whatsapp_account_count bigint, connected_instagram_account_count bigint, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  normalized_page integer;
  normalized_page_size integer;
  normalized_search text;
begin
  perform public.require_platform_admin();

  normalized_page := greatest(coalesce(p_page, 1), 1);
  normalized_page_size := least(greatest(coalesce(p_page_size, 10), 1), 50);
  normalized_search := lower(btrim(coalesce(p_search, '')));

  return query
  with member_counts as (
    select agent.organization_id, count(*) as value
    from public.agents as agent
    where agent.ai = false
      and agent.user_id is not null
      and (
        agent.extra->'invitation' is null
        or agent.extra->'invitation'->>'status' = 'accepted'
      )
    group by agent.organization_id
  ), contact_counts as (
    select contact.organization_id, count(*) as value
    from public.contacts as contact
    where contact.status = 'active'
    group by contact.organization_id
  ), conversation_counts as (
    select conversation.organization_id, count(*) as value
    from public.conversations as conversation
    where conversation.status = 'active'
    group by conversation.organization_id
  ), account_counts as (
    select
      account.organization_id,
      count(*) filter (
        where account.service = 'whatsapp'::public.service
          and account.status = 'connected'
      ) as whatsapp_count,
      count(*) filter (
        where account.service = 'instagram'::public.service
          and account.status = 'connected'
      ) as instagram_count
    from public.organizations_addresses as account
    group by account.organization_id
  ), organizations_with_metrics as (
    select
      organization.id,
      organization.name,
      organization.created_at,
      organization.updated_at,
      subscription.tier_id,
      tier.name as tier_name,
      subscription.plan_id,
      coalesce(member_count.value, 0) as human_members,
      coalesce(contact_count.value, 0) as active_contacts,
      coalesce(conversation_count.value, 0) as active_conversations,
      coalesce(account_count.whatsapp_count, 0) as whatsapp_accounts,
      coalesce(account_count.instagram_count, 0) as instagram_accounts
    from public.organizations as organization
    join public.organization_lifecycle lifecycle
      on lifecycle.organization_id = organization.id
      and lifecycle.status = 'active'
    left join member_counts as member_count
      on member_count.organization_id = organization.id
    left join contact_counts as contact_count
      on contact_count.organization_id = organization.id
    left join conversation_counts as conversation_count
      on conversation_count.organization_id = organization.id
    left join account_counts as account_count
      on account_count.organization_id = organization.id
    left join billing.subscriptions as subscription
      on subscription.organization_id = organization.id
    left join billing.tiers as tier
      on tier.id = subscription.tier_id
    where normalized_search = ''
      or lower(organization.name) like '%' || normalized_search || '%'
      or organization.id::text like '%' || normalized_search || '%'
  )
  select
    organization.id,
    organization.name,
    organization.created_at,
    organization.updated_at,
    organization.tier_id,
    organization.tier_name,
    organization.plan_id,
    organization.human_members,
    organization.active_contacts,
    organization.active_conversations,
    organization.whatsapp_accounts,
    organization.instagram_accounts,
    count(*) over()
  from organizations_with_metrics as organization
  order by organization.updated_at desc, organization.id desc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.process_auto_assignment_backlog(p_organization_id uuid DEFAULT NULL::uuid, p_routing_queue_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 100, p_source text DEFAULT 'recovery'::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare candidate record; processed integer := 0; result public.conversations;
begin
  for candidate in
    select c.id
    from public.conversations c
    join public.routing_queues q
      on q.organization_id = c.organization_id and q.id = c.routing_queue_id
    join public.organization_automation_settings settings
      on settings.organization_id = c.organization_id
    join public.organization_lifecycle lifecycle
      on lifecycle.organization_id = c.organization_id
      and lifecycle.status = 'active'
    where c.status = 'active' and c.assigned_agent_id is null
      and settings.auto_assign_conversations
      and q.status = 'active' and q.assignment_strategy = 'round_robin'
      and (p_organization_id is null or c.organization_id = p_organization_id)
      and (p_routing_queue_id is null or c.routing_queue_id = p_routing_queue_id)
    order by coalesce(c.routed_at, c.created_at), c.id
    limit least(greatest(coalesce(p_limit, 100), 1), 100)
  loop
    result := public.try_auto_assign_conversation(candidate.id, p_source);
    if result.assigned_agent_id is not null then processed := processed + 1; end if;
  end loop;
  return processed;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.try_auto_assign_conversation(p_conversation_id uuid, p_source text DEFAULT 'recovery'::text)
 RETURNS public.conversations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  conversation_row public.conversations;
  queue_row public.routing_queues;
  selected_agent public.agents;
  last_agent_id uuid;
  assignment_time timestamptz := clock_timestamp();
  assignment_event_id uuid;
begin
  select c.* into conversation_row
  from public.conversations c
  where c.id = p_conversation_id
  for update;

  if not found or conversation_row.status <> 'active'
    or conversation_row.assigned_agent_id is not null
    or conversation_row.routing_queue_id is null then
    return conversation_row;
  end if;

  if not public.is_organization_active(conversation_row.organization_id) then
    return conversation_row;
  end if;

  select q.* into queue_row
  from public.routing_queues q
  join public.organization_automation_settings settings
    on settings.organization_id = q.organization_id
   and settings.auto_assign_conversations
  where q.organization_id = conversation_row.organization_id
    and q.id = conversation_row.routing_queue_id
    and q.status = 'active'
    and q.assignment_strategy = 'round_robin';

  if not found then return conversation_row; end if;

  insert into public.routing_queue_assignment_state (
    organization_id, routing_queue_id
  ) values (conversation_row.organization_id, queue_row.id)
  on conflict (organization_id, routing_queue_id) do nothing;

  select state.last_assigned_agent_id into last_agent_id
  from public.routing_queue_assignment_state state
  where state.organization_id = conversation_row.organization_id
    and state.routing_queue_id = queue_row.id
  for update;

  with eligible as (
    select a.*, row_number() over (order by member.created_at, a.id) as position
    from public.routing_queue_members member
    join public.agents a
      on a.organization_id = member.organization_id and a.id = member.agent_id
    join public.agent_assignment_presence presence
      on presence.organization_id = a.organization_id and presence.agent_id = a.id
    where member.organization_id = conversation_row.organization_id
      and member.routing_queue_id = queue_row.id
      and a.ai = false and a.user_id is not null
      and a.extra->>'role' = 'agent'
      and coalesce(a.extra->'invitation'->>'status', 'accepted') = 'accepted'
      and presence.available
      and presence.last_heartbeat_at >= assignment_time - interval '2 minutes'
  ), cursor_position as (
    select position from eligible where id = last_agent_id
  )
  select e.organization_id, e.user_id, e.id, e.name, e.picture, e.ai,
         e.extra, e.created_at, e.updated_at
  into selected_agent
  from eligible e
  order by
    case when e.position > coalesce((select position from cursor_position), 0) then 0 else 1 end,
    e.position
  limit 1;

  if not found then return conversation_row; end if;

  update public.conversations c
  set assigned_agent_id = selected_agent.id
  where c.id = conversation_row.id
  returning * into conversation_row;

  update public.routing_queue_assignment_state state
  set last_assigned_agent_id = selected_agent.id, updated_at = assignment_time
  where state.organization_id = conversation_row.organization_id
    and state.routing_queue_id = queue_row.id;

  insert into public.conversation_assignment_events (
    organization_id, conversation_id, routing_queue_id, routing_queue_name,
    assigned_agent_id, assigned_agent_name, strategy, source, created_at
  ) values (
    conversation_row.organization_id, conversation_row.id, queue_row.id, queue_row.name,
    selected_agent.id, selected_agent.name, 'round_robin', p_source, assignment_time
  ) returning id into assignment_event_id;

  insert into public.messages (
    organization_id, conversation_id, direction, agent_id, service,
    organization_address, group_address, content, status, timestamp
  ) values (
    conversation_row.organization_id, conversation_row.id, 'internal', null,
    conversation_row.service, conversation_row.organization_address,
    conversation_row.group_address,
    jsonb_build_object(
      'version', '1', 'type', 'text', 'kind', 'assignment_event',
      'text', format('Automatically assigned to %s using Round Robin.', selected_agent.name),
      'assignment_event', jsonb_build_object(
        'id', assignment_event_id, 'agent_id', selected_agent.id,
        'agent_name', selected_agent.name, 'queue_id', queue_row.id,
        'queue_name', queue_row.name, 'strategy', 'round_robin', 'source', p_source
      )
    ), '{}'::jsonb, assignment_time
  );

  perform public.enqueue_user_notification(
    conversation_row.organization_id, selected_agent.id, null,
    conversation_row.id, 'conversation_assigned',
    format('automatic_assignment:%s', assignment_event_id),
    jsonb_build_object(
      'assignment_event_id', assignment_event_id,
      'assigned_agent_id', selected_agent.id,
      'routing_queue_id', queue_row.id,
      'routing_queue_name', queue_row.name,
      'strategy', 'round_robin'
    )
  );

  return conversation_row;
end;
$function$
;



















CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.organization_lifecycle FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');

CREATE TRIGGER prevent_direct_delete BEFORE DELETE ON public.organizations FOR EACH ROW EXECUTE FUNCTION public.prevent_direct_organization_delete();

insert into public.organization_lifecycle (organization_id)
select organization.id
from public.organizations as organization
on conflict (organization_id) do nothing;

revoke all on table public.organization_lifecycle from anon, authenticated;
revoke all on table public.organization_lifecycle_events from anon, authenticated;

revoke execute on function public.is_organization_active(uuid) from public, anon;
grant execute on function public.is_organization_active(uuid) to authenticated, service_role;
revoke execute on function public.archive_organization(uuid, text, text, uuid) from public, anon;
revoke execute on function public.restore_organization(uuid, text, uuid) from public, anon;
revoke execute on function public.list_my_archived_organizations_page(integer, integer, text) from public, anon;
revoke execute on function public.list_platform_organization_lifecycle_page(integer, integer, text, text) from public, anon;
revoke execute on function public.purge_archived_organization(uuid, text, text, uuid, uuid) from public, anon, authenticated;
grant execute on function public.archive_organization(uuid, text, text, uuid) to authenticated;
grant execute on function public.restore_organization(uuid, text, uuid) to authenticated;
grant execute on function public.list_my_archived_organizations_page(integer, integer, text) to authenticated;
grant execute on function public.list_platform_organization_lifecycle_page(integer, integer, text, text) to authenticated;
grant execute on function public.purge_archived_organization(uuid, text, text, uuid, uuid) to service_role;


