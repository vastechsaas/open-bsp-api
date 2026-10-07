alter table public.chatbot_flow_deployments enable row level security;

create policy "members can read their orgs chatbot deployments"
on public.chatbot_flow_deployments
for select
to authenticated, anon
using (
  public.has_module_permission(organization_id, 'chatbot_builder', 'view')
);

create policy "admins can create their orgs chatbot deployments"
on public.chatbot_flow_deployments
for insert
to authenticated, anon
with check (
  public.has_module_permission(organization_id, 'chatbot_builder', 'manage')
);

create policy "admins can update their orgs chatbot deployments"
on public.chatbot_flow_deployments
for update
to authenticated, anon
using (
  public.has_module_permission(organization_id, 'chatbot_builder', 'manage')
)
with check (
  public.has_module_permission(organization_id, 'chatbot_builder', 'manage')
);

create policy "admins can delete their orgs chatbot deployments"
on public.chatbot_flow_deployments
for delete
to authenticated, anon
using (
  public.has_module_permission(organization_id, 'chatbot_builder', 'manage')
);
