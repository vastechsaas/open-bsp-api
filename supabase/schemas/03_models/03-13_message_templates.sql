create table public.message_templates (
  organization_id uuid not null,
  id uuid default gen_random_uuid() not null,
  organization_address text not null,
  created_by uuid,
  external_id text,
  name text not null,
  language text not null,
  category text not null,
  status text default 'draft'::text not null,
  components jsonb default '[]'::jsonb not null,
  rejection_reason text,
  submitted_at timestamp with time zone,
  synced_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.message_templates
add constraint message_templates_pkey
primary key (id);

alter table only public.message_templates
add constraint message_templates_organization_id_id_key
unique (organization_id, id);

alter table only public.message_templates
add constraint message_templates_account_name_language_key
unique (organization_id, organization_address, name, language);

alter table only public.message_templates
add constraint message_templates_organization_external_id_key
unique (organization_id, external_id);

alter table only public.message_templates
add constraint message_templates_organization_id_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

alter table only public.message_templates
add constraint message_templates_created_by_fkey
foreign key (created_by)
references public.agents(id)
on delete set null;

alter table only public.message_templates
add constraint message_templates_organization_address_fkey
foreign key (organization_id, organization_address)
references public.organizations_addresses(organization_id, address)
on delete cascade;

alter table only public.message_templates
add constraint message_templates_name_check
check (length(btrim(name)) > 0);

alter table only public.message_templates
add constraint message_templates_language_check
check (length(btrim(language)) > 0);

alter table only public.message_templates
add constraint message_templates_category_check
check (category in ('utility', 'marketing', 'authentication'));

alter table only public.message_templates
add constraint message_templates_status_check
check (
  status in (
    'draft',
    'pending',
    'approved',
    'in_appeal',
    'rejected',
    'pending_deletion',
    'deleted',
    'disabled',
    'paused',
    'limit_exceeded'
  )
);

alter table only public.message_templates
add constraint message_templates_components_check
check (jsonb_typeof(components) = 'array');

alter table only public.message_templates
add constraint message_templates_external_state_check
check (
  (status = 'draft' and external_id is null)
  or (status <> 'draft' and external_id is not null)
);

create index message_templates_organization_updated_at_idx
on public.message_templates
using btree (organization_id, updated_at desc, id desc);

create index message_templates_organization_account_idx
on public.message_templates
using btree (organization_id, organization_address);

create index message_templates_organization_category_status_idx
on public.message_templates
using btree (organization_id, category, status);

create trigger set_updated_at
before update
on public.message_templates
for each row
execute function public.moddatetime('updated_at');

grant delete, insert, references, select, trigger, truncate, update
on table public.message_templates
to anon, authenticated, service_role;
