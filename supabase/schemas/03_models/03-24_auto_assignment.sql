create table public.agent_assignment_presence (
  organization_id uuid not null,
  agent_id uuid not null,
  available boolean default false not null,
  last_heartbeat_at timestamp with time zone,
  updated_at timestamp with time zone default now() not null,
  primary key (organization_id, agent_id),
  foreign key (organization_id, agent_id)
    references public.agents(organization_id, id) on delete cascade
);

create index agent_assignment_presence_eligible_idx
on public.agent_assignment_presence (organization_id, last_heartbeat_at desc, agent_id)
where available = true;

create table public.routing_queue_assignment_state (
  organization_id uuid not null,
  routing_queue_id uuid not null,
  last_assigned_agent_id uuid,
  updated_at timestamp with time zone default now() not null,
  primary key (organization_id, routing_queue_id),
  foreign key (organization_id, routing_queue_id)
    references public.routing_queues(organization_id, id) on delete cascade,
  foreign key (organization_id, last_assigned_agent_id)
    references public.agents(organization_id, id) on delete set null (last_assigned_agent_id)
);

create table public.conversation_assignment_events (
  organization_id uuid not null,
  id uuid default gen_random_uuid() not null,
  conversation_id uuid not null,
  routing_queue_id uuid,
  routing_queue_name text,
  previous_agent_id uuid,
  previous_agent_name text,
  assigned_agent_id uuid,
  assigned_agent_name text,
  actor_agent_id uuid,
  strategy text not null,
  source text not null,
  created_at timestamp with time zone default now() not null,
  primary key (id),
  foreign key (organization_id, conversation_id)
    references public.conversations(organization_id, id) on delete cascade,
  foreign key (organization_id, routing_queue_id)
    references public.routing_queues(organization_id, id) on delete set null (routing_queue_id),
  foreign key (organization_id, previous_agent_id)
    references public.agents(organization_id, id) on delete set null (previous_agent_id),
  foreign key (organization_id, assigned_agent_id)
    references public.agents(organization_id, id) on delete set null (assigned_agent_id),
  foreign key (organization_id, actor_agent_id)
    references public.agents(organization_id, id) on delete set null (actor_agent_id),
  check (strategy in ('round_robin')),
  check (source in (
    'chatbot_handoff', 'queue_transfer', 'manual_unassignment',
    'automation_enabled', 'agent_available', 'recovery'
  ))
);

create index conversation_assignment_events_conversation_time_idx
on public.conversation_assignment_events (organization_id, conversation_id, created_at, id);

alter table public.conversation_assignment_events replica identity full;
