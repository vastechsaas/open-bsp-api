drop policy "owners can create onboarding tokens" on "public"."onboarding_tokens";

-- Catalogue seed is a data migration: schema diff does not emit INSERTs.
-- Privileges are reasserted below because migra omits new-object ACL revokes.

alter table "public"."platform_admin_action_events" drop constraint "platform_admin_action_events_action_check";

alter table "public"."platform_admin_action_events" drop constraint "platform_admin_action_events_target_check";


  create table "public"."integration_catalogue" (
    "id" text not null,
    "name" text not null,
    "default_enabled" boolean not null default false
      );


alter table "public"."integration_catalogue" enable row level security;


  create table "public"."organization_integration_availability" (
    "organization_id" uuid not null,
    "integration_id" text not null,
    "enabled" boolean not null
      );


alter table "public"."organization_integration_availability" enable row level security;


  create table "public"."organization_integration_settings" (
    "organization_id" uuid not null,
    "revision" bigint not null default 0,
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."organization_integration_settings" enable row level security;

CREATE UNIQUE INDEX integration_catalogue_pkey ON public.integration_catalogue USING btree (id);

CREATE UNIQUE INDEX organization_integration_availability_pkey ON public.organization_integration_availability USING btree (organization_id, integration_id);

CREATE UNIQUE INDEX organization_integration_settings_pkey ON public.organization_integration_settings USING btree (organization_id);

alter table "public"."integration_catalogue" add constraint "integration_catalogue_pkey" PRIMARY KEY using index "integration_catalogue_pkey";

alter table "public"."organization_integration_availability" add constraint "organization_integration_availability_pkey" PRIMARY KEY using index "organization_integration_availability_pkey";

alter table "public"."organization_integration_settings" add constraint "organization_integration_settings_pkey" PRIMARY KEY using index "organization_integration_settings_pkey";

alter table "public"."integration_catalogue" add constraint "integration_catalogue_id_check" CHECK ((id ~ '^[a-z][a-z0-9_]{0,63}$'::text)) not valid;

alter table "public"."integration_catalogue" validate constraint "integration_catalogue_id_check";

alter table "public"."organization_integration_availability" add constraint "organization_integration_availability_integration_id_fkey" FOREIGN KEY (integration_id) REFERENCES public.integration_catalogue(id) not valid;

alter table "public"."organization_integration_availability" validate constraint "organization_integration_availability_integration_id_fkey";

alter table "public"."organization_integration_availability" add constraint "organization_integration_availability_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organization_integration_settings(organization_id) ON DELETE CASCADE not valid;

alter table "public"."organization_integration_availability" validate constraint "organization_integration_availability_organization_id_fkey";

alter table "public"."organization_integration_settings" add constraint "organization_integration_settings_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."organization_integration_settings" validate constraint "organization_integration_settings_organization_id_fkey";

alter table "public"."organization_integration_settings" add constraint "organization_integration_settings_revision_check" CHECK ((revision >= 0)) not valid;

alter table "public"."organization_integration_settings" validate constraint "organization_integration_settings_revision_check";

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_action_check" CHECK ((action_type = ANY (ARRAY['routing_queue.create'::text, 'routing_queue.update'::text, 'organization_agent_capacity.update'::text, 'organization_agent.invite'::text, 'organization_agent.update'::text, 'organization_agent.remove'::text, 'organization_member.invite'::text, 'organization_member.update'::text, 'organization_member.remove'::text, 'organization_automation.update'::text, 'organization_module_permissions.update'::text, 'organization_integrations.update'::text, 'organization_media_storage.quota_update'::text, 'organization_media_storage.reconcile'::text, 'whatsapp.health_check'::text, 'whatsapp.profile_refresh'::text, 'whatsapp.template_sync'::text]))) not valid;

alter table "public"."platform_admin_action_events" validate constraint "platform_admin_action_events_action_check";

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_target_check" CHECK ((((target_type = 'routing_queue'::text) AND (action_type ~~ 'routing_queue.%'::text)) OR ((target_type = 'organization_agent_capacity'::text) AND (action_type = 'organization_agent_capacity.update'::text)) OR ((target_type = 'organization_agent'::text) AND (action_type ~~ 'organization_agent.%'::text)) OR ((target_type = 'organization_member'::text) AND (action_type ~~ 'organization_member.%'::text)) OR ((target_type = 'organization_automation'::text) AND (action_type = 'organization_automation.update'::text)) OR ((target_type = 'organization_media_storage'::text) AND (action_type ~~ 'organization_media_storage.%'::text)) OR ((target_type = 'organization_module_permissions'::text) AND (action_type = 'organization_module_permissions.update'::text)) OR ((target_type = 'organization_integrations'::text) AND (action_type = 'organization_integrations.update'::text)) OR ((target_type = 'whatsapp_account'::text) AND (action_type ~~ 'whatsapp.%'::text)))) not valid;

alter table "public"."platform_admin_action_events" validate constraint "platform_admin_action_events_target_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.get_effective_integration_availability(p_organization_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if auth.uid() is null or public.get_request_organization_role(p_organization_id) is null then
    raise exception using errcode = '42501', message = 'Organization access required';
  end if;
  return jsonb_build_object('revision', coalesce((select revision from public.organization_integration_settings where organization_id = p_organization_id), 0),
    'integrations', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name,
      'enabled', coalesce(a.enabled,c.default_enabled)) order by c.id), '[]'::jsonb)
      from public.integration_catalogue c left join public.organization_integration_availability a
      on a.integration_id = c.id and a.organization_id = p_organization_id));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_platform_integration_availability(p_organization_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform public.require_platform_admin();
  if not exists (select 1 from public.organizations where id = p_organization_id) then
    raise exception using errcode = 'P0002', message = 'Organization not found'; end if;
  return jsonb_build_object('revision', coalesce((select revision from public.organization_integration_settings where organization_id = p_organization_id), 0),
    'integrations', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name,
      'enabled', coalesce(a.enabled,c.default_enabled), 'connected_count', coalesce(n.total,0)) order by c.id), '[]'::jsonb)
      from public.integration_catalogue c left join public.organization_integration_availability a
      on a.integration_id = c.id and a.organization_id = p_organization_id
      left join (select service::text as integration_id, count(*) as total from public.organizations_addresses
        where organization_id = p_organization_id and status = 'connected' group by service) n on n.integration_id = c.id));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.is_integration_available(p_organization_id uuid, p_integration_id text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((select coalesce(a.enabled, c.default_enabled)
    from public.integration_catalogue c
    left join public.organization_integration_availability a
      on a.integration_id = c.id and a.organization_id = p_organization_id
    where c.id = p_integration_id
      and (auth.role() = 'service_role' or public.get_request_organization_role(p_organization_id) is not null)), false);
$function$
;

CREATE OR REPLACE FUNCTION public.update_platform_integration_availability(p_organization_id uuid, p_integrations jsonb, p_expected_revision bigint, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid; previous jsonb; result jsonb; existing public.platform_admin_action_events; current_revision bigint;
begin
  actor := public.require_platform_admin();
  if p_request_id is null or p_expected_revision is null or jsonb_typeof(p_integrations) is distinct from 'array' then
    raise exception using errcode = '22023', message = 'Integrations, revision and request ID are required'; end if;
  if jsonb_array_length(p_integrations) <> (select count(*) from public.integration_catalogue)
    or (select count(distinct item->>'id') from jsonb_array_elements(p_integrations) item) <> jsonb_array_length(p_integrations)
    or exists (select 1 from jsonb_array_elements(p_integrations) item
      where jsonb_typeof(item->'enabled') is distinct from 'boolean'
        or not exists (select 1 from public.integration_catalogue c where c.id = item->>'id')) then
    raise exception using errcode = '22023', message = 'Complete supported integration settings required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':' || p_request_id::text, 0));
  select * into existing from public.platform_admin_action_events where platform_admin_user_id = actor and request_id = p_request_id;
  if found then
    if existing.action_type <> 'organization_integrations.update' or existing.organization_id <> p_organization_id
      or existing.after_state->'request_integrations' is distinct from p_integrations
      or (existing.after_state->>'expected_revision')::bigint is distinct from p_expected_revision then
      raise exception using errcode = '22023', message = 'Request ID already used for a different action'; end if;
    return existing.after_state->'result';
  end if;
  insert into public.organization_integration_settings(organization_id) values (p_organization_id) on conflict do nothing;
  select revision into current_revision from public.organization_integration_settings where organization_id = p_organization_id for update;
  if current_revision <> p_expected_revision then raise exception using errcode = '40001', message = 'Integration settings changed. Reload before saving.'; end if;
  previous := public.get_platform_integration_availability(p_organization_id);
  insert into public.organization_integration_availability(organization_id, integration_id, enabled)
    select p_organization_id, item->>'id', (item->>'enabled')::boolean from jsonb_array_elements(p_integrations) item
    on conflict (organization_id,integration_id) do update set enabled = excluded.enabled;
  update public.organization_integration_settings set revision = revision + 1, updated_at = now() where organization_id = p_organization_id;
  result := public.get_platform_integration_availability(p_organization_id);
  insert into public.platform_admin_action_events(platform_admin_user_id, organization_id, action_type, target_type, target_id, request_id, before_state, after_state)
    values (actor,p_organization_id,'organization_integrations.update','organization_integrations',p_organization_id::text,p_request_id,previous,
      jsonb_build_object('result',result,'request_integrations',p_integrations,'expected_revision',p_expected_revision));
  perform realtime.send('{}'::jsonb, 'integration-availability', 'integration-availability:' || p_organization_id::text, true);
  return result;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.prevent_last_owner_deletion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  owner_count int;
begin
  -- Skip check if org is being deleted (cascade delete)
  perform public.lock_organization_team(old.organization_id);
  if not exists (select 1 from public.organizations where id=old.organization_id) then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if old.extra->>'role' = 'owner'
    and coalesce(old.extra->'invitation'->>'status','accepted')='accepted' then
    select count(*) into owner_count
    from public.agents
    where organization_id = old.organization_id
      and extra->>'role' = 'owner'
      and (
        extra->>'invitation' is null
        or extra->'invitation'->>'status' = 'accepted'
      )
      and id <> old.id;

    if owner_count = 0 then
      raise exception 'Cannot delete the last owner of an organization';
    end if;
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$function$
;

grant delete on table "public"."integration_catalogue" to "service_role";

grant insert on table "public"."integration_catalogue" to "service_role";

grant references on table "public"."integration_catalogue" to "service_role";

grant select on table "public"."integration_catalogue" to "service_role";

grant trigger on table "public"."integration_catalogue" to "service_role";

grant truncate on table "public"."integration_catalogue" to "service_role";

grant update on table "public"."integration_catalogue" to "service_role";

grant delete on table "public"."organization_integration_availability" to "service_role";

grant insert on table "public"."organization_integration_availability" to "service_role";

grant references on table "public"."organization_integration_availability" to "service_role";

grant select on table "public"."organization_integration_availability" to "service_role";

grant trigger on table "public"."organization_integration_availability" to "service_role";

grant truncate on table "public"."organization_integration_availability" to "service_role";

grant update on table "public"."organization_integration_availability" to "service_role";

grant delete on table "public"."organization_integration_settings" to "service_role";

grant insert on table "public"."organization_integration_settings" to "service_role";

grant references on table "public"."organization_integration_settings" to "service_role";

grant select on table "public"."organization_integration_settings" to "service_role";

grant trigger on table "public"."organization_integration_settings" to "service_role";

grant truncate on table "public"."organization_integration_settings" to "service_role";

grant update on table "public"."organization_integration_settings" to "service_role";


  create policy "owners can create onboarding tokens"
  on "public"."onboarding_tokens"
  as permissive
  for insert
  to authenticated, anon
with check (((organization_id IN ( SELECT public.get_authorized_orgs('owner'::public.role) AS get_authorized_orgs)) AND public.is_integration_available(organization_id, (service)::text)));



  create policy "organization users receive integration availability changes"
  on "realtime"."messages"
  as permissive
  for select
  to authenticated
using (((extension = 'broadcast'::text) AND (topic = realtime.topic()) AND (EXISTS ( SELECT 1
   FROM public.get_authorized_orgs('agent'::public.role) org(id)
  WHERE (realtime.topic() = ('integration-availability:'::text || (org.id)::text))))));

insert into public.integration_catalogue(id,name,default_enabled)
values ('whatsapp','WhatsApp',true), ('instagram','Instagram',true)
on conflict do nothing;

revoke all on public.integration_catalogue, public.organization_integration_settings, public.organization_integration_availability from anon, authenticated;
grant all on public.integration_catalogue, public.organization_integration_settings, public.organization_integration_availability to service_role;
revoke all on function public.is_integration_available(uuid,text), public.get_effective_integration_availability(uuid), public.get_platform_integration_availability(uuid), public.update_platform_integration_availability(uuid,jsonb,bigint,uuid) from public;
grant execute on function public.is_integration_available(uuid,text) to authenticated, anon, service_role;
grant execute on function public.get_effective_integration_availability(uuid), public.get_platform_integration_availability(uuid), public.update_platform_integration_availability(uuid,jsonb,bigint,uuid) to authenticated;



