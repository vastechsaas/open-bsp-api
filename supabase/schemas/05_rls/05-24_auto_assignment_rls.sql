alter table public.agent_assignment_presence enable row level security;
alter table public.routing_queue_assignment_state enable row level security;
alter table public.conversation_assignment_events enable row level security;

create policy "agents can read their assignment presence"
on public.agent_assignment_presence for select to authenticated
using (
  agent_id = public.get_current_human_agent_id(organization_id)
  or public.get_request_organization_role(organization_id) in (
    'owner'::public.role, 'admin'::public.role, 'supervisor'::public.role
  )
);

create policy "authorized users can read assignment events"
on public.conversation_assignment_events for select to authenticated
using (
  public.get_request_organization_role(organization_id) in (
    'owner'::public.role, 'admin'::public.role, 'supervisor'::public.role
  )
  or public.agent_can_read_conversation(organization_id, conversation_id)
);
