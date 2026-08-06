alter table public.messages enable row level security;

-- Note: messages cannot be edited or deleted by the user.

create policy "members can read their orgs messages"
on public.messages
for select
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('member')
  )
);

create policy "members can create their orgs messages"
on public.messages
for insert
to authenticated, anon
with check (
  organization_id in (
    select public.get_authorized_orgs('member')
  )
  and not (
    direction = 'internal'::public.direction
    and content->>'kind' = 'private_note'
  )
);

create policy "agents can read visible conversation messages"
on public.messages
for select
to authenticated
using (
  public.agent_can_read_conversation(organization_id, conversation_id)
);

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
