alter table public.chatbot_webhook_credentials enable row level security;

revoke all on table public.chatbot_webhook_credentials from anon, authenticated;
grant select on table public.chatbot_webhook_credentials to anon, authenticated;
grant all on table public.chatbot_webhook_credentials to service_role;

create policy "admins can read their orgs chatbot webhook credentials"
on public.chatbot_webhook_credentials
for select
to authenticated, anon
using (
  organization_id in (
    select public.get_authorized_orgs('admin')
  )
);
