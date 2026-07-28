create table public.chatbot_webhook_credentials (
  organization_id uuid not null,
  id uuid default gen_random_uuid() not null,
  created_by uuid,
  name text not null,
  vault_secret_id uuid not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.chatbot_webhook_credentials
add constraint chatbot_webhook_credentials_pkey
primary key (id);

alter table only public.chatbot_webhook_credentials
add constraint chatbot_webhook_credentials_organization_id_id_key
unique (organization_id, id);

alter table only public.chatbot_webhook_credentials
add constraint chatbot_webhook_credentials_organization_id_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

alter table only public.chatbot_webhook_credentials
add constraint chatbot_webhook_credentials_created_by_fkey
foreign key (organization_id, created_by)
references public.agents(organization_id, id)
on delete set null (created_by);

alter table only public.chatbot_webhook_credentials
add constraint chatbot_webhook_credentials_vault_secret_id_key
unique (vault_secret_id);

alter table only public.chatbot_webhook_credentials
add constraint chatbot_webhook_credentials_name_check
check (length(btrim(name)) > 0);

create unique index chatbot_webhook_credentials_organization_name_key
on public.chatbot_webhook_credentials (organization_id, lower(btrim(name)));

create trigger set_updated_at
before update
on public.chatbot_webhook_credentials
for each row
execute function public.moddatetime('updated_at');

grant select
on table public.chatbot_webhook_credentials
to anon, authenticated;

grant delete, select
on table public.chatbot_webhook_credentials
to service_role;
