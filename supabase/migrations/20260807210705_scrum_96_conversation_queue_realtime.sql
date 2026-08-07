set check_function_bodies = off;

create or replace function public.broadcast_conversation_queue_state()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  perform realtime.send(
    jsonb_build_object(
      'organization_id', new.organization_id,
      'conversation_id', new.id,
      'assigned_agent_id', new.assigned_agent_id,
      'status', new.status,
      'updated_at', new.updated_at
    ),
    'conversation_state_changed',
    'conversation-queue:' || new.organization_id::text,
    true
  );

  return null;
end;
$function$;

revoke execute on function public.broadcast_conversation_queue_state()
from public;

create trigger broadcast_conversation_queue_state_trigger
after update of assigned_agent_id, status on public.conversations
for each row
when (
  old.assigned_agent_id is distinct from new.assigned_agent_id
  or old.status is distinct from new.status
)
execute function public.broadcast_conversation_queue_state();

create policy "accepted organization humans receive conversation queue changes"
on realtime.messages
as permissive
for select
to authenticated
using (
  realtime.messages.extension = 'broadcast'
  and realtime.messages.topic = realtime.topic()
  and exists (
    select 1
    from public.get_authorized_orgs('agent') as authorized_orgs(id)
    where realtime.topic() = 'conversation-queue:' || authorized_orgs.id::text
  )
);
