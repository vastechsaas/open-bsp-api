revoke execute on function public.set_conversation_agent_assignment(uuid, uuid)
from public;
grant execute on function public.set_conversation_agent_assignment(uuid, uuid)
to authenticated;

revoke execute on function public.create_conversation_for_me(
  uuid,
  public.service,
  text,
  text,
  text,
  text,
  jsonb
) from public;
grant execute on function public.create_conversation_for_me(
  uuid,
  public.service,
  text,
  text,
  text,
  text,
  jsonb
) to authenticated;

drop policy "agents can create assigned conversation messages"
on public.messages;

create policy "agents can create assigned conversation messages"
on public.messages
for insert
to authenticated
with check (
  public.agent_message_insert_rules(
    organization_id,
    conversation_id,
    agent_id,
    direction,
    service,
    organization_address,
    group_address
  )
  and (
    content->>'kind' is distinct from 'template'
    or exists (
      select 1
      from public.message_templates template
      where template.organization_id = messages.organization_id
        and template.organization_address = messages.organization_address
        and template.status = 'approved'
        and template.name = messages.content->'data'->>'name'
        and template.language = messages.content->'data'->'language'->>'code'
    )
  )
);
