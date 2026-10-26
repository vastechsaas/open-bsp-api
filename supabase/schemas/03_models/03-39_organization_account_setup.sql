alter table public.organization_provisioning add column setup_version integer not null default 1 check (setup_version in (1,2));

-- Safe orchestration references only. Credentials live exclusively in Auth.
create table public.organization_provisioning_people (
  provisioning_id uuid not null references public.organization_provisioning(id) on delete cascade,
  member_id uuid not null,
  client_key text not null check (char_length(client_key) between 1 and 64),
  ordinal integer not null check (ordinal >= 0),
  mode text not null check (mode in ('invitation','direct','pending')),
  request_id uuid not null default gen_random_uuid() unique,
  name text not null,
  email text not null,
  role public.role not null check (role in ('owner','supervisor','agent')),
  expected_updated_at timestamptz not null,
  failure_code text,
  primary key (provisioning_id, member_id),
  unique(provisioning_id,client_key),
  unique(provisioning_id,ordinal)
);
alter table public.organization_provisioning_people enable row level security;
revoke all on public.organization_provisioning_people from anon,authenticated;
grant all on public.organization_provisioning_people to service_role;
