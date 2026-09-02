
alter table "public"."platform_admin_action_events" drop constraint "platform_admin_action_events_action_check";

alter table "public"."platform_admin_action_events" drop constraint "platform_admin_action_events_target_check";


  create table "public"."organization_media_storage" (
    "organization_id" uuid not null,
    "quota_bytes" bigint not null default '25000000000'::bigint,
    "used_bytes" bigint not null default 0,
    "object_count" bigint not null default 0,
    "updated_by" uuid,
    "updated_by_scope" text not null default 'system'::text,
    "last_reconciled_at" timestamp with time zone,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."organization_media_storage" enable row level security;

CREATE UNIQUE INDEX organization_media_storage_pkey ON public.organization_media_storage USING btree (organization_id);

CREATE INDEX organization_media_storage_reconciliation_idx ON public.organization_media_storage USING btree (last_reconciled_at NULLS FIRST, organization_id);

CREATE INDEX organization_media_storage_status_idx ON public.organization_media_storage USING btree (quota_bytes, used_bytes DESC, organization_id);

alter table "public"."organization_media_storage" add constraint "organization_media_storage_pkey" PRIMARY KEY using index "organization_media_storage_pkey";

alter table "public"."organization_media_storage" add constraint "organization_media_storage_organization_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."organization_media_storage" validate constraint "organization_media_storage_organization_fkey";

alter table "public"."organization_media_storage" add constraint "organization_media_storage_quota_check" CHECK ((quota_bytes = ANY (ARRAY['25000000000'::bigint, '50000000000'::bigint, '75000000000'::bigint, '100000000000'::bigint]))) not valid;

alter table "public"."organization_media_storage" validate constraint "organization_media_storage_quota_check";

alter table "public"."organization_media_storage" add constraint "organization_media_storage_scope_check" CHECK ((updated_by_scope = ANY (ARRAY['platform'::text, 'system'::text]))) not valid;

alter table "public"."organization_media_storage" validate constraint "organization_media_storage_scope_check";

alter table "public"."organization_media_storage" add constraint "organization_media_storage_updated_by_fkey" FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL not valid;

alter table "public"."organization_media_storage" validate constraint "organization_media_storage_updated_by_fkey";

alter table "public"."organization_media_storage" add constraint "organization_media_storage_usage_check" CHECK (((used_bytes >= 0) AND (object_count >= 0))) not valid;

alter table "public"."organization_media_storage" validate constraint "organization_media_storage_usage_check";

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_action_check" CHECK ((action_type = ANY (ARRAY['routing_queue.create'::text, 'routing_queue.update'::text, 'organization_agent_capacity.update'::text, 'organization_agent.invite'::text, 'organization_agent.update'::text, 'organization_agent.remove'::text, 'organization_automation.update'::text, 'organization_media_storage.quota_update'::text, 'organization_media_storage.reconcile'::text, 'whatsapp.health_check'::text, 'whatsapp.profile_refresh'::text, 'whatsapp.template_sync'::text]))) not valid;

alter table "public"."platform_admin_action_events" validate constraint "platform_admin_action_events_action_check";

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_target_check" CHECK ((((target_type = 'routing_queue'::text) AND (action_type ~~ 'routing_queue.%'::text)) OR ((target_type = 'organization_agent_capacity'::text) AND (action_type = 'organization_agent_capacity.update'::text)) OR ((target_type = 'organization_agent'::text) AND (action_type ~~ 'organization_agent.%'::text)) OR ((target_type = 'organization_automation'::text) AND (action_type = 'organization_automation.update'::text)) OR ((target_type = 'organization_media_storage'::text) AND (action_type ~~ 'organization_media_storage.%'::text)) OR ((target_type = 'whatsapp_account'::text) AND (action_type ~~ 'whatsapp.%'::text)))) not valid;

alter table "public"."platform_admin_action_events" validate constraint "platform_admin_action_events_target_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.apply_organization_media_storage_usage()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  old_organization_id uuid;
  new_organization_id uuid;
  target_organization_id uuid;
  old_size_bytes bigint := 0;
  new_size_bytes bigint := 0;
  size_delta bigint := 0;
  object_delta bigint := 0;
  current_used_bytes bigint;
  configured_quota_bytes bigint;
begin
  if tg_op <> 'INSERT' then
    old_organization_id := public.media_storage_path_organization_id(
      old.bucket_id,
      old.name
    );
    old_size_bytes := public.media_storage_object_size_bytes(old.metadata);
  end if;

  if tg_op <> 'DELETE' then
    new_organization_id := public.media_storage_path_organization_id(
      new.bucket_id,
      new.name
    );
    new_size_bytes := public.media_storage_object_size_bytes(new.metadata);
  end if;

  if old_organization_id is not null
    and new_organization_id is not null
    and old_organization_id <> new_organization_id
  then
    raise exception using
      errcode = '42501',
      message = 'cross-organization media moves are not allowed';
  end if;

  if tg_op = 'INSERT' then
    target_organization_id := new_organization_id;
    size_delta := new_size_bytes;
    object_delta := case when new_organization_id is null then 0 else 1 end;
  elsif tg_op = 'DELETE' then
    target_organization_id := old_organization_id;
    size_delta := -old_size_bytes;
    object_delta := case when old_organization_id is null then 0 else -1 end;
  else
    target_organization_id := coalesce(new_organization_id, old_organization_id);
    size_delta := case
      when old_organization_id is null then new_size_bytes
      when new_organization_id is null then -old_size_bytes
      else new_size_bytes - old_size_bytes
    end;
    object_delta := case
      when old_organization_id is null and new_organization_id is not null then 1
      when old_organization_id is not null and new_organization_id is null then -1
      else 0
    end;
  end if;

  if target_organization_id is null then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  if tg_op <> 'DELETE' and not exists (
    select 1
    from public.organizations organization
    where organization.id = target_organization_id
  ) then
    raise exception using errcode = '23503', message = 'organization not found';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'organization-media-storage:' || target_organization_id::text,
      0
    )
  );

  insert into public.organization_media_storage (organization_id)
  select target_organization_id
  where exists (
    select 1 from public.organizations organization
    where organization.id = target_organization_id
  )
  on conflict (organization_id) do nothing;

  select storage.used_bytes, storage.quota_bytes
  into current_used_bytes, configured_quota_bytes
  from public.organization_media_storage storage
  where storage.organization_id = target_organization_id
  for update;

  if not found then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  if size_delta > 0
    and current_used_bytes + size_delta > configured_quota_bytes
  then
    raise exception using
      errcode = '23514',
      message = 'media storage quota exceeded',
      detail = jsonb_build_object(
        'code', 'media_storage_quota_exceeded',
        'used_bytes', current_used_bytes,
        'quota_bytes', configured_quota_bytes,
        'requested_bytes', size_delta
      )::text;
  end if;

  update public.organization_media_storage storage
  set
    used_bytes = greatest(storage.used_bytes + size_delta, 0),
    object_count = greatest(storage.object_count + object_delta, 0)
  where storage.organization_id = target_organization_id;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_organization_media_storage(p_organization_id uuid)
 RETURNS TABLE(organization_id uuid, quota_bytes bigint, used_bytes bigint, remaining_bytes bigint, object_count bigint, usage_percent numeric, storage_status text, last_reconciled_at timestamp with time zone, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not exists (
    select 1
    from public.get_authorized_orgs('agent'::public.role) authorized(id)
    where authorized.id = p_organization_id
  ) then
    raise exception using errcode = '42501', message = 'organization access required';
  end if;

  return query
  select
    storage.organization_id,
    storage.quota_bytes,
    storage.used_bytes,
    greatest(storage.quota_bytes - storage.used_bytes, 0),
    storage.object_count,
    round(storage.used_bytes * 100.0 / greatest(storage.quota_bytes, 1), 2),
    public.media_storage_status(storage.used_bytes, storage.quota_bytes),
    storage.last_reconciled_at,
    storage.updated_at
  from public.organization_media_storage storage
  where storage.organization_id = p_organization_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_platform_organization_media_storage(p_organization_id uuid)
 RETURNS TABLE(organization_id uuid, organization_name text, quota_bytes bigint, used_bytes bigint, remaining_bytes bigint, object_count bigint, usage_percent numeric, storage_status text, last_reconciled_at timestamp with time zone, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform public.require_platform_admin();

  if not exists (
    select 1 from public.organizations organization
    where organization.id = p_organization_id
  ) then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;

  return query
  select
    organization.id,
    organization.name,
    storage.quota_bytes,
    storage.used_bytes,
    greatest(storage.quota_bytes - storage.used_bytes, 0),
    storage.object_count,
    round(storage.used_bytes * 100.0 / greatest(storage.quota_bytes, 1), 2),
    public.media_storage_status(storage.used_bytes, storage.quota_bytes),
    storage.last_reconciled_at,
    storage.updated_at
  from public.organizations organization
  join public.organization_media_storage storage
    on storage.organization_id = organization.id
  where organization.id = p_organization_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.initialize_organization_media_storage()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  insert into public.organization_media_storage (organization_id)
  values (new.id)
  on conflict (organization_id) do nothing;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_platform_media_storage_page(p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, organization_name text, quota_bytes bigint, used_bytes bigint, remaining_bytes bigint, object_count bigint, usage_percent numeric, storage_status text, last_reconciled_at timestamp with time zone, updated_at timestamp with time zone, total_count bigint)
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

  if normalized_status is not null
    and normalized_status not in ('safe', 'approaching', 'critical')
  then
    raise exception using errcode = '22023', message = 'invalid storage status';
  end if;

  return query
  with storage_rows as (
    select
      organization.id as organization_id,
      organization.name as organization_name,
      storage.quota_bytes,
      storage.used_bytes,
      greatest(storage.quota_bytes - storage.used_bytes, 0) as remaining_bytes,
      storage.object_count,
      round(storage.used_bytes * 100.0 / greatest(storage.quota_bytes, 1), 2)
        as usage_percent,
      public.media_storage_status(storage.used_bytes, storage.quota_bytes)
        as storage_status,
      storage.last_reconciled_at,
      storage.updated_at
    from public.organizations organization
    join public.organization_media_storage storage
      on storage.organization_id = organization.id
    where normalized_search = ''
      or lower(organization.name) like '%' || normalized_search || '%'
      or organization.id::text like '%' || normalized_search || '%'
  ), filtered_rows as (
    select * from storage_rows row
    where normalized_status is null or row.storage_status = normalized_status
  )
  select
    row.organization_id,
    row.organization_name,
    row.quota_bytes,
    row.used_bytes,
    row.remaining_bytes,
    row.object_count,
    row.usage_percent,
    row.storage_status,
    row.last_reconciled_at,
    row.updated_at,
    count(*) over()
  from filtered_rows row
  order by row.organization_name asc, row.organization_id asc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.media_storage_object_size_bytes(p_metadata jsonb)
 RETURNS bigint
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case
    when coalesce(p_metadata->>'size', '') ~ '^[0-9]+$'
      then (p_metadata->>'size')::bigint
    else 0::bigint
  end;
$function$
;

CREATE OR REPLACE FUNCTION public.media_storage_path_organization_id(p_bucket_id text, p_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare
  path_parts text[];
begin
  if p_bucket_id is distinct from 'media' or p_name is null then
    return null;
  end if;

  path_parts := string_to_array(trim(both '/' from p_name), '/');

  if cardinality(path_parts) < 4
    or path_parts[1] <> 'organizations'
    or path_parts[3] <> 'attachments'
    or nullif(path_parts[4], '') is null
  then
    return null;
  end if;

  return path_parts[2]::uuid;
exception
  when invalid_text_representation then
    return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.media_storage_status(p_used_bytes bigint, p_quota_bytes bigint)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case
    when coalesce(p_used_bytes, 0) * 100.0 / greatest(p_quota_bytes, 1) >= 90
      then 'critical'
    when coalesce(p_used_bytes, 0) * 100.0 / greatest(p_quota_bytes, 1) >= 75
      then 'approaching'
    else 'safe'
  end;
$function$
;

CREATE OR REPLACE FUNCTION public.reconcile_organization_media_storage_batch(p_limit integer DEFAULT 100)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  organization_record record;
  reconciled_count integer := 0;
  normalized_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
begin
  for organization_record in
    select storage.organization_id
    from public.organization_media_storage storage
    order by storage.last_reconciled_at asc nulls first, storage.organization_id
    limit normalized_limit
  loop
    perform public.reconcile_organization_media_storage_internal(
      organization_record.organization_id
    );
    reconciled_count := reconciled_count + 1;
  end loop;

  return reconciled_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.reconcile_organization_media_storage_internal(p_organization_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  calculated_used_bytes bigint;
  calculated_object_count bigint;
begin
  if not exists (
    select 1 from public.organizations organization
    where organization.id = p_organization_id
  ) then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('organization-media-storage:' || p_organization_id::text, 0)
  );

  select
    coalesce(sum(public.media_storage_object_size_bytes(object.metadata)), 0),
    count(*)
  into calculated_used_bytes, calculated_object_count
  from storage.objects object
  where public.media_storage_path_organization_id(object.bucket_id, object.name)
    = p_organization_id;

  insert into public.organization_media_storage (
    organization_id,
    used_bytes,
    object_count,
    last_reconciled_at
  ) values (
    p_organization_id,
    calculated_used_bytes,
    calculated_object_count,
    now()
  )
  on conflict (organization_id) do update
  set
    used_bytes = excluded.used_bytes,
    object_count = excluded.object_count,
    last_reconciled_at = excluded.last_reconciled_at;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.reconcile_platform_organization_media_storage(p_organization_id uuid, p_request_id uuid)
 RETURNS TABLE(organization_id uuid, organization_name text, quota_bytes bigint, used_bytes bigint, remaining_bytes bigint, object_count bigint, usage_percent numeric, storage_status text, last_reconciled_at timestamp with time zone, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  authenticated_user_id uuid;
  existing_event public.platform_admin_action_events;
  before_state jsonb;
  after_state jsonb;
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
    if existing_event.action_type <> 'organization_media_storage.reconcile'
      or existing_event.organization_id <> p_organization_id
    then
      raise exception using
        errcode = '22023',
        message = 'request id was already used for a different platform action';
    end if;

    return query
    select * from public.get_platform_organization_media_storage(p_organization_id);
    return;
  end if;

  select jsonb_build_object(
    'used_bytes', storage.used_bytes,
    'object_count', storage.object_count,
    'last_reconciled_at', storage.last_reconciled_at
  ) into before_state
  from public.organization_media_storage storage
  where storage.organization_id = p_organization_id;

  if not found then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;

  perform public.reconcile_organization_media_storage_internal(p_organization_id);

  select jsonb_build_object(
    'used_bytes', storage.used_bytes,
    'object_count', storage.object_count,
    'last_reconciled_at', storage.last_reconciled_at
  ) into after_state
  from public.organization_media_storage storage
  where storage.organization_id = p_organization_id;

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
    p_organization_id,
    'organization_media_storage.reconcile',
    'organization_media_storage',
    p_organization_id::text,
    p_request_id,
    before_state,
    after_state
  );

  return query
  select * from public.get_platform_organization_media_storage(p_organization_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_platform_organization_media_storage_quota(p_organization_id uuid, p_quota_gb integer, p_request_id uuid)
 RETURNS TABLE(organization_id uuid, organization_name text, quota_bytes bigint, used_bytes bigint, remaining_bytes bigint, object_count bigint, usage_percent numeric, storage_status text, last_reconciled_at timestamp with time zone, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  authenticated_user_id uuid;
  configured_quota_bytes bigint;
  existing_event public.platform_admin_action_events;
  before_state jsonb;
  after_state jsonb;
begin
  authenticated_user_id := public.require_platform_admin();

  if p_request_id is null then
    raise exception using errcode = '22023', message = 'request id is required';
  end if;

  if p_quota_gb not in (25, 50, 75, 100) then
    raise exception using errcode = '22023', message = 'invalid media storage quota';
  end if;

  configured_quota_bytes := p_quota_gb::bigint * 1000000000;

  perform pg_advisory_xact_lock(
    hashtextextended(authenticated_user_id::text || ':' || p_request_id::text, 0)
  );

  select * into existing_event
  from public.platform_admin_action_events event
  where event.platform_admin_user_id = authenticated_user_id
    and event.request_id = p_request_id;

  if found then
    if existing_event.action_type <> 'organization_media_storage.quota_update'
      or existing_event.organization_id <> p_organization_id
    then
      raise exception using
        errcode = '22023',
        message = 'request id was already used for a different platform action';
    end if;

    return query
    select * from public.get_platform_organization_media_storage(p_organization_id);
    return;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('organization-media-storage:' || p_organization_id::text, 0)
  );

  select jsonb_build_object(
    'quota_bytes', storage.quota_bytes,
    'used_bytes', storage.used_bytes,
    'object_count', storage.object_count
  ) into before_state
  from public.organization_media_storage storage
  where storage.organization_id = p_organization_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;

  update public.organization_media_storage storage
  set
    quota_bytes = configured_quota_bytes,
    updated_by = authenticated_user_id,
    updated_by_scope = 'platform'
  where storage.organization_id = p_organization_id;

  select jsonb_build_object(
    'quota_bytes', storage.quota_bytes,
    'used_bytes', storage.used_bytes,
    'object_count', storage.object_count,
    'storage_status', public.media_storage_status(
      storage.used_bytes,
      storage.quota_bytes
    )
  ) into after_state
  from public.organization_media_storage storage
  where storage.organization_id = p_organization_id;

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
    p_organization_id,
    'organization_media_storage.quota_update',
    'organization_media_storage',
    p_organization_id::text,
    p_request_id,
    before_state,
    after_state
  );

  return query
  select * from public.get_platform_organization_media_storage(p_organization_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION billing.update_storage_usage()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _org_id uuid;
  _size_gb numeric;
begin
  if tg_op = 'INSERT' then
    _org_id := public.media_storage_path_organization_id(new.bucket_id, new.name);
    if _org_id is null then
      return new;
    end if;
    _size_gb := coalesce((new.metadata->>'size')::numeric, 0) / 1000000000.0;
    perform billing.update_usage(_org_id, 'storage', _size_gb);
    return new;
  elsif tg_op = 'DELETE' then
    _org_id := public.media_storage_path_organization_id(old.bucket_id, old.name);
    if _org_id is null then
      return old;
    end if;
    -- Orphaned object: the org (and its billing rows) was already deleted and the
    -- storage-gc sweep is removing the leftover files. There is no usage to
    -- credit back, so skip accounting to avoid acting on a non-existent org.
    if not exists (select 1 from public.organizations where id = _org_id) then
      return old;
    end if;
    _size_gb := coalesce((old.metadata->>'size')::numeric, 0) / 1000000000.0;
    perform billing.update_usage(_org_id, 'storage', -_size_gb);
    return old;
  end if;

  return coalesce(new, old);
end;
$function$
;

grant references on table "public"."organization_media_storage" to "service_role";

grant trigger on table "public"."organization_media_storage" to "service_role";

grant truncate on table "public"."organization_media_storage" to "service_role";

revoke all on table "public"."organization_media_storage" from "anon", "authenticated";

grant all on table "public"."organization_media_storage" to "service_role";

revoke execute on function public.media_storage_path_organization_id(text, text)
from public, anon, authenticated;
revoke execute on function public.media_storage_object_size_bytes(jsonb)
from public, anon, authenticated;
revoke execute on function public.media_storage_status(bigint, bigint)
from public, anon, authenticated;
revoke execute on function public.initialize_organization_media_storage()
from public, anon, authenticated;
revoke execute on function public.apply_organization_media_storage_usage()
from public, anon, authenticated;
revoke execute on function public.reconcile_organization_media_storage_internal(uuid)
from public, anon, authenticated;
revoke execute on function public.reconcile_organization_media_storage_batch(integer)
from public, anon, authenticated;

revoke execute on function public.get_organization_media_storage(uuid)
from public, anon;
grant execute on function public.get_organization_media_storage(uuid)
to authenticated;

revoke execute on function public.get_platform_organization_media_storage(uuid)
from public, anon;
grant execute on function public.get_platform_organization_media_storage(uuid)
to authenticated;

revoke execute on function public.list_platform_media_storage_page(
  integer,
  integer,
  text,
  text
) from public, anon;
grant execute on function public.list_platform_media_storage_page(
  integer,
  integer,
  text,
  text
) to authenticated;

revoke execute on function public.update_platform_organization_media_storage_quota(
  uuid,
  integer,
  uuid
) from public, anon;
grant execute on function public.update_platform_organization_media_storage_quota(
  uuid,
  integer,
  uuid
) to authenticated;

revoke execute on function public.reconcile_platform_organization_media_storage(
  uuid,
  uuid
) from public, anon;
grant execute on function public.reconcile_platform_organization_media_storage(
  uuid,
  uuid
) to authenticated;

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.organization_media_storage FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');

CREATE TRIGGER initialize_organization_media_storage AFTER INSERT ON public.organizations FOR EACH ROW EXECUTE FUNCTION public.initialize_organization_media_storage();

drop trigger if exists "check_billing_storage_limit" on "storage"."objects";

CREATE TRIGGER apply_organization_media_storage_usage BEFORE INSERT OR DELETE OR UPDATE ON storage.objects FOR EACH ROW EXECUTE FUNCTION public.apply_organization_media_storage_usage();

insert into public.organization_media_storage (organization_id)
select organization.id
from public.organizations organization
on conflict (organization_id) do nothing;

select public.reconcile_organization_media_storage_internal(organization.id)
from public.organizations organization;

select cron.schedule(
  'organization-media-storage-reconcile',
  '17 3 * * *',
  $cron$select public.reconcile_organization_media_storage_batch(100);$cron$
);
