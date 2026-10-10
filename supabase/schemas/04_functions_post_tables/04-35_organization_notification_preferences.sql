create function public.get_organization_notification_preferences(
  p_organization_id uuid
) returns table (notification_type text, enabled boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null
    or public.get_request_organization_role(p_organization_id) is distinct from 'owner'::public.role
  then
    raise exception using errcode = '42501', message = 'organization owner role required';
  end if;

  return query
  select supported.notification_type, coalesce(preference.enabled, true)
  from (values
    ('conversation_assigned', 1),
    ('conversation_transferred_to_agent', 2),
    ('conversation_transferred_to_queue', 3),
    ('private_note_mention', 4)
  ) as supported(notification_type, position)
  left join public.organization_notification_preferences preference
    on preference.organization_id = p_organization_id
    and preference.notification_type = supported.notification_type
  order by supported.position;
end;
$$;

create function public.update_organization_notification_preference(
  p_organization_id uuid,
  p_notification_type text,
  p_enabled boolean
) returns public.organization_notification_preferences
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  preference public.organization_notification_preferences;
begin
  if auth.uid() is null
    or public.get_request_organization_role(p_organization_id) is distinct from 'owner'::public.role
  then
    raise exception using errcode = '42501', message = 'organization owner role required';
  end if;

  if p_enabled is null then
    raise exception using errcode = '22023', message = 'enabled state is required';
  end if;
  if p_notification_type is null or p_notification_type not in (
    'conversation_assigned',
    'conversation_transferred_to_agent',
    'conversation_transferred_to_queue',
    'private_note_mention'
  ) then
    raise exception using errcode = '22023', message = 'unsupported notification type';
  end if;

  -- Updating a single type avoids overwriting another owner's unrelated toggle.
  insert into public.organization_notification_preferences (
    organization_id, notification_type, enabled, updated_by_user_id
  ) values (
    p_organization_id, p_notification_type, p_enabled, auth.uid()
  )
  on conflict (organization_id, notification_type) do update
  set enabled = excluded.enabled,
      updated_at = clock_timestamp(),
      updated_by_user_id = excluded.updated_by_user_id
  returning * into preference;

  return preference;
end;
$$;

revoke execute on function public.get_organization_notification_preferences(uuid) from public, anon;
revoke execute on function public.update_organization_notification_preference(uuid, text, boolean) from public, anon;
grant execute on function public.get_organization_notification_preferences(uuid) to authenticated;
grant execute on function public.update_organization_notification_preference(uuid, text, boolean) to authenticated;
