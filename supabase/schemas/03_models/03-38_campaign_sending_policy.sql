-- Policies and accounting are backend-only. UI uses scoped, authorized RPCs.
create table public.campaign_sending_policies (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  enabled boolean not null default false,
  daily_limit integer check (daily_limit between 1 and 1000000000),
  max_sends_per_minute integer check (max_sends_per_minute between 1 and 60000),
  recipient_cap integer check (recipient_cap between 1 and 1000000),
  budget_timezone text not null default 'UTC',
  revision bigint not null default 0,
  updated_at timestamptz not null default now(),
  check (not enabled or (daily_limit is not null and max_sends_per_minute is not null and recipient_cap is not null))
);
alter table public.campaign_sending_policies enable row level security;
revoke all on public.campaign_sending_policies from public, anon, authenticated;
grant all on public.campaign_sending_policies to service_role;

-- One row per actual submission boundary, including rejected attempts. Retain
-- accounting when a campaign is deleted so deletion cannot replenish allowance.
create table public.campaign_send_ledger (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  job_id uuid unique references public.campaign_dispatch_jobs(id) on delete set null,
  delivery_id uuid references public.campaign_deliveries(id) on delete set null,
  legacy_delivery_id uuid unique,
  organization_address text not null,
  recipient_key text not null,
  submitted_at timestamptz not null default clock_timestamp(),
  accepted_at timestamptz,
  state text not null check (state in ('reserved', 'accepted', 'released'))
);
create index campaign_send_ledger_daily_idx on public.campaign_send_ledger (organization_id, submitted_at) where state <> 'released';
create index campaign_send_ledger_recipient_idx on public.campaign_send_ledger (organization_id, recipient_key, submitted_at) where state <> 'released';
create index campaign_send_ledger_rate_idx on public.campaign_send_ledger (organization_id, organization_address, submitted_at);
alter table public.campaign_send_ledger enable row level security;
revoke all on public.campaign_send_ledger from public, anon, authenticated;
grant all on public.campaign_send_ledger to service_role;
