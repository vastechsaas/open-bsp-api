create table public.platform_admins (
  user_id uuid not null,
  active boolean default true not null,
  created_by uuid,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.platform_admins
add constraint platform_admins_pkey
primary key (user_id);

alter table only public.platform_admins
add constraint platform_admins_user_id_fkey
foreign key (user_id)
references auth.users(id)
on delete cascade;

alter table only public.platform_admins
add constraint platform_admins_created_by_fkey
foreign key (created_by)
references auth.users(id)
on delete set null;

create index platform_admins_active_idx
on public.platform_admins (active)
where active = true;

create trigger set_updated_at
before update
on public.platform_admins
for each row
execute function public.moddatetime('updated_at');

create table public.platform_admin_access_events (
  id uuid default gen_random_uuid() not null,
  platform_admin_user_id uuid not null,
  organization_id uuid,
  scope text not null,
  request_id uuid not null,
  accessed_at timestamp with time zone default now() not null
);

alter table only public.platform_admin_access_events
add constraint platform_admin_access_events_pkey
primary key (id);

alter table only public.platform_admin_access_events
add constraint platform_admin_access_events_admin_fkey
foreign key (platform_admin_user_id)
references public.platform_admins(user_id);

alter table only public.platform_admin_access_events
add constraint platform_admin_access_events_scope_check
check (
  (scope = 'global' and organization_id is null)
  or (scope = 'tenant' and organization_id is not null)
);

alter table only public.platform_admin_access_events
add constraint platform_admin_access_events_request_key
unique (platform_admin_user_id, request_id);

create index platform_admin_access_events_admin_time_idx
on public.platform_admin_access_events (
  platform_admin_user_id,
  accessed_at desc
);

create index platform_admin_access_events_organization_time_idx
on public.platform_admin_access_events (
  organization_id,
  accessed_at desc
)
where organization_id is not null;
