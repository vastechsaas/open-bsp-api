-- Catalogue rows are deployment-managed. New connectors are opt-in by default.
create table public.integration_catalogue (
  id text primary key check (id ~ '^[a-z][a-z0-9_]{0,63}$'),
  name text not null,
  default_enabled boolean not null default false
);

create table public.organization_integration_settings (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  revision bigint not null default 0 check (revision >= 0),
  updated_at timestamptz not null default now()
);

create table public.organization_integration_availability (
  organization_id uuid not null references public.organization_integration_settings(organization_id) on delete cascade,
  integration_id text not null references public.integration_catalogue(id),
  enabled boolean not null,
  primary key (organization_id, integration_id)
);

alter table public.integration_catalogue enable row level security;
alter table public.organization_integration_settings enable row level security;
alter table public.organization_integration_availability enable row level security;
revoke all on public.integration_catalogue, public.organization_integration_settings, public.organization_integration_availability from anon, authenticated;
grant all on public.integration_catalogue, public.organization_integration_settings, public.organization_integration_availability to service_role;

-- Data is also explicitly seeded in the generated migration (diffs omit data).
insert into public.integration_catalogue(id, name, default_enabled)
values ('whatsapp', 'WhatsApp', true), ('instagram', 'Instagram', true)
on conflict do nothing;
