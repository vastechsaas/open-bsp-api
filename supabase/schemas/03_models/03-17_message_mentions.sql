create table public.message_mentions (
  organization_id uuid not null,
  message_id uuid not null,
  mentioned_agent_id uuid not null,
  created_at timestamp with time zone default now() not null
);

alter table only public.message_mentions
add constraint message_mentions_pkey
primary key (message_id, mentioned_agent_id);

alter table only public.message_mentions
add constraint message_mentions_message_fkey
foreign key (organization_id, message_id)
references public.messages(organization_id, id)
on delete cascade;

alter table only public.message_mentions
add constraint message_mentions_agent_fkey
foreign key (organization_id, mentioned_agent_id)
references public.agents(organization_id, id)
on delete cascade;

create index message_mentions_recipient_time_idx
on public.message_mentions
using btree (
  organization_id,
  mentioned_agent_id,
  created_at desc,
  message_id
);

create index message_mentions_message_id_idx
on public.message_mentions
using btree (message_id);
