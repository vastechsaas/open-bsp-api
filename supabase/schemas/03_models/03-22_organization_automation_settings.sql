create table public.organization_automation_settings (
  organization_id uuid not null,
  auto_save_whatsapp_contacts boolean default true not null,
  updated_at timestamp with time zone default now() not null,
  updated_by_user_id uuid,
  updated_by_scope text default 'system' not null
);

alter table only public.organization_automation_settings
add constraint organization_automation_settings_pkey
primary key (organization_id);

alter table only public.organization_automation_settings
add constraint organization_automation_settings_organization_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

alter table only public.organization_automation_settings
add constraint organization_automation_settings_updated_by_user_fkey
foreign key (updated_by_user_id)
references auth.users(id)
on delete set null;

alter table only public.organization_automation_settings
add constraint organization_automation_settings_scope_check
check (updated_by_scope in ('system', 'organization', 'platform'));

create trigger initialize_organization_automation_settings
after insert
on public.organizations
for each row
execute function public.initialize_organization_automation_settings();
