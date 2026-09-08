create table public.organization_lifecycle (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  status text default 'active'::text not null,
  archived_at timestamp with time zone,
  archived_by_user_id uuid,
  archived_by_scope text,
  archive_reason text,
  purge_eligible_at timestamp with time zone,
  restored_at timestamp with time zone,
  restored_by_user_id uuid,
  restored_by_scope text,
  restore_reason text,
  address_statuses jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  constraint organization_lifecycle_pkey primary key (organization_id),
  constraint organization_lifecycle_status_check
    check (status in ('active', 'archived')),
  constraint organization_lifecycle_archived_scope_check
    check (archived_by_scope is null or archived_by_scope in ('owner', 'platform_admin')),
  constraint organization_lifecycle_restored_scope_check
    check (restored_by_scope is null or restored_by_scope in ('owner', 'platform_admin'))
);

create index organization_lifecycle_status_purge_idx
on public.organization_lifecycle (status, purge_eligible_at, organization_id);

create trigger set_updated_at
before update on public.organization_lifecycle
for each row execute function public.moddatetime('updated_at');

alter table public.organization_lifecycle enable row level security;
revoke all on table public.organization_lifecycle from anon, authenticated;

create table public.organization_lifecycle_events (
  id uuid default gen_random_uuid() not null primary key,
  organization_id uuid not null,
  organization_name text not null,
  action_type text not null,
  actor_user_id uuid not null,
  actor_scope text not null,
  request_id uuid not null,
  reason text not null,
  before_state jsonb,
  after_state jsonb,
  created_at timestamp with time zone default now() not null,
  constraint organization_lifecycle_events_action_check
    check (action_type in ('organization.archive', 'organization.restore', 'organization.purge')),
  constraint organization_lifecycle_events_scope_check
    check (actor_scope in ('owner', 'platform_admin')),
  constraint organization_lifecycle_events_request_key unique (request_id)
);

create index organization_lifecycle_events_organization_time_idx
on public.organization_lifecycle_events (organization_id, created_at desc, id desc);

alter table public.organization_lifecycle_events enable row level security;
revoke all on table public.organization_lifecycle_events from anon, authenticated;

insert into public.organization_lifecycle (organization_id)
select organization.id
from public.organizations as organization
on conflict (organization_id) do nothing;
