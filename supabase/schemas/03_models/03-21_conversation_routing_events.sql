create table public.conversation_routing_events (
  id uuid default gen_random_uuid() not null,
  organization_id uuid not null,
  conversation_id uuid not null,
  previous_routing_queue_id uuid,
  previous_routing_queue_name text,
  destination_routing_queue_id uuid not null,
  destination_routing_queue_name text not null,
  actor_agent_id uuid,
  source text not null,
  explanation text,
  created_at timestamp with time zone default now() not null
);

alter table only public.conversation_routing_events
add constraint conversation_routing_events_pkey
primary key (id);

alter table only public.conversation_routing_events
add constraint conversation_routing_events_organization_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

alter table only public.conversation_routing_events
add constraint conversation_routing_events_conversation_fkey
foreign key (conversation_id)
references public.conversations(id)
on delete cascade;

alter table only public.conversation_routing_events
add constraint conversation_routing_events_actor_fkey
foreign key (actor_agent_id)
references public.agents(id)
on delete set null;

alter table only public.conversation_routing_events
add constraint conversation_routing_events_destination_name_check
check (char_length(btrim(destination_routing_queue_name)) between 1 and 80);

alter table only public.conversation_routing_events
add constraint conversation_routing_events_previous_name_check
check (
  previous_routing_queue_name is null
  or char_length(btrim(previous_routing_queue_name)) between 1 and 80
);

alter table only public.conversation_routing_events
add constraint conversation_routing_events_source_check
check (source in ('legacy_backfill', 'chatbot_handoff', 'manual_transfer'));

alter table only public.conversation_routing_events
add constraint conversation_routing_events_explanation_check
check (
  (source = 'manual_transfer' and nullif(btrim(explanation), '') is not null)
  or (source <> 'manual_transfer')
);

create index conversation_routing_events_conversation_time_idx
on public.conversation_routing_events (conversation_id, created_at desc, id desc);

create index conversation_routing_events_organization_time_idx
on public.conversation_routing_events (
  organization_id,
  created_at desc,
  id desc
);
