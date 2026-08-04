alter table public.chatbot_flow_deployments enable row level security;

create policy "members can read their orgs chatbot deployments"
on public.chatbot_flow_deployments
for select
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs_by_roles(
      array['owner', 'admin', 'member']::public.role[]
    )
  )
);

create policy "admins can create their orgs chatbot deployments"
on public.chatbot_flow_deployments
for insert
to authenticated, anon
with check (
  organization_id in (
    select public.get_authorized_orgs('admin')
  )
);

create policy "admins can update their orgs chatbot deployments"
on public.chatbot_flow_deployments
for update
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('admin')
  )
)
with check (
  organization_id in (
    select public.get_authorized_orgs('admin')
  )
);

create policy "admins can delete their orgs chatbot deployments"
on public.chatbot_flow_deployments
for delete
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('admin')
  )
);
