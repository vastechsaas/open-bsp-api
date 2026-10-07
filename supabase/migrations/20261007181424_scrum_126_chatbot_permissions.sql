drop policy "admins can create their orgs chatbot deployments" on "public"."chatbot_flow_deployments";

drop policy "admins can delete their orgs chatbot deployments" on "public"."chatbot_flow_deployments";

drop policy "admins can update their orgs chatbot deployments" on "public"."chatbot_flow_deployments";

drop policy "members can read their orgs chatbot deployments" on "public"."chatbot_flow_deployments";

drop policy "members can read their orgs chatbot flow runs" on "public"."chatbot_flow_runs";

drop policy "admins can create chatbot flow drafts" on "public"."chatbot_flow_versions";

drop policy "admins can delete chatbot flow drafts" on "public"."chatbot_flow_versions";

drop policy "admins can update chatbot flow drafts" on "public"."chatbot_flow_versions";

drop policy "members can read their orgs chatbot flow versions" on "public"."chatbot_flow_versions";

drop policy "admins can create their orgs chatbot flows" on "public"."chatbot_flows";

drop policy "admins can delete their orgs unpublished chatbot flows" on "public"."chatbot_flows";

drop policy "admins can update their orgs chatbot flows" on "public"."chatbot_flows";

drop policy "members can read their orgs chatbot flows" on "public"."chatbot_flows";

drop policy "tenant_bridge_read" on "public"."chatbot_node_bridges";

drop policy "admins can read their orgs chatbot webhook credentials" on "public"."chatbot_webhook_credentials";


alter table "public"."platform_admin_action_events" drop constraint "platform_admin_action_events_action_check";

alter table "public"."platform_admin_action_events" drop constraint "platform_admin_action_events_target_check";


  create table "public"."organization_module_permissions" (
    "organization_id" uuid not null,
    "module" text not null,
    "role" public.role not null,
    "can_view" boolean not null,
    "can_manage" boolean not null
      );


alter table "public"."organization_module_permissions" enable row level security;


  create table "public"."organization_module_settings" (
    "organization_id" uuid not null,
    "module" text not null,
    "revision" bigint not null default 0,
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."organization_module_settings" enable row level security;

CREATE UNIQUE INDEX organization_module_permissions_pkey ON public.organization_module_permissions USING btree (organization_id, module, role);

CREATE UNIQUE INDEX organization_module_settings_pkey ON public.organization_module_settings USING btree (organization_id, module);

alter table "public"."organization_module_permissions" add constraint "organization_module_permissions_pkey" PRIMARY KEY using index "organization_module_permissions_pkey";

alter table "public"."organization_module_settings" add constraint "organization_module_settings_pkey" PRIMARY KEY using index "organization_module_settings_pkey";

alter table "public"."organization_module_permissions" add constraint "organization_module_permissions_check" CHECK (((NOT can_manage) OR can_view)) not valid;

alter table "public"."organization_module_permissions" validate constraint "organization_module_permissions_check";

alter table "public"."organization_module_permissions" add constraint "organization_module_permissions_organization_id_module_fkey" FOREIGN KEY (organization_id, module) REFERENCES public.organization_module_settings(organization_id, module) ON DELETE CASCADE not valid;

alter table "public"."organization_module_permissions" validate constraint "organization_module_permissions_organization_id_module_fkey";

alter table "public"."organization_module_settings" add constraint "organization_module_settings_module_check" CHECK ((module = 'chatbot_builder'::text)) not valid;

alter table "public"."organization_module_settings" validate constraint "organization_module_settings_module_check";

alter table "public"."organization_module_settings" add constraint "organization_module_settings_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."organization_module_settings" validate constraint "organization_module_settings_organization_id_fkey";

alter table "public"."organization_module_settings" add constraint "organization_module_settings_revision_check" CHECK ((revision >= 0)) not valid;

alter table "public"."organization_module_settings" validate constraint "organization_module_settings_revision_check";

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_action_check" CHECK ((action_type = ANY (ARRAY['routing_queue.create'::text, 'routing_queue.update'::text, 'organization_agent_capacity.update'::text, 'organization_agent.invite'::text, 'organization_agent.update'::text, 'organization_agent.remove'::text, 'organization_automation.update'::text, 'organization_module_permissions.update'::text, 'organization_media_storage.quota_update'::text, 'organization_media_storage.reconcile'::text, 'whatsapp.health_check'::text, 'whatsapp.profile_refresh'::text, 'whatsapp.template_sync'::text]))) not valid;

alter table "public"."platform_admin_action_events" validate constraint "platform_admin_action_events_action_check";

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_target_check" CHECK ((((target_type = 'routing_queue'::text) AND (action_type ~~ 'routing_queue.%'::text)) OR ((target_type = 'organization_agent_capacity'::text) AND (action_type = 'organization_agent_capacity.update'::text)) OR ((target_type = 'organization_agent'::text) AND (action_type ~~ 'organization_agent.%'::text)) OR ((target_type = 'organization_automation'::text) AND (action_type = 'organization_automation.update'::text)) OR ((target_type = 'organization_media_storage'::text) AND (action_type ~~ 'organization_media_storage.%'::text)) OR ((target_type = 'organization_module_permissions'::text) AND (action_type = 'organization_module_permissions.update'::text)) OR ((target_type = 'whatsapp_account'::text) AND (action_type ~~ 'whatsapp.%'::text)))) not valid;

alter table "public"."platform_admin_action_events" validate constraint "platform_admin_action_events_target_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.get_effective_module_permissions(p_organization_id uuid, p_module text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'Authentication required'; end if;
  if p_module is distinct from 'chatbot_builder' then raise exception using errcode = '22023', message = 'Unsupported module'; end if;
  if public.get_request_organization_role(p_organization_id) is null then
    return jsonb_build_object('can_view', false, 'can_manage', false, 'revision', 0);
  end if;
  return jsonb_build_object('can_view', public.has_module_permission(p_organization_id, p_module, 'view'),
    'can_manage', public.has_module_permission(p_organization_id, p_module, 'manage'),
    'revision', coalesce((select revision from public.organization_module_settings where organization_id = p_organization_id and module = p_module), 0));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_platform_module_permissions(p_organization_id uuid, p_module text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform public.require_platform_admin();
  if p_module is distinct from 'chatbot_builder' then raise exception using errcode = '22023', message = 'Unsupported module'; end if;
  if not exists (select 1 from public.organizations where id = p_organization_id) then
    raise exception using errcode = 'P0002', message = 'Organization not found'; end if;
  return jsonb_build_object('revision', coalesce((select revision from public.organization_module_settings where organization_id = p_organization_id and module = p_module), 0),
    'permissions', (select jsonb_agg(jsonb_build_object('role', r.role, 'can_view', coalesce(p.can_view, r.role in ('owner','admin','supervisor','member')),
    'can_manage', coalesce(p.can_manage, r.role in ('owner','admin'))) order by r.ordinal)
    from unnest(array['owner','admin','supervisor','member','agent']::public.role[]) with ordinality r(role, ordinal)
    left join public.organization_module_permissions p on p.organization_id = p_organization_id and p.module = p_module and p.role = r.role));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.has_module_permission(p_organization_id uuid, p_module text, p_permission text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor_role public.role; permission_value boolean;
begin
  if p_module is distinct from 'chatbot_builder' or p_permission is null or p_permission not in ('view', 'manage') then return false; end if;
  actor_role := public.get_request_organization_role(p_organization_id);
  if actor_role is null then return false; end if;
  select case when p_permission = 'view' then p.can_view else p.can_manage end
    into permission_value from public.organization_module_permissions p
    where p.organization_id = p_organization_id and p.module = p_module and p.role = actor_role;
  return coalesce(permission_value, case when p_permission = 'view'
    then actor_role in ('owner', 'admin', 'supervisor', 'member') else actor_role in ('owner', 'admin') end);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_platform_module_permissions(p_organization_id uuid, p_module text, p_permissions jsonb, p_expected_revision bigint, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid; previous jsonb; result jsonb; existing public.platform_admin_action_events; current_revision bigint;
begin
  actor := public.require_platform_admin();
  if p_module is distinct from 'chatbot_builder' or p_request_id is null or p_expected_revision is null then
    raise exception using errcode = '22023', message = 'Module, revision and request ID are required'; end if;
  if jsonb_typeof(p_permissions) is distinct from 'array' then raise exception using errcode = '22023', message = 'Complete permission matrix required'; end if;
  if jsonb_array_length(p_permissions) <> 5 or
    (select count(distinct item->>'role') from jsonb_array_elements(p_permissions) item where item->>'role' in ('owner','admin','supervisor','member','agent')) <> 5 or
    exists (select 1 from jsonb_array_elements(p_permissions) item where jsonb_typeof(item->'can_view') is distinct from 'boolean'
      or jsonb_typeof(item->'can_manage') is distinct from 'boolean'
      or (item->'can_manage' = 'true'::jsonb and item->'can_view' <> 'true'::jsonb)) then
    raise exception using errcode = '22023', message = 'Five unique roles and valid View/Manage flags are required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':' || p_request_id::text, 0));
  select * into existing from public.platform_admin_action_events where platform_admin_user_id = actor and request_id = p_request_id;
  if found then
    if existing.action_type <> 'organization_module_permissions.update' or existing.organization_id <> p_organization_id or existing.target_id <> p_module
      or existing.after_state->'request_permissions' <> p_permissions or (existing.after_state->>'expected_revision')::bigint <> p_expected_revision then
      raise exception using errcode = '22023', message = 'Request ID already used for a different action'; end if;
    return existing.after_state->'result';
  end if;
  insert into public.organization_module_settings (organization_id, module) values (p_organization_id, p_module) on conflict do nothing;
  select revision into current_revision from public.organization_module_settings where organization_id = p_organization_id and module = p_module for update;
  if current_revision <> p_expected_revision then raise exception using errcode = '40001', message = 'Permissions changed. Reload before saving.'; end if;
  previous := public.get_platform_module_permissions(p_organization_id, p_module);
  insert into public.organization_module_permissions (organization_id, module, role, can_view, can_manage)
    select p_organization_id, p_module, (item->>'role')::public.role, (item->>'can_view')::boolean, (item->>'can_manage')::boolean
    from jsonb_array_elements(p_permissions) item
    on conflict (organization_id,module,role) do update set can_view = excluded.can_view, can_manage = excluded.can_manage;
  update public.organization_module_settings set revision = revision + 1, updated_at = now() where organization_id = p_organization_id and module = p_module;
  result := public.get_platform_module_permissions(p_organization_id, p_module);
  insert into public.platform_admin_action_events (platform_admin_user_id, organization_id, action_type, target_type, target_id, request_id, before_state, after_state)
    values (actor, p_organization_id, 'organization_module_permissions.update', 'organization_module_permissions', p_module, p_request_id, previous,
      jsonb_build_object('result',result,'request_permissions',p_permissions,'expected_revision',p_expected_revision));
  perform realtime.send(jsonb_build_object('module', p_module), 'module-permissions', 'module-permissions:' || p_organization_id::text, true);
  return result;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_chatbot_flows_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, id uuid, created_by uuid, created_by_name text, name text, status text, created_at timestamp with time zone, updated_at timestamp with time zone, draft_id uuid, draft_version integer, draft_updated_at timestamp with time zone, published_version_id uuid, published_version integer, published_at timestamp with time zone, has_unpublished_changes boolean, total_count bigint)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  normalized_page integer;
  normalized_page_size integer;
  normalized_search text;
  normalized_status text;
begin
  if not public.has_module_permission(p_organization_id, 'chatbot_builder', 'view') then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  normalized_page := greatest(coalesce(p_page, 1), 1);
  normalized_page_size := least(
    greatest(coalesce(p_page_size, 10), 1),
    50
  );
  normalized_search := lower(btrim(coalesce(p_search, '')));
  normalized_status := nullif(lower(btrim(coalesce(p_status, ''))), '');

  if normalized_status is not null
    and normalized_status not in ('active', 'archived')
  then
    raise exception using
      errcode = '22023',
      message = 'chatbot flow status filter is invalid';
  end if;

  return query
  with listed as materialized (
    select
      flow.organization_id,
      flow.id,
      flow.created_by,
      creator.name as created_by_name,
      flow.name,
      flow.status,
      flow.created_at,
      greatest(
        flow.updated_at,
        coalesce(draft.updated_at, flow.updated_at),
        coalesce(published.updated_at, flow.updated_at)
      ) as updated_at,
      draft.id as draft_id,
      draft.version as draft_version,
      draft.updated_at as draft_updated_at,
      published.id as published_version_id,
      published.version as published_version,
      published.published_at,
      case
        when draft.id is null then false
        when published.id is null then true
        else draft.editor_graph is distinct from published.editor_graph
      end as has_unpublished_changes
    from public.chatbot_flows as flow
    left join public.agents as creator
      on creator.organization_id = flow.organization_id
      and creator.id = flow.created_by
    left join lateral (
      select
        version.id,
        version.version,
        version.editor_graph,
        version.updated_at
      from public.chatbot_flow_versions as version
      where version.organization_id = flow.organization_id
        and version.flow_id = flow.id
        and version.status = 'draft'
      order by version.version desc, version.id desc
      limit 1
    ) as draft on true
    left join lateral (
      select
        version.id,
        version.version,
        version.editor_graph,
        version.published_at,
        version.updated_at
      from public.chatbot_flow_versions as version
      where version.organization_id = flow.organization_id
        and version.flow_id = flow.id
        and version.status = 'published'
      order by version.version desc, version.id desc
      limit 1
    ) as published on true
    where flow.organization_id = p_organization_id
      and (
        normalized_status is null
        or flow.status = normalized_status
      )
      and (
        normalized_search = ''
        or position(normalized_search in lower(flow.name)) > 0
      )
  )
  select
    listed.organization_id,
    listed.id,
    listed.created_by,
    listed.created_by_name,
    listed.name,
    listed.status,
    listed.created_at,
    listed.updated_at,
    listed.draft_id,
    listed.draft_version,
    listed.draft_updated_at,
    listed.published_version_id,
    listed.published_version,
    listed.published_at,
    listed.has_unpublished_changes,
    count(*) over() as total_count
  from listed
  order by listed.updated_at desc, listed.id desc
  offset (normalized_page - 1) * normalized_page_size
  limit normalized_page_size;
end;
$function$
;

grant delete on table "public"."organization_module_permissions" to "service_role";

grant insert on table "public"."organization_module_permissions" to "service_role";

grant references on table "public"."organization_module_permissions" to "service_role";

grant select on table "public"."organization_module_permissions" to "service_role";

grant trigger on table "public"."organization_module_permissions" to "service_role";

grant truncate on table "public"."organization_module_permissions" to "service_role";

grant update on table "public"."organization_module_permissions" to "service_role";

grant delete on table "public"."organization_module_settings" to "service_role";

grant insert on table "public"."organization_module_settings" to "service_role";

grant references on table "public"."organization_module_settings" to "service_role";

grant select on table "public"."organization_module_settings" to "service_role";

grant trigger on table "public"."organization_module_settings" to "service_role";

grant truncate on table "public"."organization_module_settings" to "service_role";

grant update on table "public"."organization_module_settings" to "service_role";


  create policy "admins can create their orgs chatbot deployments"
  on "public"."chatbot_flow_deployments"
  as permissive
  for insert
  to authenticated, anon
with check (public.has_module_permission(organization_id, 'chatbot_builder'::text, 'manage'::text));



  create policy "admins can delete their orgs chatbot deployments"
  on "public"."chatbot_flow_deployments"
  as permissive
  for delete
  to authenticated, anon
using (public.has_module_permission(organization_id, 'chatbot_builder'::text, 'manage'::text));



  create policy "admins can update their orgs chatbot deployments"
  on "public"."chatbot_flow_deployments"
  as permissive
  for update
  to authenticated, anon
using (public.has_module_permission(organization_id, 'chatbot_builder'::text, 'manage'::text))
with check (public.has_module_permission(organization_id, 'chatbot_builder'::text, 'manage'::text));



  create policy "members can read their orgs chatbot deployments"
  on "public"."chatbot_flow_deployments"
  as permissive
  for select
  to authenticated, anon
using (public.has_module_permission(organization_id, 'chatbot_builder'::text, 'view'::text));



  create policy "members can read their orgs chatbot flow runs"
  on "public"."chatbot_flow_runs"
  as permissive
  for select
  to authenticated, anon
using (public.has_module_permission(organization_id, 'chatbot_builder'::text, 'view'::text));



  create policy "admins can create chatbot flow drafts"
  on "public"."chatbot_flow_versions"
  as permissive
  for insert
  to authenticated, anon
with check ((public.has_module_permission(organization_id, 'chatbot_builder'::text, 'manage'::text) AND (status = 'draft'::text)));



  create policy "admins can delete chatbot flow drafts"
  on "public"."chatbot_flow_versions"
  as permissive
  for delete
  to authenticated, anon
using ((public.has_module_permission(organization_id, 'chatbot_builder'::text, 'manage'::text) AND (status = 'draft'::text)));



  create policy "admins can update chatbot flow drafts"
  on "public"."chatbot_flow_versions"
  as permissive
  for update
  to authenticated, anon
using ((public.has_module_permission(organization_id, 'chatbot_builder'::text, 'manage'::text) AND (status = 'draft'::text)))
with check ((public.has_module_permission(organization_id, 'chatbot_builder'::text, 'manage'::text) AND (status = 'draft'::text)));



  create policy "members can read their orgs chatbot flow versions"
  on "public"."chatbot_flow_versions"
  as permissive
  for select
  to authenticated, anon
using (public.has_module_permission(organization_id, 'chatbot_builder'::text, 'view'::text));



  create policy "admins can create their orgs chatbot flows"
  on "public"."chatbot_flows"
  as permissive
  for insert
  to authenticated, anon
with check (public.has_module_permission(organization_id, 'chatbot_builder'::text, 'manage'::text));



  create policy "admins can delete their orgs unpublished chatbot flows"
  on "public"."chatbot_flows"
  as permissive
  for delete
  to authenticated, anon
using ((public.has_module_permission(organization_id, 'chatbot_builder'::text, 'manage'::text) AND (NOT (EXISTS ( SELECT 1
   FROM public.chatbot_flow_versions version
  WHERE ((version.flow_id = chatbot_flows.id) AND (version.status = 'published'::text)))))));



  create policy "admins can update their orgs chatbot flows"
  on "public"."chatbot_flows"
  as permissive
  for update
  to authenticated, anon
using (public.has_module_permission(organization_id, 'chatbot_builder'::text, 'manage'::text))
with check (public.has_module_permission(organization_id, 'chatbot_builder'::text, 'manage'::text));



  create policy "members can read their orgs chatbot flows"
  on "public"."chatbot_flows"
  as permissive
  for select
  to authenticated, anon
using (public.has_module_permission(organization_id, 'chatbot_builder'::text, 'view'::text));



  create policy "tenant_bridge_read"
  on "public"."chatbot_node_bridges"
  as permissive
  for select
  to authenticated
using (public.has_module_permission(organization_id, 'chatbot_builder'::text, 'view'::text));



  create policy "admins can read their orgs chatbot webhook credentials"
  on "public"."chatbot_webhook_credentials"
  as permissive
  for select
  to authenticated, anon
using (public.has_module_permission(organization_id, 'chatbot_builder'::text, 'view'::text));



  create policy "accepted organization humans receive module permission changes"
  on "realtime"."messages"
  as permissive
  for select
  to authenticated
using (((extension = 'broadcast'::text) AND (topic = realtime.topic()) AND (EXISTS ( SELECT 1
   FROM public.get_authorized_orgs('agent'::public.role) org(id)
  WHERE (realtime.topic() = ('module-permissions:'::text || (org.id)::text))))));

revoke all on function public.has_module_permission(uuid,text,text) from public;
revoke all on public.organization_module_settings, public.organization_module_permissions from anon, authenticated;
grant all on public.organization_module_settings, public.organization_module_permissions to service_role;
grant execute on function public.has_module_permission(uuid,text,text) to authenticated, anon, service_role;
revoke all on function public.get_effective_module_permissions(uuid,text), public.get_platform_module_permissions(uuid,text), public.update_platform_module_permissions(uuid,text,jsonb,bigint,uuid) from public;
grant execute on function public.get_effective_module_permissions(uuid,text), public.get_platform_module_permissions(uuid,text), public.update_platform_module_permissions(uuid,text,jsonb,bigint,uuid) to authenticated;
