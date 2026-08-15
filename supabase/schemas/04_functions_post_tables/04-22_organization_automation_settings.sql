revoke execute on function public.initialize_organization_automation_settings() from public;
revoke execute on function public.initialize_organization_automation_settings() from anon;
revoke execute on function public.initialize_organization_automation_settings() from authenticated;

create function public.is_whatsapp_contact_auto_save_enabled(
  p_organization_id uuid
) returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(
    (
      select settings.auto_save_whatsapp_contacts
      from public.organization_automation_settings settings
      where settings.organization_id = p_organization_id
    ),
    true
  );
$$;

revoke execute on function public.is_whatsapp_contact_auto_save_enabled(uuid) from public;
revoke execute on function public.is_whatsapp_contact_auto_save_enabled(uuid) from anon;
revoke execute on function public.is_whatsapp_contact_auto_save_enabled(uuid) from authenticated;

create function public.get_organization_automation_settings(
  p_organization_id uuid
) returns public.organization_automation_settings
language plpgsql
stable
security definer
set search_path to ''
as $$
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
$$;

create function public.update_organization_contact_auto_save(
  p_organization_id uuid,
  p_enabled boolean
) returns public.organization_automation_settings
language plpgsql
volatile
security definer
set search_path to ''
as $$
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
$$;

create function public.get_platform_organization_automation_settings(
  p_organization_id uuid
) returns public.organization_automation_settings
language plpgsql
stable
security definer
set search_path to ''
as $$
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
$$;

create function public.update_platform_organization_contact_auto_save(
  p_organization_id uuid,
  p_enabled boolean,
  p_request_id uuid
) returns public.organization_automation_settings
language plpgsql
volatile
security definer
set search_path to ''
as $$
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
$$;

revoke execute on function public.get_organization_automation_settings(uuid) from public;
revoke execute on function public.update_organization_contact_auto_save(uuid, boolean) from public;
revoke execute on function public.get_platform_organization_automation_settings(uuid) from public;
revoke execute on function public.update_platform_organization_contact_auto_save(uuid, boolean, uuid) from public;

grant execute on function public.get_organization_automation_settings(uuid) to authenticated;
grant execute on function public.update_organization_contact_auto_save(uuid, boolean) to authenticated;
grant execute on function public.get_platform_organization_automation_settings(uuid) to authenticated;
grant execute on function public.update_platform_organization_contact_auto_save(uuid, boolean, uuid) to authenticated;
