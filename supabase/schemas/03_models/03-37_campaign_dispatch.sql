-- Deployment-managed tenant opt-in; disabling affects new runs only.
create table public.campaign_dispatch_settings (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  enabled boolean not null default false
);
alter table public.campaign_dispatch_settings enable row level security;
revoke all on table public.campaign_dispatch_settings from public, anon, authenticated;
grant all on table public.campaign_dispatch_settings to service_role;

-- Each row is both a durable attempt and its transactional publishing outbox.
-- No credential, message content or recipient address is copied here.
alter table public.campaign_deliveries add constraint campaign_deliveries_job_identity_key unique (organization_id, campaign_id, id);
create table public.campaign_dispatch_jobs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  campaign_id uuid not null,
  delivery_id uuid not null,
  attempt_no integer not null default 1 check (attempt_no between 1 and 3),
  phase text not null default 'pending' check (phase in
    ('pending', 'preparing', 'submitting', 'accepted', 'failed', 'retry_scheduled', 'needs_review')),
  due_at timestamptz not null default now(),
  publish_after timestamptz not null default now(),
  publication_token uuid,
  publication_expires_at timestamptz,
  lease_token uuid,
  lease_expires_at timestamptz,
  send_started_at timestamptz,
  external_id text,
  error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (delivery_id, attempt_no),
  foreign key (organization_id, campaign_id, delivery_id) references public.campaign_deliveries(organization_id, campaign_id, id) on delete cascade,
  foreign key (organization_id, campaign_id) references public.campaigns(organization_id, id) on delete cascade
);
create index campaign_dispatch_jobs_publication_idx on public.campaign_dispatch_jobs (publish_after, id) where phase = 'pending';
create index campaign_dispatch_jobs_recovery_idx on public.campaign_dispatch_jobs (lease_expires_at, id) where phase in ('preparing', 'submitting');
alter table public.campaign_dispatch_jobs enable row level security;
revoke all on table public.campaign_dispatch_jobs from public, anon, authenticated;
grant all on table public.campaign_dispatch_jobs to service_role;
