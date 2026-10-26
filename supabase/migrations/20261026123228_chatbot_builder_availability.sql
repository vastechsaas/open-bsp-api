drop function if exists "public"."update_platform_module_permissions"(p_organization_id uuid, p_module text, p_permissions jsonb, p_expected_revision bigint, p_request_id uuid);

alter table "public"."organization_module_settings" add column "enabled" boolean not null default true;

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.update_platform_module_permissions(p_organization_id uuid, p_module text, p_permissions jsonb, p_expected_revision bigint, p_request_id uuid, p_enabled boolean DEFAULT NULL::boolean)
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
      or existing.after_state->'request_permissions' <> p_permissions or (existing.after_state->>'expected_revision')::bigint <> p_expected_revision
      or existing.after_state->>'request_enabled' is distinct from p_enabled::text then
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
  update public.organization_module_settings set enabled=coalesce(p_enabled,enabled), revision = revision + 1, updated_at = now() where organization_id = p_organization_id and module = p_module;
  result := public.get_platform_module_permissions(p_organization_id, p_module);
  insert into public.platform_admin_action_events (platform_admin_user_id, organization_id, action_type, target_type, target_id, request_id, before_state, after_state)
    values (actor, p_organization_id, 'organization_module_permissions.update', 'organization_module_permissions', p_module, p_request_id, previous,
      jsonb_build_object('result',result,'request_permissions',p_permissions,'expected_revision',p_expected_revision,'request_enabled',p_enabled));
  perform realtime.send(jsonb_build_object('module', p_module), 'module-permissions', 'module-permissions:' || p_organization_id::text, true);
  return result;
end;
$function$
;

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
    return jsonb_build_object('enabled', false, 'can_view', false, 'can_manage', false, 'revision', 0);
  end if;
  return jsonb_build_object('enabled', coalesce((select enabled from public.organization_module_settings where organization_id=p_organization_id and module=p_module),true),
    'can_view', public.has_module_permission(p_organization_id, p_module, 'view'),
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
  return jsonb_build_object('enabled', coalesce((select enabled from public.organization_module_settings where organization_id=p_organization_id and module=p_module),true),
    'revision', coalesce((select revision from public.organization_module_settings where organization_id = p_organization_id and module = p_module), 0),
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
  if not coalesce((select enabled from public.organization_module_settings where organization_id=p_organization_id and module=p_module),true) then return false; end if;
  select case when p_permission = 'view' then p.can_view else p.can_manage end
    into permission_value from public.organization_module_permissions p
    where p.organization_id = p_organization_id and p.module = p_module and p.role = actor_role;
  return coalesce(permission_value, case when p_permission = 'view'
    then actor_role in ('owner', 'admin', 'supervisor', 'member') else actor_role in ('owner', 'admin') end);
end;
$function$
;

revoke all on function public.update_platform_module_permissions(uuid,text,jsonb,bigint,uuid,boolean) from public;
grant execute on function public.update_platform_module_permissions(uuid,text,jsonb,bigint,uuid,boolean) to authenticated;


