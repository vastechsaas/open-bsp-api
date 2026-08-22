create or replace function public.list_user_notifications_page(
  p_organization_id uuid,
  p_page integer default 1,
  p_page_size integer default 25,
  p_unread_only boolean default false
)
returns table (
  organization_id uuid,
  id uuid,
  recipient_agent_id uuid,
  actor_agent_id uuid,
  conversation_id uuid,
  notification_type text,
  source_event_key text,
  payload jsonb,
  created_at timestamptz,
  read_at timestamptz,
  resolved_at timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current_agent_id uuid;
  v_page integer;
  v_page_size integer;
  v_offset integer;
begin
  v_current_agent_id :=
    public.get_current_human_agent_id(p_organization_id);

  if v_current_agent_id is null then
    raise exception 'Not authorized';
  end if;

  v_page := greatest(coalesce(p_page, 1), 1);

  v_page_size :=
    least(
      greatest(coalesce(p_page_size, 25), 1),
      50
    );

  v_offset := (v_page - 1) * v_page_size;

  return query
  select
    n.organization_id,
    n.id,
    n.recipient_agent_id,
    n.actor_agent_id,
    n.conversation_id,
    n.notification_type,
    n.source_event_key,
    n.payload,
    n.created_at,
    n.read_at,
    n.resolved_at,
    count(*) over() as total_count
  from public.user_notifications n
  where n.organization_id = p_organization_id
    and n.recipient_agent_id = v_current_agent_id
    and (
      coalesce(p_unread_only, false) = false
      or (
        n.read_at is null
        and n.resolved_at is null
      )
    )
  order by n.created_at desc, n.id desc
  limit v_page_size
  offset v_offset;
end;
$$;

revoke execute on function public.list_user_notifications_page(
  uuid,
  integer,
  integer,
  boolean
) from public, anon;

grant execute on function public.list_user_notifications_page(
  uuid,
  integer,
  integer,
  boolean
) to authenticated;

create or replace function public.get_unread_notification_count(
  p_organization_id uuid
)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_current_agent_id uuid;
  v_unread_count bigint;
begin
  v_current_agent_id :=
    public.get_current_human_agent_id(p_organization_id);

  if v_current_agent_id is null then
    raise exception 'Not authorized';
  end if;

  select count(*)
  into v_unread_count
  from public.user_notifications n
  where n.organization_id = p_organization_id
    and n.recipient_agent_id = v_current_agent_id
    and n.read_at is null
    and n.resolved_at is null;

  return v_unread_count;
end;
$$;

revoke execute on function public.get_unread_notification_count(
  uuid
) from public, anon;

grant execute on function public.get_unread_notification_count(
  uuid
) to authenticated;

create or replace function public.mark_user_notification_read(
  p_notification_id uuid
)
returns public.user_notifications
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_notification public.user_notifications;
begin
  update public.user_notifications n
  set read_at = coalesce(n.read_at, now())
  where n.id = p_notification_id
    and n.recipient_agent_id =
      public.get_current_human_agent_id(n.organization_id)
  returning n.* into v_notification;

  if not found then
    raise exception 'Notification not found or not authorized';
  end if;

  return v_notification;
end;
$$;

revoke execute on function public.mark_user_notification_read(
  uuid
) from public, anon;

grant execute on function public.mark_user_notification_read(
  uuid
) to authenticated;

create or replace function public.mark_all_user_notifications_read(
  p_organization_id uuid
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current_agent_id uuid;
  v_updated_count integer;
begin
  v_current_agent_id :=
    public.get_current_human_agent_id(p_organization_id);

  if v_current_agent_id is null then
    raise exception 'Not authorized';
  end if;

  update public.user_notifications n
  set read_at = now()
  where n.organization_id = p_organization_id
    and n.recipient_agent_id = v_current_agent_id
    and n.read_at is null
    and n.resolved_at is null;

  get diagnostics v_updated_count = row_count;

  return v_updated_count;
end;
$$;

revoke execute on function public.mark_all_user_notifications_read(
  uuid
) from public, anon;

grant execute on function public.mark_all_user_notifications_read(
  uuid
) to authenticated;
