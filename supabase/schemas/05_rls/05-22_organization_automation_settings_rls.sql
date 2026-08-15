alter table public.organization_automation_settings enable row level security;

revoke all on table public.organization_automation_settings from anon, authenticated;
