create table public.organization_module_settings (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  module text not null check (module = 'chatbot_builder'),
  revision bigint not null default 0 check (revision >= 0),
  updated_at timestamptz not null default now(),
  primary key (organization_id, module)
);

create table public.organization_module_permissions (
  organization_id uuid not null,
  module text not null,
  role public.role not null,
  can_view boolean not null,
  can_manage boolean not null,
  primary key (organization_id, module, role),
  foreign key (organization_id, module) references public.organization_module_settings(organization_id, module) on delete cascade,
  check (not can_manage or can_view)
);

alter table public.organization_module_settings enable row level security;
alter table public.organization_module_permissions enable row level security;
revoke all on public.organization_module_settings, public.organization_module_permissions from anon, authenticated;
grant all on public.organization_module_settings, public.organization_module_permissions to service_role;
