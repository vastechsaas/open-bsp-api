alter table public.campaigns enable row level security;

create policy "members can read their orgs campaigns"
on public.campaigns
for select
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs_by_roles(array['owner', 'admin', 'member']::public.role[])
  )
);

create policy "members can create their orgs campaign drafts"
on public.campaigns
for insert
to authenticated, anon
with check (
  organization_id in (
    select public.get_authorized_orgs_by_roles(array['owner', 'admin', 'member']::public.role[])
  )
  and status = 'draft'
);

create policy "members can update their orgs campaign drafts"
on public.campaigns
for update
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs_by_roles(array['owner', 'admin', 'member']::public.role[])
  )
  and status = 'draft'
)
with check (
  organization_id in (
    select public.get_authorized_orgs_by_roles(array['owner', 'admin', 'member']::public.role[])
  )
  and status = 'draft'
);

create policy "members can delete their orgs campaign drafts"
on public.campaigns
for delete
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs_by_roles(array['owner', 'admin', 'member']::public.role[])
  )
  and status = 'draft'
);

alter table public.campaign_csv_recipients enable row level security;

create policy "members can read their orgs campaign CSV recipients"
on public.campaign_csv_recipients
for select
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs_by_roles(array['owner', 'admin', 'member']::public.role[])
  )
);

create policy "members can create CSV recipients for campaign drafts"
on public.campaign_csv_recipients
for insert
to authenticated, anon
with check (
  organization_id in (
    select public.get_authorized_orgs_by_roles(array['owner', 'admin', 'member']::public.role[])
  )
  and exists (
    select 1
    from public.campaigns c
    where c.organization_id = campaign_csv_recipients.organization_id
      and c.id = campaign_csv_recipients.campaign_id
      and c.status = 'draft'
  )
);

create policy "members can update CSV recipients for campaign drafts"
on public.campaign_csv_recipients
for update
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs_by_roles(array['owner', 'admin', 'member']::public.role[])
  )
  and exists (
    select 1
    from public.campaigns c
    where c.organization_id = campaign_csv_recipients.organization_id
      and c.id = campaign_csv_recipients.campaign_id
      and c.status = 'draft'
  )
)
with check (
  organization_id in (
    select public.get_authorized_orgs_by_roles(array['owner', 'admin', 'member']::public.role[])
  )
  and exists (
    select 1
    from public.campaigns c
    where c.organization_id = campaign_csv_recipients.organization_id
      and c.id = campaign_csv_recipients.campaign_id
      and c.status = 'draft'
  )
);

create policy "members can delete CSV recipients for campaign drafts"
on public.campaign_csv_recipients
for delete
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs_by_roles(array['owner', 'admin', 'member']::public.role[])
  )
  and exists (
    select 1
    from public.campaigns c
    where c.organization_id = campaign_csv_recipients.organization_id
      and c.id = campaign_csv_recipients.campaign_id
      and c.status = 'draft'
  )
);

alter table public.campaign_deliveries enable row level security;

create policy "members can read their orgs campaign deliveries"
on public.campaign_deliveries
for select
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs_by_roles(array['owner', 'admin', 'member']::public.role[])
  )
);
