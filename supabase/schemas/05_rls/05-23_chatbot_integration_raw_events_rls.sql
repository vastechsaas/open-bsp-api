alter table public.chatbot_integration_raw_events enable row level security;

revoke all on table public.chatbot_integration_raw_events from public, anon, authenticated;
grant all on table public.chatbot_integration_raw_events to service_role;
