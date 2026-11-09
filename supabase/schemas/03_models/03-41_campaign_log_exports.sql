-- Temporary, private export snapshots. Never part of campaign dispatch state.
create table public.campaign_log_exports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  campaign_id uuid not null,
  owner_id uuid not null references auth.users(id) on delete cascade,
  request_id uuid not null,
  state text not null default 'queued' check (state in ('queued','processing','ready','failed')),
  snapshot_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null default (clock_timestamp()+interval '24 hours'),
  timezone text not null,
  template jsonb not null,
  mapping jsonb not null,
  sender_number text not null,
  display_name text not null,
  row_count bigint not null default 0,
  processed_count bigint not null default 0,
  lease_token uuid,
  lease_until timestamptz,
  failures integer not null default 0,
  ticket_hash text,
  ticket_until timestamptz,
  unique (owner_id,request_id),
  foreign key (organization_id,campaign_id) references public.campaigns(organization_id,id) on delete cascade,
  check (processed_count between 0 and row_count)
);
create index campaign_log_exports_pending_idx on public.campaign_log_exports(state,lease_until,snapshot_at);
create index campaign_log_exports_lookup_idx on public.campaign_log_exports(organization_id,campaign_id,owner_id,snapshot_at desc);

create table public.campaign_log_export_rows (
  export_id uuid not null references public.campaign_log_exports(id) on delete cascade,
  ordinal bigint not null,
  sent_at timestamptz,
  recipient text not null,
  recipient_name text,
  variables jsonb not null,
  status text not null check (status in ('Delivered','Not Delivered','')),
  primary key (export_id,ordinal)
);
create table public.campaign_log_export_parts (
  export_id uuid not null references public.campaign_log_exports(id) on delete cascade,
  part_no bigint not null,
  path text not null,
  primary key (export_id,part_no)
);
alter table public.campaign_log_exports enable row level security;
alter table public.campaign_log_export_rows enable row level security;
alter table public.campaign_log_export_parts enable row level security;
revoke all on public.campaign_log_exports,public.campaign_log_export_rows,public.campaign_log_export_parts from public,anon,authenticated;
grant all on public.campaign_log_exports,public.campaign_log_export_rows,public.campaign_log_export_parts to service_role;
