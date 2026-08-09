create table public.quick_replies (
  id uuid default gen_random_uuid() not null,
  organization_id uuid not null,
  shortcut text not null,
  content text not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only public.quick_replies
add constraint quick_replies_pkey
primary key (id);

alter table only public.quick_replies
add constraint quick_replies_organization_id_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

create index quick_replies_organization_idx
on public.quick_replies
using btree (organization_id);

alter table only public.quick_replies
add constraint quick_replies_organization_shortcut_key
unique (organization_id, shortcut);

alter table only public.quick_replies
add constraint quick_replies_shortcut_check
check (
  char_length(shortcut) between 2 and 30
  and shortcut ~ '^/[a-z0-9_-]+$'
);

create trigger set_updated_at
before update
on public.quick_replies
for each row
execute function public.moddatetime('updated_at');
