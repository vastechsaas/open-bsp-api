create table public.contacts (
  organization_id uuid not null,
  id uuid default gen_random_uuid() not null,
  name text,
  email text,
  company text,
  job_title text,
  city text,
  country text,
  extra jsonb,
  status text default 'active'::text not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.contacts
add constraint contacts_pkey
primary key (id);

alter table only public.contacts
add constraint contacts_organization_id_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

alter table only public.contacts
add constraint contacts_email_check
check (
  email is null
  or (
    char_length(email) <= 254
    and email ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  )
);

alter table only public.contacts
add constraint contacts_company_check
check (company is null or char_length(company) <= 200);

alter table only public.contacts
add constraint contacts_job_title_check
check (job_title is null or char_length(job_title) <= 120);

alter table only public.contacts
add constraint contacts_city_check
check (city is null or char_length(city) <= 120);

alter table only public.contacts
add constraint contacts_country_check
check (country is null or char_length(country) <= 120);

create index contacts_organization_id_idx
on public.contacts
using btree (organization_id);

create index contacts_organization_id_created_at_idx
on public.contacts
using btree (organization_id, created_at desc);

create trigger set_extra
before update
on public.contacts
for each row
when (
  new.extra is not null
)
execute function public.merge_update('extra');

create trigger set_updated_at
before update
on public.contacts
for each row
execute function public.moddatetime('updated_at');

create trigger z_notify_webhook_contacts
after insert or update
on public.contacts
for each row
execute function public.notify_webhook();


