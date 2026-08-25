alter table public.organization_agent_capacity enable row level security;

revoke all on table public.organization_agent_capacity from anon, authenticated;
