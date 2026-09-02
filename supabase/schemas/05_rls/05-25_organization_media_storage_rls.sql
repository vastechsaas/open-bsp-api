alter table public.organization_media_storage enable row level security;

revoke all on table public.organization_media_storage from anon, authenticated;
