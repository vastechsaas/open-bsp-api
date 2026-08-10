alter table public.platform_admins enable row level security;
alter table public.platform_admin_access_events enable row level security;

revoke all on table public.platform_admins from anon, authenticated;
revoke all on table public.platform_admin_access_events from anon, authenticated;
