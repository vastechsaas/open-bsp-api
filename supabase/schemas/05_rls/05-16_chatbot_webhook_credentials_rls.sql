alter table public.chatbot_webhook_credentials enable row level security;

create policy "admins can read their orgs chatbot webhook credentials"
on public.chatbot_webhook_credentials
for select
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('admin')
  )
);
