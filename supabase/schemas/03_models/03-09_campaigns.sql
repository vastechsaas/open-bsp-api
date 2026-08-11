create table public.campaigns (
  organization_id uuid not null,
  id uuid default gen_random_uuid() not null,
  created_by uuid,
  name text not null,
  service public.service default 'whatsapp'::public.service not null,
  organization_address text not null,
  template jsonb not null,
  template_variable_mapping jsonb default '{}'::jsonb not null,
  header_media jsonb,
  audience_type public.campaign_audience_type not null,
  status text default 'draft'::text not null,
  queued_count integer default 0 not null,
  processing_count integer default 0 not null,
  accepted_count integer default 0 not null,
  failed_count integer default 0 not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.campaigns
add constraint campaigns_pkey
primary key (id);

alter table only public.campaigns
add constraint campaigns_organization_id_id_key
unique (organization_id, id);

alter table only public.campaigns
add constraint campaigns_organization_id_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

alter table only public.campaigns
add constraint campaigns_created_by_fkey
foreign key (created_by)
references public.agents(id)
on delete set null;

alter table only public.campaigns
add constraint campaigns_organization_address_fkey
foreign key (organization_id, organization_address)
references public.organizations_addresses(organization_id, address)
on delete no action;

alter table only public.campaigns
add constraint campaigns_name_check
check (length(btrim(name)) > 0);

alter table only public.campaigns
add constraint campaigns_service_check
check (service = 'whatsapp'::public.service);

alter table only public.campaigns
add constraint campaigns_status_check
check (status in ('draft', 'queued', 'running', 'completed', 'failed'));

alter table only public.campaigns
add constraint campaigns_delivery_counts_check
check (
  queued_count >= 0
  and processing_count >= 0
  and accepted_count >= 0
  and failed_count >= 0
);

alter table only public.campaigns
add constraint campaigns_template_check
check (
  jsonb_typeof(template) = 'object'
  and length(coalesce(template->>'id', '')) > 0
  and length(coalesce(template->>'name', '')) > 0
  and length(coalesce(template->>'language', '')) > 0
  and template->>'status' = 'APPROVED'
);

alter table only public.campaigns
add constraint campaigns_template_variable_mapping_check
check (jsonb_typeof(template_variable_mapping) = 'object');

alter table only public.campaigns
add constraint campaigns_header_media_check
check (
  header_media is null
  or (
    jsonb_typeof(header_media) = 'object'
    and header_media->>'format' in ('IMAGE', 'VIDEO', 'DOCUMENT')
    and length(coalesce(header_media->>'media_id', '')) > 0
    and length(coalesce(header_media->>'file_name', '')) > 0
    and length(coalesce(header_media->>'mime_type', '')) > 0
    and (header_media->>'size')::bigint > 0
  )
);

create index campaigns_organization_id_idx
on public.campaigns
using btree (organization_id);

create index campaigns_organization_updated_at_idx
on public.campaigns
using btree (organization_id, updated_at desc);

create trigger set_updated_at
before update
on public.campaigns
for each row
execute function public.moddatetime('updated_at');

create table public.campaign_csv_recipients (
  organization_id uuid not null,
  campaign_id uuid not null,
  id uuid default gen_random_uuid() not null,
  contact_address text not null,
  name text,
  variables jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.campaign_csv_recipients
add constraint campaign_csv_recipients_pkey
primary key (id);

alter table only public.campaign_csv_recipients
add constraint campaign_csv_recipients_campaign_fkey
foreign key (organization_id, campaign_id)
references public.campaigns(organization_id, id)
on delete cascade;

alter table only public.campaign_csv_recipients
add constraint campaign_csv_recipients_campaign_address_key
unique (campaign_id, contact_address);

alter table only public.campaign_csv_recipients
add constraint campaign_csv_recipients_contact_address_check
check (length(btrim(contact_address)) > 0);

alter table only public.campaign_csv_recipients
add constraint campaign_csv_recipients_variables_check
check (jsonb_typeof(variables) = 'object');

create index campaign_csv_recipients_organization_id_idx
on public.campaign_csv_recipients
using btree (organization_id);

create index campaign_csv_recipients_campaign_id_idx
on public.campaign_csv_recipients
using btree (campaign_id);

create trigger set_updated_at
before update
on public.campaign_csv_recipients
for each row
execute function public.moddatetime('updated_at');

create table public.campaign_deliveries (
  organization_id uuid not null,
  campaign_id uuid not null,
  id uuid default gen_random_uuid() not null,
  contact_address text not null,
  name text,
  variables jsonb default '{}'::jsonb not null,
  status text default 'queued'::text not null,
  attempts integer default 0 not null,
  external_id text,
  error jsonb,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.campaign_deliveries
add constraint campaign_deliveries_pkey
primary key (id);

alter table only public.campaign_deliveries
add constraint campaign_deliveries_campaign_fkey
foreign key (organization_id, campaign_id)
references public.campaigns(organization_id, id)
on delete cascade;

alter table only public.campaign_deliveries
add constraint campaign_deliveries_campaign_address_key
unique (campaign_id, contact_address);

alter table only public.campaign_deliveries
add constraint campaign_deliveries_external_id_key
unique (external_id);

alter table only public.campaign_deliveries
add constraint campaign_deliveries_contact_address_check
check (length(btrim(contact_address)) > 0);

alter table only public.campaign_deliveries
add constraint campaign_deliveries_variables_check
check (jsonb_typeof(variables) = 'object');

alter table only public.campaign_deliveries
add constraint campaign_deliveries_status_check
check (status in ('queued', 'processing', 'accepted', 'failed'));

alter table only public.campaign_deliveries
add constraint campaign_deliveries_attempts_check
check (attempts >= 0);

create index campaign_deliveries_organization_id_idx
on public.campaign_deliveries
using btree (organization_id);

create index campaign_deliveries_organization_created_campaign_idx
on public.campaign_deliveries
using btree (organization_id, created_at, campaign_id);

create index campaign_deliveries_campaign_status_idx
on public.campaign_deliveries
using btree (campaign_id, status, created_at);

create trigger set_updated_at
before update
on public.campaign_deliveries
for each row
execute function public.moddatetime('updated_at');

grant delete, insert, references, select, trigger, truncate, update
on table public.campaigns
to anon, authenticated, service_role;

grant delete, insert, references, select, trigger, truncate, update
on table public.campaign_csv_recipients
to anon, authenticated, service_role;

grant delete, insert, references, select, trigger, truncate, update
on table public.campaign_deliveries
to anon, authenticated, service_role;
