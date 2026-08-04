alter table public.chatbot_flows enable row level security;

create policy "members can read their orgs chatbot flows"
on public.chatbot_flows
for select
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs_by_roles(
      array['owner', 'admin', 'member']::public.role[]
    )
  )
);

create policy "admins can create their orgs chatbot flows"
on public.chatbot_flows
for insert
to authenticated, anon
with check (
  organization_id in (
    select public.get_authorized_orgs('admin')
  )
);

create policy "admins can update their orgs chatbot flows"
on public.chatbot_flows
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

create policy "admins can delete their orgs unpublished chatbot flows"
on public.chatbot_flows
for delete
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('admin')
  )
  and not exists (
    select 1
    from public.chatbot_flow_versions as version
    where version.flow_id = chatbot_flows.id
      and version.status = 'published'
  )
);

alter table public.chatbot_flow_versions enable row level security;

create policy "members can read their orgs chatbot flow versions"
on public.chatbot_flow_versions
for select
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs_by_roles(
      array['owner', 'admin', 'member']::public.role[]
    )
  )
);

create policy "admins can create chatbot flow drafts"
on public.chatbot_flow_versions
for insert
to authenticated, anon
with check (
  organization_id in (
    select public.get_authorized_orgs('admin')
  )
  and status = 'draft'
);

create policy "admins can update chatbot flow drafts"
on public.chatbot_flow_versions
for update
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('admin')
  )
  and status = 'draft'
)
with check (
  organization_id in (
    select public.get_authorized_orgs('admin')
  )
  and status = 'draft'
);

create policy "admins can delete chatbot flow drafts"
on public.chatbot_flow_versions
for delete
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('admin')
  )
  and status = 'draft'
);

alter table public.chatbot_flow_runs enable row level security;

create policy "members can read their orgs chatbot flow runs"
on public.chatbot_flow_runs
for select
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs_by_roles(
      array['owner', 'admin', 'member']::public.role[]
    )
  )
);
