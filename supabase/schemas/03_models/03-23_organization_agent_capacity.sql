create table public.organization_agent_capacity (
  organization_id uuid not null,
  max_agent_seats integer,
  updated_by uuid,
  updated_by_scope text default 'platform' not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.organization_agent_capacity
add constraint organization_agent_capacity_pkey
primary key (organization_id);

alter table only public.organization_agent_capacity
add constraint organization_agent_capacity_organization_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

alter table only public.organization_agent_capacity
add constraint organization_agent_capacity_updated_by_fkey
foreign key (updated_by)
references auth.users(id)
on delete set null;

alter table only public.organization_agent_capacity
add constraint organization_agent_capacity_limit_check
check (max_agent_seats is null or max_agent_seats > 0);

alter table only public.organization_agent_capacity
add constraint organization_agent_capacity_scope_check
check (updated_by_scope = 'platform');

create trigger set_updated_at
before update on public.organization_agent_capacity
for each row
execute function public.moddatetime('updated_at');
