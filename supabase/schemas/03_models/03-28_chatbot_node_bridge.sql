create table public.chatbot_node_bridges (
  organization_id uuid not null,
  organization_address text not null,
  engine text not null default 'native' check (engine in ('native', 'transitioning', 'node', 'disabled')),
  flow_id uuid,
  flow_version_id uuid,
  node_company_id text not null check (node_company_id ~ '^[0-9]+$'),
  node_flow_id text,
  node_version_id text,
  definition_hash text,
  request_id uuid,
  sync_status text not null default 'disabled' check (sync_status in ('disabled', 'pending', 'syncing', 'active', 'failed', 'suspended')),
  last_error text,
  updated_at timestamptz not null default now(),
  primary key (organization_id, organization_address),
  foreign key (organization_id, organization_address)
    references public.organizations_addresses(organization_id, address) on delete cascade,
  foreign key (organization_id, flow_id)
    references public.chatbot_flows(organization_id, id),
  foreign key (organization_id, flow_version_id)
    references public.chatbot_flow_versions(organization_id, id)
);

create table public.chatbot_node_operations (
  request_id uuid primary key,
  organization_id uuid not null,
  organization_address text not null,
  action text not null check (action in ('activate', 'deactivate', 'suspend', 'restore', 'resume')),
  phase text not null default 'prepare',
  status text not null default 'pending' check (status in ('pending', 'in_flight', 'reconciling', 'retry_wait', 'succeeded', 'failed')),
  attempts integer not null default 0 check (attempts between 0 and 5),
  payload jsonb not null,
  result jsonb,
  last_error text,
  next_attempt_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (organization_id, organization_address)
    references public.chatbot_node_bridges(organization_id, organization_address) on delete cascade
);
create index chatbot_node_operations_due_idx on public.chatbot_node_operations(status, next_attempt_at);

create table public.chatbot_node_conversations (
  organization_id uuid not null,
  organization_address text not null,
  node_conversation_id text not null check (node_conversation_id ~ '^[0-9]+$'),
  conversation_id uuid not null,
  human_owned boolean not null default true,
  primary key (organization_id, organization_address, node_conversation_id),
  foreign key (organization_id, organization_address)
    references public.chatbot_node_bridges(organization_id, organization_address) on delete cascade,
  foreign key (organization_id, conversation_id)
    references public.conversations(organization_id, id) on delete cascade
);
create table public.chatbot_node_handoff_receipts (
  event_id uuid primary key,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.chatbot_node_bridges enable row level security;
alter table public.chatbot_node_operations enable row level security;
alter table public.chatbot_node_conversations enable row level security;
alter table public.chatbot_node_handoff_receipts enable row level security;
revoke all on public.chatbot_node_bridges, public.chatbot_node_operations,
  public.chatbot_node_conversations, public.chatbot_node_handoff_receipts from anon, authenticated;
grant all on public.chatbot_node_bridges, public.chatbot_node_operations,
  public.chatbot_node_conversations, public.chatbot_node_handoff_receipts to service_role;
grant select on public.chatbot_node_bridges, public.chatbot_node_conversations to authenticated;
