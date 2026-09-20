-- Reconcile the broad ACL preservation introduced by SCRUM-117 with the
-- least-privilege contracts enforced by these tables' RLS test suites.
--
-- This migration is intentionally limited to the affected tables. Supabase's
-- schema diff also emitted unrelated ACL noise, which has been trimmed.

revoke all on table public.chatbot_webhook_credentials from anon, authenticated;
grant select on table public.chatbot_webhook_credentials to anon, authenticated;
grant all on table public.chatbot_webhook_credentials to service_role;

revoke all on table public.conversation_routing_events from anon, authenticated;
grant all on table public.conversation_routing_events to service_role;

revoke all on table public.organization_agent_capacity from anon, authenticated;
grant all on table public.organization_agent_capacity to service_role;

revoke all on table public.whatsapp_integration_health from anon, authenticated;
grant all on table public.whatsapp_integration_health to service_role;

revoke all on table public.routing_queues from anon, authenticated;
grant select on table public.routing_queues to authenticated;
grant all on table public.routing_queues to service_role;

revoke all on table public.routing_queue_members from anon, authenticated;
grant select on table public.routing_queue_members to authenticated;
grant all on table public.routing_queue_members to service_role;

revoke all on table public.user_notifications from anon, authenticated;
grant select on table public.user_notifications to authenticated;
grant all on table public.user_notifications to service_role;
