alter table public.routing_queues enable row level security;
alter table public.routing_queue_members enable row level security;

create policy "managers can read organization routing queues"
on public.routing_queues
for select
to authenticated
using (
  public.get_request_organization_role(organization_id) in (
    'owner'::public.role,
    'admin'::public.role,
    'supervisor'::public.role
  )
);

create policy "agents can read their active routing queues"
on public.routing_queues
for select
to authenticated
using (
  status = 'active'
  and public.get_request_organization_role(organization_id) = 'agent'::public.role
  and exists (
    select 1
    from public.routing_queue_members member
    where member.organization_id = routing_queues.organization_id
      and member.routing_queue_id = routing_queues.id
      and member.agent_id = public.get_current_human_agent_id(organization_id)
  )
);

create policy "managers can read organization routing queue members"
on public.routing_queue_members
for select
to authenticated
using (
  public.get_request_organization_role(organization_id) in (
    'owner'::public.role,
    'admin'::public.role,
    'supervisor'::public.role
  )
);

create policy "agents can read their routing queue memberships"
on public.routing_queue_members
for select
to authenticated
using (
  public.get_request_organization_role(organization_id) = 'agent'::public.role
  and agent_id = public.get_current_human_agent_id(organization_id)
);
