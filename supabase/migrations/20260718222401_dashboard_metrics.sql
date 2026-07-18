CREATE INDEX contacts_organization_id_created_at_idx ON public.contacts USING btree (organization_id, created_at DESC);

CREATE INDEX conversations_organization_id_status_idx ON public.conversations USING btree (organization_id, status);

CREATE INDEX messages_organization_id_timestamp_idx ON public.messages USING btree (organization_id, "timestamp" DESC);

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.get_dashboard_metrics(p_organization_id uuid, p_days integer DEFAULT 7)
 RETURNS TABLE(period_start date, period_end date, total_contacts bigint, active_today bigint, active_last_7_days bigint, active_last_30_days bigint, new_contacts bigint, open_conversations bigint, unassigned_conversations bigint, closed_conversations bigint, contact_activity jsonb, message_activity jsonb, team_snapshot jsonb)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  normalized_days integer;
  selected_start date;
begin
  if not exists (
    select 1
    from public.get_authorized_orgs('member') as authorized_orgs(id)
    where authorized_orgs.id = p_organization_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  normalized_days := coalesce(p_days, 7);
  if normalized_days not in (7, 30) then
    raise exception using
      errcode = '22023',
      message = 'dashboard period must be 7 or 30 days';
  end if;

  selected_start := current_date - (normalized_days - 1);

  return query
  with message_contacts as materialized (
    select
      contact_address.contact_id,
      (message.timestamp at time zone 'UTC')::date as activity_date
    from public.messages message
    join public.conversations conversation
      on conversation.organization_id = message.organization_id
      and conversation.id = message.conversation_id
    join public.contacts_addresses contact_address
      on contact_address.organization_id = conversation.organization_id
      and contact_address.address = conversation.contact_address
      and contact_address.contact_id is not null
    where message.organization_id = p_organization_id
      and message.timestamp >= current_date - interval '29 days'
  ), days as (
    select generate_series(
      selected_start,
      current_date,
      interval '1 day'
    )::date as day
  ), contact_series as (
    select
      day.day,
      (
        select count(distinct activity.contact_id)
        from message_contacts activity
        where activity.activity_date = day.day
      ) as active_contacts,
      (
        select count(*)
        from public.contacts contact
        where contact.organization_id = p_organization_id
          and contact.status = 'active'
          and (contact.created_at at time zone 'UTC')::date = day.day
      ) as new_contacts
    from days day
  ), message_series as (
    select
      day.day,
      (
        select count(*)
        from public.messages message
        where message.organization_id = p_organization_id
          and message.direction = 'outgoing'::public.direction
          and (message.timestamp at time zone 'UTC')::date = day.day
      ) as sent,
      (
        select count(*)
        from public.messages message
        where message.organization_id = p_organization_id
          and message.direction = 'incoming'::public.direction
          and (message.timestamp at time zone 'UTC')::date = day.day
      ) as received
    from days day
  ), team_counts as (
    select
      agent.id,
      agent.name,
      agent.picture,
      count(conversation.id) as assigned,
      count(conversation.id) filter (
        where conversation.status = 'active'
      ) as open,
      count(conversation.id) filter (
        where conversation.status = 'closed'
      ) as closed
    from public.agents agent
    left join public.conversations conversation
      on conversation.organization_id = agent.organization_id
      and conversation.assigned_agent_id = agent.id
    where agent.organization_id = p_organization_id
      and agent.ai = false
      and agent.user_id is not null
      and (
        agent.extra->'invitation' is null
        or agent.extra->'invitation'->>'status' = 'accepted'
      )
    group by agent.id, agent.name, agent.picture
    order by
      count(conversation.id) filter (
        where conversation.status = 'active'
      ) desc,
      count(conversation.id) desc,
      agent.name,
      agent.id
    limit 5
  )
  select
    selected_start,
    current_date,
    (
      select count(*)
      from public.contacts contact
      where contact.organization_id = p_organization_id
        and contact.status = 'active'
    ),
    (
      select count(distinct activity.contact_id)
      from message_contacts activity
      where activity.activity_date = current_date
    ),
    (
      select count(distinct activity.contact_id)
      from message_contacts activity
      where activity.activity_date >= current_date - 6
    ),
    (
      select count(distinct activity.contact_id)
      from message_contacts activity
    ),
    (
      select count(*)
      from public.contacts contact
      where contact.organization_id = p_organization_id
        and contact.status = 'active'
        and (contact.created_at at time zone 'UTC')::date >= selected_start
    ),
    (
      select count(*)
      from public.conversations conversation
      where conversation.organization_id = p_organization_id
        and conversation.status = 'active'
    ),
    (
      select count(*)
      from public.conversations conversation
      where conversation.organization_id = p_organization_id
        and conversation.status = 'active'
        and conversation.assigned_agent_id is null
    ),
    (
      select count(*)
      from public.conversations conversation
      where conversation.organization_id = p_organization_id
        and conversation.status = 'closed'
    ),
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'date', series.day,
            'active_contacts', series.active_contacts,
            'new_contacts', series.new_contacts
          ) order by series.day
        )
        from contact_series series
      ),
      '[]'::jsonb
    ),
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'date', series.day,
            'sent', series.sent,
            'received', series.received
          ) order by series.day
        )
        from message_series series
      ),
      '[]'::jsonb
    ),
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', member.id,
            'name', member.name,
            'picture', member.picture,
            'assigned', member.assigned,
            'open', member.open,
            'closed', member.closed
          ) order by member.open desc, member.assigned desc, member.name, member.id
        )
        from team_counts member
      ),
      '[]'::jsonb
    );
end;
$function$
;
