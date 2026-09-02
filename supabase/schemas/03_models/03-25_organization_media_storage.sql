create table public.organization_media_storage (
  organization_id uuid not null,
  quota_bytes bigint default 25000000000 not null,
  used_bytes bigint default 0 not null,
  object_count bigint default 0 not null,
  updated_by uuid,
  updated_by_scope text default 'system' not null,
  last_reconciled_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.organization_media_storage
add constraint organization_media_storage_pkey
primary key (organization_id);

alter table only public.organization_media_storage
add constraint organization_media_storage_organization_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

alter table only public.organization_media_storage
add constraint organization_media_storage_updated_by_fkey
foreign key (updated_by)
references auth.users(id)
on delete set null;

alter table only public.organization_media_storage
add constraint organization_media_storage_quota_check
check (quota_bytes in (25000000000, 50000000000, 75000000000, 100000000000));

alter table only public.organization_media_storage
add constraint organization_media_storage_usage_check
check (used_bytes >= 0 and object_count >= 0);

alter table only public.organization_media_storage
add constraint organization_media_storage_scope_check
check (updated_by_scope in ('platform', 'system'));

create index organization_media_storage_status_idx
on public.organization_media_storage (quota_bytes, used_bytes desc, organization_id);

create index organization_media_storage_reconciliation_idx
on public.organization_media_storage (last_reconciled_at nulls first, organization_id);

create trigger set_updated_at
before update on public.organization_media_storage
for each row
execute function public.moddatetime('updated_at');
