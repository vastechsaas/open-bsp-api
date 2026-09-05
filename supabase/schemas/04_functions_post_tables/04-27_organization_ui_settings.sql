revoke execute on function public.initialize_organization_ui_settings() from public;
revoke execute on function public.initialize_organization_ui_settings() from anon;
revoke execute on function public.initialize_organization_ui_settings() from authenticated;

create function public.get_organization_ui_settings(
  p_organization_id uuid
) returns public.organization_ui_settings
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  settings public.organization_ui_settings;
begin
  if public.get_request_organization_role(p_organization_id) is null then
    raise exception using
      errcode = '42501',
      message = 'accepted organization membership required to read appearance settings';
  end if;

  select current_settings.* into settings
  from public.organization_ui_settings current_settings
  where current_settings.organization_id = p_organization_id;

  if not found then
    raise exception using errcode = 'P0002', message = 'appearance settings not found';
  end if;

  return settings;
end;
$$;

create function public.update_organization_chat_bubble_theme(
  p_organization_id uuid,
  p_theme text
) returns public.organization_ui_settings
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  request_role public.role;
  updated_settings public.organization_ui_settings;
begin
  request_role := public.get_request_organization_role(p_organization_id);
  if request_role is null or request_role not in (
    'owner'::public.role,
    'admin'::public.role,
    'supervisor'::public.role
  ) then
    raise exception using
      errcode = '42501',
      message = 'owner, admin, or supervisor role required to manage appearance settings';
  end if;

  if p_theme is null or p_theme not in ('orange', 'green', 'blue', 'purple', 'teal') then
    raise exception using errcode = '22023', message = 'invalid chat bubble theme';
  end if;

  update public.organization_ui_settings settings
  set chat_bubble_theme = p_theme,
      updated_at = now(),
      updated_by_user_id = auth.uid(),
      updated_by_scope = 'organization'
  where settings.organization_id = p_organization_id
  returning * into updated_settings;

  if not found then
    raise exception using errcode = 'P0002', message = 'appearance settings not found';
  end if;

  return updated_settings;
end;
$$;

revoke execute on function public.get_organization_ui_settings(uuid) from public;
revoke execute on function public.update_organization_chat_bubble_theme(uuid, text) from public;

grant execute on function public.get_organization_ui_settings(uuid) to authenticated;
grant execute on function public.update_organization_chat_bubble_theme(uuid, text) to authenticated;
