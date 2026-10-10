alter table public.organization_notification_preferences enable row level security;

-- Owners use the protected RPCs; direct REST writes cannot bypass validation.
revoke all on table public.organization_notification_preferences from anon, authenticated;
grant all on table public.organization_notification_preferences to service_role;
