-- Private retry accounting for media analysis, not message delivery.
create table public.media_preprocessing_jobs (
  message_id uuid primary key,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  state text not null check (state in ('queued','processing','retry_wait','succeeded','skipped','failed')),
  attempts integer not null default 0 check (attempts between 0 and 3),
  lease_token uuid,
  next_attempt_at timestamptz not null default clock_timestamp(),
  last_error_code text,
  updated_at timestamptz not null default clock_timestamp(),
  foreign key (organization_id,message_id) references public.messages(organization_id,id) on delete cascade
);
create index media_preprocessing_jobs_due_idx on public.media_preprocessing_jobs(next_attempt_at,message_id)
  where state in ('queued','processing','retry_wait');
alter table public.media_preprocessing_jobs enable row level security;
revoke all on public.media_preprocessing_jobs from public,anon,authenticated;
grant all on public.media_preprocessing_jobs to service_role;
