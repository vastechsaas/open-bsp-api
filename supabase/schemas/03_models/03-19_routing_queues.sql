create table public.routing_queues (
  organization_id uuid not null,
  id uuid default gen_random_uuid() not null,
  name text not null,
  status text default 'active'::text not null,
  assignment_strategy text default 'manual'::text not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.routing_queues
add constraint routing_queues_pkey primary key (id);

alter table only public.routing_queues
add constraint routing_queues_organization_id_id_key
unique (organization_id, id);

alter table only public.routing_queues
add constraint routing_queues_organization_id_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

alter table only public.routing_queues
add constraint routing_queues_name_check
check (char_length(btrim(name)) between 1 and 80);

alter table only public.routing_queues
add constraint routing_queues_status_check
check (status in ('active', 'archived'));

alter table only public.routing_queues
add constraint routing_queues_assignment_strategy_check
check (assignment_strategy in ('manual', 'round_robin'));

create unique index routing_queues_organization_name_key
on public.routing_queues (organization_id, lower(name));

create index routing_queues_organization_status_name_idx
on public.routing_queues (organization_id, status, name, id);

create trigger set_updated_at
before update on public.routing_queues
for each row
execute function public.moddatetime('updated_at');

create table public.routing_queue_members (
  organization_id uuid not null,
  routing_queue_id uuid not null,
  agent_id uuid not null,
  created_at timestamp with time zone default now() not null
);

alter table only public.routing_queue_members
add constraint routing_queue_members_pkey
primary key (organization_id, routing_queue_id, agent_id);

alter table only public.routing_queue_members
add constraint routing_queue_members_queue_fkey
foreign key (organization_id, routing_queue_id)
references public.routing_queues(organization_id, id)
on delete cascade;

alter table only public.routing_queue_members
add constraint routing_queue_members_agent_fkey
foreign key (organization_id, agent_id)
references public.agents(organization_id, id)
on delete cascade;

create index routing_queue_members_agent_idx
on public.routing_queue_members (organization_id, agent_id, routing_queue_id);

alter table only public.conversations
add constraint conversations_organization_id_routing_queue_id_fkey
foreign key (organization_id, routing_queue_id)
references public.routing_queues(organization_id, id)
on delete restrict;

create index conversations_routing_queue_state_idx
on public.conversations (
  organization_id,
  routing_queue_id,
  status,
  assigned_agent_id,
  routed_at
);
