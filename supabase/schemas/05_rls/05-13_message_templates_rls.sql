alter table public.message_templates enable row level security;

create policy "members can read their orgs message templates"
on public.message_templates
for select
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('member')
  )
);

create policy "admins can create their orgs message templates"
on public.message_templates
for insert
to authenticated, anon
with check (
  organization_id in (
    select public.get_authorized_orgs('admin')
  )
);

create policy "admins can update their orgs message templates"
on public.message_templates
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

create policy "admins can delete their orgs message templates"
on public.message_templates
for delete
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('admin')
  )
);
