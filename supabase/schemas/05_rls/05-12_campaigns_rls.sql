alter table public.campaigns enable row level security;

create policy "members can manage their orgs campaign drafts"
on public.campaigns
for all
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('member')
  )
)
with check (
  organization_id in (
    select public.get_authorized_orgs('member')
  )
);

alter table public.campaign_csv_recipients enable row level security;

create policy "members can manage their orgs campaign CSV recipients"
on public.campaign_csv_recipients
for all
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('member')
  )
)
with check (
  organization_id in (
    select public.get_authorized_orgs('member')
  )
);
