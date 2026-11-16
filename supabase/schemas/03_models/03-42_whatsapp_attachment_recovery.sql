create table public.whatsapp_attachment_recovery_jobs (
  message_id uuid primary key references public.messages(id) on delete cascade,
  media_id text not null check (media_id ~ '^[0-9]{1,40}$'),
  state text not null default 'pending' check (state in (
    'pending', 'ready', 'failed', 'unavailable', 'credentials', 'storage', 'too_large', 'cancelled'
  )),
  next_attempt_at timestamptz not null default now(),
  automatic_attempts integer not null default 0 check (automatic_attempts between 0 and 4),
  manual_attempts integer not null default 0 check (manual_attempts between 0 and 2),
  manual boolean not null default false,
  manual_requested_at timestamptz,
  lease_token uuid,
  lease_until timestamptz,
  check ((lease_token is null) = (lease_until is null))
);

alter table public.whatsapp_attachment_recovery_jobs enable row level security;
revoke all on table public.whatsapp_attachment_recovery_jobs from public, anon, authenticated;

create index whatsapp_attachment_recovery_jobs_due_idx
on public.whatsapp_attachment_recovery_jobs (next_attempt_at, message_id) where state = 'pending';
