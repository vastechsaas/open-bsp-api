-- Backend-only reuse of Meta uploads. Original content-addressed assets remain in storage.
create table public.campaign_media_cache (
  organization_id uuid not null,
  organization_address text not null,
  storage_uri text not null,
  media_id text,
  uploaded_at timestamptz,
  lease_token uuid,
  lease_expires_at timestamptz,
  primary key (organization_id,organization_address,storage_uri),
  foreign key (organization_id,organization_address)
    references public.organizations_addresses(organization_id,address) on delete cascade,
  check (storage_uri ~ ('^internal://media/organizations/' || organization_id::text || '/attachments/[A-Za-z0-9_-]{43}$')),
  check (media_id is null or media_id ~ '^[0-9]{1,100}$'),
  check ((lease_token is null) = (lease_expires_at is null))
);
alter table public.campaign_media_cache enable row level security;
revoke all on public.campaign_media_cache from public,anon,authenticated;
grant all on public.campaign_media_cache to service_role;
