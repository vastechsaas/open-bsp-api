-- Missing preferences mean enabled, preserving existing and new organizations.
create table public.organization_notification_preferences (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  notification_type text not null,
  enabled boolean default true not null,
  updated_at timestamptz default now() not null,
  updated_by_user_id uuid references auth.users(id) on delete set null,
  primary key (organization_id, notification_type),
  constraint organization_notification_preferences_type_check check (
    notification_type in (
      'conversation_assigned',
      'conversation_transferred_to_agent',
      'conversation_transferred_to_queue',
      'private_note_mention'
    )
  )
);
