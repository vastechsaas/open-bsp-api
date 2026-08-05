alter table public.organizations_addresses enable row level security;

-- Note: organizations addresses are read only. They are managed by the system.

create policy "members can read their orgs addresses"
on public.organizations_addresses
for select
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('member')
  )
);

create policy "agents can read their orgs addresses"
on public.organizations_addresses
for select
to authenticated
using (
  public.get_request_organization_role(organization_id) = 'agent'::public.role
);
