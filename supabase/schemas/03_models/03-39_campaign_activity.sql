-- Dispatch outcomes remain unchanged. Receipts are independent provider evidence.
create table public.campaign_delivery_receipts (
  delivery_id uuid primary key,
  organization_id uuid not null,
  campaign_id uuid not null,
  sent_at timestamptz,
  delivered_at timestamptz,
  read_at timestamptz,
  failed_at timestamptz,
  failure_code text,
  foreign key (organization_id,campaign_id,delivery_id)
    references public.campaign_deliveries(organization_id,campaign_id,id) on delete cascade
);
create index campaign_delivery_receipts_campaign_idx on public.campaign_delivery_receipts(organization_id,campaign_id);

create table public.campaign_activity (
  id bigint generated always as identity primary key,
  organization_id uuid not null,
  campaign_id uuid not null,
  delivery_id uuid,
  job_id uuid,
  attempt_no integer,
  event_type text not null,
  reason_code text,
  actor_user_id uuid,
  actor_name text,
  request_id uuid,
  control_revision bigint,
  provider_at timestamptz,
  recorded_at timestamptz not null default clock_timestamp(),
  deduplication_key text unique,
  foreign key (organization_id,campaign_id) references public.campaigns(organization_id,id) on delete cascade,
  foreign key (organization_id,campaign_id,delivery_id)
    references public.campaign_deliveries(organization_id,campaign_id,id) on delete cascade
);
create index campaign_activity_page_idx on public.campaign_activity(organization_id,campaign_id,recorded_at desc,id desc);

-- Unknown receipts wait here, never in messages (which would create empty chats).
-- Only safe correlation data, no raw payload, phone number, content or credential.
create table public.campaign_receipt_inbox (
  id bigint generated always as identity primary key,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  organization_address text not null,
  external_id text not null check (length(external_id) between 1 and 512),
  receipt_type text not null check (receipt_type in ('sent','delivered','read','failed')),
  provider_at timestamptz not null,
  recorded_at timestamptz not null default clock_timestamp(),
  correlation text check (length(correlation)<=128),
  error_code text check (error_code ~ '^[a-zA-Z0-9_.:-]{1,100}$'),
  processed_at timestamptz,
  next_check_at timestamptz not null default clock_timestamp(),
  unique (organization_id,organization_address,external_id,receipt_type,provider_at)
);
create index campaign_receipt_inbox_pending_idx on public.campaign_receipt_inbox(next_check_at,id) where processed_at is null;

alter table public.campaign_delivery_receipts enable row level security;
alter table public.campaign_activity enable row level security;
alter table public.campaign_receipt_inbox enable row level security;
revoke all on public.campaign_delivery_receipts,public.campaign_activity,public.campaign_receipt_inbox from public,anon,authenticated;
grant all on public.campaign_delivery_receipts,public.campaign_activity,public.campaign_receipt_inbox to service_role;
grant usage,select on sequence public.campaign_activity_id_seq,public.campaign_receipt_inbox_id_seq to service_role;
