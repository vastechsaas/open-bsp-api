alter table public.whatsapp_integration_health enable row level security;

revoke all on table public.whatsapp_integration_health from anon, authenticated;
