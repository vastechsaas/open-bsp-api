alter table public.quick_replies enable row level security;

create policy "members can read their orgs quick replies"
on public.quick_replies
for select
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('member')
  )
);

create policy "supervisors can manage their orgs quick replies"
on public.quick_replies
for all
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('supervisor')
  )
);

create policy "agents can read their orgs quick replies"
on public.quick_replies
for select
to authenticated
using (
  public.get_request_organization_role(organization_id) = 'agent'::public.role
);
