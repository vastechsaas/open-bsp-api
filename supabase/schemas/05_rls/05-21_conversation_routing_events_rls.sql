alter table public.conversation_routing_events enable row level security;

revoke all on table public.conversation_routing_events from anon, authenticated;
grant all on table public.conversation_routing_events to service_role;
