create table public.chatbot_flow_deployments (
  organization_id uuid not null,
  organization_address text not null,
  flow_id uuid not null,
  flow_version_id uuid not null,
  agent_id uuid not null,
  activated_by uuid,
  activated_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.chatbot_flow_deployments
add constraint chatbot_flow_deployments_pkey
primary key (organization_id, organization_address);

alter table only public.chatbot_flow_deployments
add constraint chatbot_flow_deployments_address_fkey
foreign key (organization_id, organization_address)
references public.organizations_addresses(organization_id, address)
on delete cascade;

alter table only public.chatbot_flow_deployments
add constraint chatbot_flow_deployments_flow_fkey
foreign key (organization_id, flow_id)
references public.chatbot_flows(organization_id, id)
on delete cascade;

alter table only public.chatbot_flow_deployments
add constraint chatbot_flow_deployments_version_fkey
foreign key (organization_id, flow_version_id)
references public.chatbot_flow_versions(organization_id, id)
on delete restrict;

alter table only public.chatbot_flow_deployments
add constraint chatbot_flow_deployments_agent_fkey
foreign key (organization_id, agent_id)
references public.agents(organization_id, id)
on delete restrict;

alter table only public.chatbot_flow_deployments
add constraint chatbot_flow_deployments_activated_by_fkey
foreign key (organization_id, activated_by)
references public.agents(organization_id, id)
on delete set null (activated_by);

create index chatbot_flow_deployments_flow_idx
on public.chatbot_flow_deployments
using btree (flow_id);

create index chatbot_flow_deployments_version_idx
on public.chatbot_flow_deployments
using btree (flow_version_id);

create trigger set_updated_at
before update
on public.chatbot_flow_deployments
for each row
execute function public.moddatetime('updated_at');

grant delete, insert, references, select, trigger, truncate, update
on table public.chatbot_flow_deployments
to anon, authenticated, service_role;
