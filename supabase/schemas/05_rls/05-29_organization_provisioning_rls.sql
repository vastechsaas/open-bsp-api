alter table public.organization_provisioning enable row level security;
alter table public.organization_provisioning_events enable row level security;

revoke all on table public.organization_provisioning from anon, authenticated;
revoke all on table public.organization_provisioning_events from anon, authenticated;
