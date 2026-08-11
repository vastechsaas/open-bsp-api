alter table public.conversations enable row level security;

create policy "members can manage their orgs conversations"
on public.conversations
for all
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('member')
  )
);

create policy "agents can read visible conversations"
on public.conversations
for select
to authenticated
using (
  public.agent_can_read_conversation(organization_id, id)
);

create policy "agents can update assigned conversations"
on public.conversations
for update
to authenticated
using (
  public.agent_owns_conversation(organization_id, id)
)
with check (
  public.get_request_organization_role(organization_id) = 'agent'::public.role
  and public.agent_conversation_update_rules(
    id,
    organization_id,
    service,
    organization_address,
    contact_address,
    group_address,
    assigned_agent_id,
    routing_queue_id,
    routed_at
  )
);
