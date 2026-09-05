alter table public.organization_ui_settings enable row level security;

revoke all on table public.organization_ui_settings from anon, authenticated;
grant all on table public.organization_ui_settings to service_role;
