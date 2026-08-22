create table public.user_notifications (
  organization_id uuid not null,
  id uuid default gen_random_uuid() not null,
  recipient_agent_id uuid not null,
  actor_agent_id uuid,
  conversation_id uuid,
  notification_type text not null,
  source_event_key text not null,
  payload jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  read_at timestamp with time zone,
  resolved_at timestamp with time zone
);

alter table only public.user_notifications
add constraint user_notifications_pkey
primary key (id);

alter table only public.user_notifications
add constraint user_notifications_organization_id_fkey
foreign key (organization_id)
references public.organizations(id)
on delete cascade;

alter table only public.user_notifications
add constraint user_notifications_recipient_agent_fkey
foreign key (organization_id, recipient_agent_id)
references public.agents(organization_id, id)
on delete cascade;

alter table only public.user_notifications
add constraint user_notifications_actor_agent_fkey
foreign key (organization_id, actor_agent_id)
references public.agents(organization_id, id)
on delete set null (actor_agent_id);

alter table only public.user_notifications
add constraint user_notifications_conversation_fkey
foreign key (organization_id, conversation_id)
references public.conversations(organization_id, id)
on delete cascade;

alter table only public.user_notifications
add constraint user_notifications_recipient_source_key
unique (organization_id, recipient_agent_id, source_event_key);

alter table only public.user_notifications
add constraint user_notifications_type_check
check (
  notification_type in (
    'conversation_assigned',
    'conversation_transferred_to_agent',
    'conversation_transferred_to_queue',
    'private_note_mention'
  )
);

alter table only public.user_notifications
add constraint user_notifications_source_event_key_check
check (length(btrim(source_event_key)) > 0);

alter table only public.user_notifications
add constraint user_notifications_payload_check
check (jsonb_typeof(payload) = 'object');

alter table only public.user_notifications
add constraint user_notifications_read_at_check
check (read_at is null or read_at >= created_at);

alter table only public.user_notifications
add constraint user_notifications_resolved_at_check
check (resolved_at is null or resolved_at >= created_at);

create index user_notifications_recipient_time_idx
on public.user_notifications
using btree (
  organization_id,
  recipient_agent_id,
  created_at desc,
  id desc
);

create index user_notifications_unread_idx
on public.user_notifications
using btree (
  organization_id,
  recipient_agent_id,
  created_at desc,
  id desc
)
where (
  read_at is null
  and resolved_at is null
);

create index user_notifications_conversation_idx
on public.user_notifications
using btree (organization_id, conversation_id)
where conversation_id is not null;

alter table public.user_notifications replica identity full;
