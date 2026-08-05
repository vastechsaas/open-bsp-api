alter table public.contacts enable row level security;

create policy "members can manage their orgs contacts"
on public.contacts
for all
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('member')
  )
);

create policy "agents can manage their orgs contacts"
on public.contacts
for all
to authenticated
using (
  public.get_request_organization_role(organization_id) = 'agent'::public.role
)
with check (
  public.get_request_organization_role(organization_id) = 'agent'::public.role
);
