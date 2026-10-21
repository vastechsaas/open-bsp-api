-- Account setup is distinct from organization membership and from Auth credentials.
create table public.platform_user_onboarding (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  member_id uuid not null,
  administrator_id uuid not null references auth.users(id),
  request_id uuid not null,
  intended_user_id uuid not null default gen_random_uuid(),
  email text not null,
  name text not null,
  role public.role not null check (role in ('owner','supervisor','agent')),
  mode text not null check (mode in ('direct','invitation')),
  status text not null default 'reserved' check (status in ('reserved','account_created','invitation_sent','completing','completed','revoked')),
  failure_code text,
  generation integer not null default 0,
  context_hash text,
  context_expires_at timestamptz,
  delivery_request_id uuid,
  delivery_accepted_at timestamptz,
  lease_id uuid,
  lease_until timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique(administrator_id,request_id),
  unique(intended_user_id)
);
create unique index platform_user_onboarding_email_reservation on public.platform_user_onboarding(email)
  where status not in ('completed','revoked');
create index platform_user_onboarding_member on public.platform_user_onboarding(organization_id,member_id,created_at desc);
alter table public.platform_user_onboarding enable row level security;
revoke all on public.platform_user_onboarding from anon,authenticated;

create table public.platform_user_onboarding_events (
  id bigint generated always as identity primary key,
  operation_id uuid not null references public.platform_user_onboarding(id) on delete cascade,
  actor_user_id uuid not null,
  event text not null,
  code text,
  member_state jsonb not null,
  created_at timestamptz not null default clock_timestamp()
);
alter table public.platform_user_onboarding_events enable row level security;
revoke all on public.platform_user_onboarding_events from anon,authenticated;
-- Events are append-only even for service callers. Owner maintenance/purge is unchanged.
revoke update,delete on public.platform_user_onboarding_events from service_role;
