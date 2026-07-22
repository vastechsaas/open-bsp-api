create table public.chatbot_flows (
  organization_id uuid not null,
  id uuid default gen_random_uuid() not null,
  created_by uuid,
  name text not null,
  status text default 'active'::text not null,
  archived_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.chatbot_flows
add constraint chatbot_flows_pkey
primary key (id);

alter table only public.chatbot_flows
add constraint chatbot_flows_organization_id_id_key
unique (organization_id, id);

alter table only public.chatbot_flows
add constraint chatbot_flows_organization_id_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

alter table only public.chatbot_flows
add constraint chatbot_flows_created_by_fkey
foreign key (organization_id, created_by)
references public.agents(organization_id, id)
on delete set null (created_by);

alter table only public.chatbot_flows
add constraint chatbot_flows_name_check
check (length(btrim(name)) > 0);

alter table only public.chatbot_flows
add constraint chatbot_flows_status_check
check (status in ('active', 'archived'));

alter table only public.chatbot_flows
add constraint chatbot_flows_archived_at_check
check (
  (status = 'active' and archived_at is null)
  or (status = 'archived' and archived_at is not null)
);

create unique index chatbot_flows_organization_name_key
on public.chatbot_flows (organization_id, lower(btrim(name)));

create index chatbot_flows_organization_updated_at_idx
on public.chatbot_flows
using btree (organization_id, updated_at desc, id desc);

create trigger set_updated_at
before update
on public.chatbot_flows
for each row
execute function public.moddatetime('updated_at');

create table public.chatbot_flow_versions (
  organization_id uuid not null,
  flow_id uuid not null,
  id uuid default gen_random_uuid() not null,
  created_by uuid,
  version integer not null,
  status text default 'draft'::text not null,
  editor_graph jsonb default '{"nodes":[],"edges":[]}'::jsonb not null,
  definition jsonb,
  published_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.chatbot_flow_versions
add constraint chatbot_flow_versions_pkey
primary key (id);

alter table only public.chatbot_flow_versions
add constraint chatbot_flow_versions_organization_id_id_key
unique (organization_id, id);

alter table only public.chatbot_flow_versions
add constraint chatbot_flow_versions_flow_version_key
unique (flow_id, version);

alter table only public.chatbot_flow_versions
add constraint chatbot_flow_versions_flow_fkey
foreign key (organization_id, flow_id)
references public.chatbot_flows(organization_id, id)
on delete cascade;

alter table only public.chatbot_flow_versions
add constraint chatbot_flow_versions_created_by_fkey
foreign key (organization_id, created_by)
references public.agents(organization_id, id)
on delete set null (created_by);

alter table only public.chatbot_flow_versions
add constraint chatbot_flow_versions_version_check
check (version > 0);

alter table only public.chatbot_flow_versions
add constraint chatbot_flow_versions_status_check
check (status in ('draft', 'published'));

alter table only public.chatbot_flow_versions
add constraint chatbot_flow_versions_editor_graph_check
check (
  jsonb_typeof(editor_graph) = 'object'
  and editor_graph ? 'nodes'
  and editor_graph ? 'edges'
  and jsonb_typeof(editor_graph->'nodes') = 'array'
  and jsonb_typeof(editor_graph->'edges') = 'array'
);

alter table only public.chatbot_flow_versions
add constraint chatbot_flow_versions_definition_check
check (
  definition is null
  or (
    jsonb_typeof(definition) = 'object'
    and definition ? 'schema_version'
    and definition ? 'start_node_id'
    and definition ? 'nodes'
    and definition ? 'edges'
    and jsonb_typeof(definition->'schema_version') = 'number'
    and (definition->>'schema_version')::numeric >= 1
    and trunc((definition->>'schema_version')::numeric) =
      (definition->>'schema_version')::numeric
    and jsonb_typeof(definition->'start_node_id') = 'string'
    and length(btrim(definition->>'start_node_id')) > 0
    and jsonb_typeof(definition->'nodes') = 'array'
    and jsonb_typeof(definition->'edges') = 'array'
  )
);

alter table only public.chatbot_flow_versions
add constraint chatbot_flow_versions_published_state_check
check (
  (status = 'draft' and published_at is null)
  or (
    status = 'published'
    and published_at is not null
    and definition is not null
  )
);

create unique index chatbot_flow_versions_one_draft_per_flow_idx
on public.chatbot_flow_versions (flow_id)
where status = 'draft';

create index chatbot_flow_versions_flow_status_version_idx
on public.chatbot_flow_versions
using btree (flow_id, status, version desc);

create trigger set_updated_at
before update
on public.chatbot_flow_versions
for each row
execute function public.moddatetime('updated_at');

create table public.chatbot_flow_runs (
  organization_id uuid not null,
  conversation_id uuid not null,
  flow_version_id uuid not null,
  agent_id uuid not null,
  id uuid default gen_random_uuid() not null,
  current_node_id text,
  status text default 'running'::text not null,
  waiting_for text,
  variables jsonb default '{}'::jsonb not null,
  lock_version bigint default 0 not null,
  last_processed_message_id uuid,
  error jsonb,
  started_at timestamp with time zone default now() not null,
  expires_at timestamp with time zone,
  ended_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.chatbot_flow_runs
add constraint chatbot_flow_runs_pkey
primary key (id);

alter table only public.chatbot_flow_runs
add constraint chatbot_flow_runs_organization_id_id_key
unique (organization_id, id);

alter table only public.chatbot_flow_runs
add constraint chatbot_flow_runs_organization_id_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

alter table only public.chatbot_flow_runs
add constraint chatbot_flow_runs_conversation_fkey
foreign key (conversation_id)
references public.conversations(id)
on delete cascade;

alter table only public.chatbot_flow_runs
add constraint chatbot_flow_runs_flow_version_fkey
foreign key (organization_id, flow_version_id)
references public.chatbot_flow_versions(organization_id, id)
on delete restrict;

alter table only public.chatbot_flow_runs
add constraint chatbot_flow_runs_agent_fkey
foreign key (organization_id, agent_id)
references public.agents(organization_id, id)
on delete restrict;

alter table only public.chatbot_flow_runs
add constraint chatbot_flow_runs_last_processed_message_fkey
foreign key (last_processed_message_id)
references public.messages(id)
on delete set null;

alter table only public.chatbot_flow_runs
add constraint chatbot_flow_runs_current_node_check
check (
  status not in ('running', 'waiting')
  or (
    current_node_id is not null
    and length(btrim(current_node_id)) > 0
  )
);

alter table only public.chatbot_flow_runs
add constraint chatbot_flow_runs_status_check
check (
  status in (
    'running',
    'waiting',
    'completed',
    'failed',
    'handed_off',
    'expired'
  )
);

alter table only public.chatbot_flow_runs
add constraint chatbot_flow_runs_waiting_for_check
check (
  (
    status = 'waiting'
    and waiting_for is not null
    and waiting_for in ('free_text', 'button', 'list_selection')
  )
  or (status <> 'waiting' and waiting_for is null)
);

alter table only public.chatbot_flow_runs
add constraint chatbot_flow_runs_variables_check
check (jsonb_typeof(variables) = 'object');

alter table only public.chatbot_flow_runs
add constraint chatbot_flow_runs_lock_version_check
check (lock_version >= 0);

alter table only public.chatbot_flow_runs
add constraint chatbot_flow_runs_error_check
check (error is null or jsonb_typeof(error) = 'object');

alter table only public.chatbot_flow_runs
add constraint chatbot_flow_runs_expiry_check
check (expires_at is null or expires_at > started_at);

alter table only public.chatbot_flow_runs
add constraint chatbot_flow_runs_ended_at_check
check (
  (status in ('running', 'waiting') and ended_at is null)
  or (
    status in ('completed', 'failed', 'handed_off', 'expired')
    and ended_at is not null
  )
);

create unique index chatbot_flow_runs_one_active_per_conversation_idx
on public.chatbot_flow_runs (conversation_id)
where status in ('running', 'waiting');

create index chatbot_flow_runs_organization_status_updated_at_idx
on public.chatbot_flow_runs
using btree (organization_id, status, updated_at desc);

create index chatbot_flow_runs_flow_version_idx
on public.chatbot_flow_runs
using btree (flow_version_id);

create index chatbot_flow_runs_expires_at_idx
on public.chatbot_flow_runs
using btree (expires_at)
where status in ('running', 'waiting') and expires_at is not null;

create trigger set_updated_at
before update
on public.chatbot_flow_runs
for each row
execute function public.moddatetime('updated_at');

grant delete, insert, references, select, trigger, truncate, update
on table public.chatbot_flows
to anon, authenticated, service_role;

grant delete, insert, references, select, trigger, truncate, update
on table public.chatbot_flow_versions
to anon, authenticated, service_role;

grant delete, insert, references, select, trigger, truncate, update
on table public.chatbot_flow_runs
to anon, authenticated, service_role;
