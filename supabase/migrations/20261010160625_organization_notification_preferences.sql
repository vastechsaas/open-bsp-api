create table "public"."organization_notification_preferences" (
    "organization_id" uuid not null,
    "notification_type" text not null,
    "enabled" boolean not null default true,
    "updated_at" timestamp with time zone not null default now(),
    "updated_by_user_id" uuid
      );


alter table "public"."organization_notification_preferences" enable row level security;

CREATE UNIQUE INDEX organization_notification_preferences_pkey ON public.organization_notification_preferences USING btree (organization_id, notification_type);

alter table "public"."organization_notification_preferences" add constraint "organization_notification_preferences_pkey" PRIMARY KEY using index "organization_notification_preferences_pkey";

alter table "public"."organization_notification_preferences" add constraint "organization_notification_preferences_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."organization_notification_preferences" validate constraint "organization_notification_preferences_organization_id_fkey";

alter table "public"."organization_notification_preferences" add constraint "organization_notification_preferences_type_check" CHECK ((notification_type = ANY (ARRAY['conversation_assigned'::text, 'conversation_transferred_to_agent'::text, 'conversation_transferred_to_queue'::text, 'private_note_mention'::text]))) not valid;

alter table "public"."organization_notification_preferences" validate constraint "organization_notification_preferences_type_check";

alter table "public"."organization_notification_preferences" add constraint "organization_notification_preferences_updated_by_user_id_fkey" FOREIGN KEY (updated_by_user_id) REFERENCES auth.users(id) ON DELETE SET NULL not valid;

alter table "public"."organization_notification_preferences" validate constraint "organization_notification_preferences_updated_by_user_id_fkey";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.get_organization_notification_preferences(p_organization_id uuid)
 RETURNS TABLE(notification_type text, enabled boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.update_organization_notification_preference(p_organization_id uuid, p_notification_type text, p_enabled boolean)
 RETURNS public.organization_notification_preferences
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.enqueue_user_notification(p_organization_id uuid, p_recipient_agent_id uuid, p_actor_agent_id uuid, p_conversation_id uuid, p_notification_type text, p_source_event_key text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  notification_id uuid;
begin
  if not exists (
    select 1
    from public.agents recipient
    where recipient.organization_id = p_organization_id
      and recipient.id = p_recipient_agent_id
      and recipient.ai = false
      and recipient.user_id is not null
      and recipient.extra->>'role' in (
        'owner',
        'admin',
        'supervisor',
        'member',
        'agent'
      )
      and (
        recipient.extra->'invitation' is null
        or recipient.extra->'invitation'->>'status' = 'accepted'
      )
  ) then
    raise exception using
      errcode = '23514',
      message = 'notification recipient must be an accepted human in the organization';
  end if;

  -- Preferences affect notification delivery only, never the originating action.
  -- An absent row defaults to enabled for both existing and new organizations.
  if not coalesce((
    select preference.enabled
    from public.organization_notification_preferences preference
    where preference.organization_id = p_organization_id
      and preference.notification_type = p_notification_type
  ), true) then
    return null;
  end if;

  insert into public.user_notifications (
    organization_id,
    recipient_agent_id,
    actor_agent_id,
    conversation_id,
    notification_type,
    source_event_key,
    payload
  ) values (
    p_organization_id,
    p_recipient_agent_id,
    p_actor_agent_id,
    p_conversation_id,
    p_notification_type,
    p_source_event_key,
    coalesce(p_payload, '{}'::jsonb)
  )
  on conflict (
    organization_id,
    recipient_agent_id,
    source_event_key
  ) do nothing
  returning id into notification_id;

  if notification_id is null then
    select notification.id into notification_id
    from public.user_notifications notification
    where notification.organization_id = p_organization_id
      and notification.recipient_agent_id = p_recipient_agent_id
      and notification.source_event_key = p_source_event_key;
  end if;

  return notification_id;
end;
$function$
;

grant delete on table "public"."organization_notification_preferences" to "service_role";

grant insert on table "public"."organization_notification_preferences" to "service_role";

grant references on table "public"."organization_notification_preferences" to "service_role";

grant select on table "public"."organization_notification_preferences" to "service_role";

grant trigger on table "public"."organization_notification_preferences" to "service_role";

grant truncate on table "public"."organization_notification_preferences" to "service_role";

grant update on table "public"."organization_notification_preferences" to "service_role";

-- Keep feature privileges aligned with schema sources; exclude unrelated diff revoke noise.
revoke all on table public.organization_notification_preferences from anon, authenticated;
revoke execute on function public.get_organization_notification_preferences(uuid) from public, anon;
revoke execute on function public.update_organization_notification_preference(uuid, text, boolean) from public, anon;
grant execute on function public.get_organization_notification_preferences(uuid) to authenticated;
grant execute on function public.update_organization_notification_preference(uuid, text, boolean) to authenticated;


