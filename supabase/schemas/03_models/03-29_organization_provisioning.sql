create table public.organization_provisioning (
  id uuid default gen_random_uuid() not null,
  request_id uuid not null,
  platform_admin_user_id uuid not null,
  organization_id uuid,
  organization_name text not null,
  request_payload jsonb not null,
  status text default 'pending_invitation' not null,
  invitation_agent_ids uuid[] default array[]::uuid[] not null,
  attempt_count integer default 0 not null,
  last_error text,
  completed_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.organization_provisioning
add constraint organization_provisioning_pkey primary key (id);

alter table only public.organization_provisioning
add constraint organization_provisioning_admin_fkey
foreign key (platform_admin_user_id)
references public.platform_admins(user_id);

alter table only public.organization_provisioning
add constraint organization_provisioning_organization_fkey
foreign key (organization_id)
references public.organizations(id)
on delete set null;

alter table only public.organization_provisioning
add constraint organization_provisioning_status_check
check (status in ('pending_invitation', 'completed', 'failed'));

alter table only public.organization_provisioning
add constraint organization_provisioning_attempt_count_check
check (attempt_count >= 0);

alter table only public.organization_provisioning
add constraint organization_provisioning_admin_request_key
unique (platform_admin_user_id, request_id);

create unique index organization_provisioning_organization_key
on public.organization_provisioning (organization_id)
where organization_id is not null;

create index organization_provisioning_status_time_idx
on public.organization_provisioning (status, updated_at desc, id desc);

create trigger set_updated_at
before update on public.organization_provisioning
for each row execute function public.moddatetime('updated_at');

create table public.organization_provisioning_events (
  id uuid default gen_random_uuid() not null,
  provisioning_id uuid not null,
  platform_admin_user_id uuid not null,
  organization_id uuid,
  event_type text not null,
  details jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null
);

alter table only public.organization_provisioning_events
add constraint organization_provisioning_events_pkey primary key (id);

alter table only public.organization_provisioning_events
add constraint organization_provisioning_events_provisioning_fkey
foreign key (provisioning_id)
references public.organization_provisioning(id)
on delete cascade;

alter table only public.organization_provisioning_events
add constraint organization_provisioning_events_admin_fkey
foreign key (platform_admin_user_id)
references public.platform_admins(user_id);

alter table only public.organization_provisioning_events
add constraint organization_provisioning_events_type_check
check (event_type in ('started', 'retried', 'completed', 'failed'));

create index organization_provisioning_events_provisioning_time_idx
on public.organization_provisioning_events (provisioning_id, created_at, id);
