set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.get_conversation_queue_conversations(
  p_organization_id uuid,
  p_queue_key text,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
 RETURNS SETOF public.conversations
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  normalized_limit integer;
  normalized_offset integer;
begin
  if p_organization_id is null then
    raise exception using
      errcode = '22004',
      message = 'organization id is required';
  end if;

  if p_queue_key is null or p_queue_key not in (
    'all_active',
    'assigned',
    'pending',
    'spam',
    'closed',
    'expired'
  ) then
    raise exception using
      errcode = '22023',
      message = 'invalid conversation queue key';
  end if;

  if not exists (
    select 1
    from public.get_authorized_orgs('member') as authorized_orgs(id)
    where authorized_orgs.id = p_organization_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  normalized_limit := least(greatest(coalesce(p_limit, 50), 1), 500);
  normalized_offset := greatest(coalesce(p_offset, 0), 0);

  return query
  select c.*
  from public.conversations c
  left join lateral (
    select max(m.timestamp) as latest_incoming_at
    from public.messages m
    where m.organization_id = c.organization_id
      and m.conversation_id = c.id
      and m.direction = 'incoming'::public.direction
  ) incoming on true
  where c.organization_id = p_organization_id
    and (
      (
        p_queue_key = 'all_active'
        and c.status = 'active'
      )
      or (
        p_queue_key = 'assigned'
        and c.status = 'active'
        and c.assigned_agent_id is not null
      )
      or (
        p_queue_key = 'pending'
        and c.status = 'active'
        and c.assigned_agent_id is null
      )
      or (
        p_queue_key = 'spam'
        and c.status = 'spam'
      )
      or (
        p_queue_key = 'closed'
        and c.status = 'closed'
      )
      or (
        p_queue_key = 'expired'
        and c.status = 'active'
        and incoming.latest_incoming_at <= now() - interval '24 hours'
      )
    )
  order by c.updated_at desc, c.id desc
  limit normalized_limit
  offset normalized_offset;
end;
$function$
;
