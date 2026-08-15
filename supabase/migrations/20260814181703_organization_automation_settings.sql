alter table "public"."platform_admin_action_events" drop constraint "platform_admin_action_events_action_check";

alter table "public"."platform_admin_action_events" drop constraint "platform_admin_action_events_target_check";


  create table "public"."organization_automation_settings" (
    "organization_id" uuid not null,
    "auto_save_whatsapp_contacts" boolean not null default true,
    "updated_at" timestamp with time zone not null default now(),
    "updated_by_user_id" uuid,
    "updated_by_scope" text not null default 'system'::text
      );


alter table "public"."organization_automation_settings" enable row level security;

CREATE UNIQUE INDEX organization_automation_settings_pkey ON public.organization_automation_settings USING btree (organization_id);

alter table "public"."organization_automation_settings" add constraint "organization_automation_settings_pkey" PRIMARY KEY using index "organization_automation_settings_pkey";

alter table "public"."organization_automation_settings" add constraint "organization_automation_settings_organization_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."organization_automation_settings" validate constraint "organization_automation_settings_organization_fkey";

alter table "public"."organization_automation_settings" add constraint "organization_automation_settings_scope_check" CHECK ((updated_by_scope = ANY (ARRAY['system'::text, 'organization'::text, 'platform'::text]))) not valid;

alter table "public"."organization_automation_settings" validate constraint "organization_automation_settings_scope_check";

alter table "public"."organization_automation_settings" add constraint "organization_automation_settings_updated_by_user_fkey" FOREIGN KEY (updated_by_user_id) REFERENCES auth.users(id) ON DELETE SET NULL not valid;

alter table "public"."organization_automation_settings" validate constraint "organization_automation_settings_updated_by_user_fkey";

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_action_check" CHECK ((action_type = ANY (ARRAY['routing_queue.create'::text, 'routing_queue.update'::text, 'organization_automation.update'::text, 'whatsapp.health_check'::text, 'whatsapp.profile_refresh'::text, 'whatsapp.template_sync'::text]))) not valid;

alter table "public"."platform_admin_action_events" validate constraint "platform_admin_action_events_action_check";

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_target_check" CHECK ((((target_type = 'routing_queue'::text) AND (action_type ~~ 'routing_queue.%'::text)) OR ((target_type = 'organization_automation'::text) AND (action_type = 'organization_automation.update'::text)) OR ((target_type = 'whatsapp_account'::text) AND (action_type ~~ 'whatsapp.%'::text)))) not valid;

alter table "public"."platform_admin_action_events" validate constraint "platform_admin_action_events_target_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.get_organization_automation_settings(p_organization_id uuid)
 RETURNS public.organization_automation_settings
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  request_role public.role;
  settings public.organization_automation_settings;
begin
  request_role := public.get_request_organization_role(p_organization_id);
  if request_role is null or request_role not in (
    'owner'::public.role,
    'admin'::public.role,
    'supervisor'::public.role
  ) then
    raise exception using
      errcode = '42501',
      message = 'owner, admin, or supervisor role required to manage automation settings';
  end if;

  select current_settings.* into settings
  from public.organization_automation_settings current_settings
  where current_settings.organization_id = p_organization_id;

  if not found then
    raise exception using errcode = 'P0002', message = 'automation settings not found';
  end if;

  return settings;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_platform_organization_automation_settings(p_organization_id uuid)
 RETURNS public.organization_automation_settings
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  settings public.organization_automation_settings;
begin
  perform public.require_platform_admin();

  select current_settings.* into settings
  from public.organization_automation_settings current_settings
  where current_settings.organization_id = p_organization_id;

  if not found then
    raise exception using errcode = 'P0002', message = 'automation settings not found';
  end if;

  return settings;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.initialize_organization_automation_settings()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  insert into public.organization_automation_settings (organization_id)
  values (new.id)
  on conflict (organization_id) do nothing;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.is_whatsapp_contact_auto_save_enabled(p_organization_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(
    (
      select settings.auto_save_whatsapp_contacts
      from public.organization_automation_settings settings
      where settings.organization_id = p_organization_id
    ),
    true
  );
$function$
;

CREATE OR REPLACE FUNCTION public.update_organization_contact_auto_save(p_organization_id uuid, p_enabled boolean)
 RETURNS public.organization_automation_settings
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  request_role public.role;
  updated_settings public.organization_automation_settings;
begin
  request_role := public.get_request_organization_role(p_organization_id);
  if request_role is null or request_role not in (
    'owner'::public.role,
    'admin'::public.role,
    'supervisor'::public.role
  ) then
    raise exception using
      errcode = '42501',
      message = 'owner, admin, or supervisor role required to manage automation settings';
  end if;

  if p_enabled is null then
    raise exception using errcode = '22023', message = 'enabled state is required';
  end if;

  update public.organization_automation_settings settings
  set auto_save_whatsapp_contacts = p_enabled,
      updated_at = now(),
      updated_by_user_id = auth.uid(),
      updated_by_scope = 'organization'
  where settings.organization_id = p_organization_id
  returning * into updated_settings;

  if not found then
    raise exception using errcode = 'P0002', message = 'automation settings not found';
  end if;

  return updated_settings;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_platform_organization_contact_auto_save(p_organization_id uuid, p_enabled boolean, p_request_id uuid)
 RETURNS public.organization_automation_settings
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  authenticated_user_id uuid;
  existing_event public.platform_admin_action_events;
  current_settings public.organization_automation_settings;
  updated_settings public.organization_automation_settings;
  before_state jsonb;
begin
  authenticated_user_id := public.require_platform_admin();

  if p_enabled is null then
    raise exception using errcode = '22023', message = 'enabled state is required';
  end if;
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
    if existing_event.action_type <> 'organization_automation.update'
      or existing_event.organization_id <> p_organization_id
      or existing_event.target_id <> 'contact_auto_save'
    then
      raise exception using
        errcode = '22023',
        message = 'request id was already used for a different platform action';
    end if;

    select settings.* into updated_settings
    from public.organization_automation_settings settings
    where settings.organization_id = p_organization_id;
    return updated_settings;
  end if;

  select settings.* into current_settings
  from public.organization_automation_settings settings
  where settings.organization_id = p_organization_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'automation settings not found';
  end if;

  before_state := jsonb_build_object(
    'auto_save_whatsapp_contacts', current_settings.auto_save_whatsapp_contacts,
    'updated_at', current_settings.updated_at,
    'updated_by_user_id', current_settings.updated_by_user_id,
    'updated_by_scope', current_settings.updated_by_scope
  );

  update public.organization_automation_settings settings
  set auto_save_whatsapp_contacts = p_enabled,
      updated_at = now(),
      updated_by_user_id = authenticated_user_id,
      updated_by_scope = 'platform'
  where settings.organization_id = p_organization_id
  returning * into updated_settings;

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
    'organization_automation.update',
    'organization_automation',
    'contact_auto_save',
    p_request_id,
    before_state,
    jsonb_build_object(
      'auto_save_whatsapp_contacts', updated_settings.auto_save_whatsapp_contacts,
      'updated_at', updated_settings.updated_at,
      'updated_by_user_id', updated_settings.updated_by_user_id,
      'updated_by_scope', updated_settings.updated_by_scope
    )
  );

  return updated_settings;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.manage_contact_on_first_inbound()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  created_contact_id uuid;
  contact_name text;
begin
  -- This trigger runs only on the first real inbound identity transition. A
  -- disabled organization deliberately leaves the address unlinked while the
  -- inbound marker remains set, so enabling later never backfills it.
  if not public.is_whatsapp_contact_auto_save_enabled(new.organization_id) then
    return new;
  end if;

  -- A Meta user_id_update marks the old address with replaced_by_bsuid.
  -- Reuse that Contact before deciding this is a genuinely new customer.
  if nullif(btrim(new.extra->>'bsuid'), '') is not null then
    select address.contact_id
    into created_contact_id
    from public.contacts_addresses as address
    where address.organization_id = new.organization_id
      and address.service = 'whatsapp'::public.service
      and address.address <> new.address
      and address.contact_id is not null
      and address.extra->>'replaced_by_bsuid' = new.extra->>'bsuid'
    order by address.updated_at desc
    limit 1;
  end if;

  if created_contact_id is null then
    contact_name := coalesce(
      nullif(btrim(new.extra->>'name'), ''),
      nullif(btrim(new.extra->>'username'), ''),
      nullif(btrim(new.extra->>'phone_number'), ''),
      new.address
    );

    insert into public.contacts (organization_id, name)
    values (new.organization_id, contact_name)
    returning id into created_contact_id;
  end if;

  if tg_op = 'UPDATE' then
    new.contact_id := created_contact_id;
    return new;
  end if;

  update public.contacts_addresses
  set contact_id = created_contact_id
  where organization_id = new.organization_id
    and address = new.address
    and contact_id is null;

  return new;
end;
$function$
;

grant references on table "public"."organization_automation_settings" to "service_role";

grant trigger on table "public"."organization_automation_settings" to "service_role";

grant truncate on table "public"."organization_automation_settings" to "service_role";

CREATE TRIGGER initialize_organization_automation_settings AFTER INSERT ON public.organizations FOR EACH ROW EXECUTE FUNCTION public.initialize_organization_automation_settings();

insert into public.organization_automation_settings (organization_id)
select organization.id
from public.organizations organization
on conflict (organization_id) do nothing;

revoke all on table public.organization_automation_settings from anon, authenticated;

revoke execute on function public.initialize_organization_automation_settings() from public;
revoke execute on function public.initialize_organization_automation_settings() from anon;
revoke execute on function public.initialize_organization_automation_settings() from authenticated;

revoke execute on function public.is_whatsapp_contact_auto_save_enabled(uuid) from public;
revoke execute on function public.is_whatsapp_contact_auto_save_enabled(uuid) from anon;
revoke execute on function public.is_whatsapp_contact_auto_save_enabled(uuid) from authenticated;

revoke execute on function public.get_organization_automation_settings(uuid) from public;
revoke execute on function public.update_organization_contact_auto_save(uuid, boolean) from public;
revoke execute on function public.get_platform_organization_automation_settings(uuid) from public;
revoke execute on function public.update_platform_organization_contact_auto_save(uuid, boolean, uuid) from public;

grant execute on function public.get_organization_automation_settings(uuid) to authenticated;
grant execute on function public.update_organization_contact_auto_save(uuid, boolean) to authenticated;
grant execute on function public.get_platform_organization_automation_settings(uuid) to authenticated;
grant execute on function public.update_platform_organization_contact_auto_save(uuid, boolean, uuid) to authenticated;


