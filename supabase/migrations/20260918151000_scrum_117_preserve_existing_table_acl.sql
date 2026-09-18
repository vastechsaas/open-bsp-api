-- Forward-only repair of db-diff ACL noise, preserving the pre-deployment staging ACL.
-- This contains privileges only, never tenant data or credentials.
revoke all on table "public"."agent_assignment_presence",
 "public"."agents",
 "public"."api_keys",
 "public"."contacts_addresses",
 "public"."contacts",
 "public"."conversation_assignment_events",
 "public"."conversation_routing_events",
 "public"."conversations",
 "public"."logs",
 "public"."messages",
 "public"."onboarding_tokens",
 "public"."organization_agent_capacity",
 "public"."organization_media_storage",
 "public"."organizations_addresses",
 "public"."organizations",
 "public"."platform_admin_access_events",
 "public"."platform_admins",
 "public"."platform_report_export_events",
 "public"."quick_replies",
 "public"."routing_queue_assignment_state",
 "public"."webhooks",
 "public"."whatsapp_integration_health" from anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."conversations" TO "anon";
GRANT ALL ON TABLE "public"."conversations" TO "authenticated";
GRANT ALL ON TABLE "public"."conversations" TO "service_role";
GRANT ALL ON TABLE "public"."agents" TO "anon";
GRANT ALL ON TABLE "public"."agents" TO "authenticated";
GRANT ALL ON TABLE "public"."agents" TO "service_role";
GRANT ALL ON TABLE "public"."messages" TO "anon";
GRANT ALL ON TABLE "public"."messages" TO "authenticated";
GRANT ALL ON TABLE "public"."messages" TO "service_role";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."quick_replies" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."quick_replies" TO "authenticated";
GRANT ALL ON TABLE "public"."quick_replies" TO "service_role";
GRANT ALL ON TABLE "public"."agent_assignment_presence" TO "anon";
GRANT ALL ON TABLE "public"."agent_assignment_presence" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_assignment_presence" TO "service_role";
GRANT ALL ON TABLE "public"."api_keys" TO "anon";
GRANT ALL ON TABLE "public"."api_keys" TO "authenticated";
GRANT ALL ON TABLE "public"."api_keys" TO "service_role";
GRANT ALL ON TABLE "public"."contacts" TO "anon";
GRANT ALL ON TABLE "public"."contacts" TO "authenticated";
GRANT ALL ON TABLE "public"."contacts" TO "service_role";
GRANT ALL ON TABLE "public"."contacts_addresses" TO "anon";
GRANT ALL ON TABLE "public"."contacts_addresses" TO "authenticated";
GRANT ALL ON TABLE "public"."contacts_addresses" TO "service_role";
GRANT ALL ON TABLE "public"."conversation_assignment_events" TO "anon";
GRANT ALL ON TABLE "public"."conversation_assignment_events" TO "authenticated";
GRANT ALL ON TABLE "public"."conversation_assignment_events" TO "service_role";
GRANT ALL ON TABLE "public"."conversation_routing_events" TO "anon";
GRANT ALL ON TABLE "public"."conversation_routing_events" TO "authenticated";
GRANT ALL ON TABLE "public"."conversation_routing_events" TO "service_role";
GRANT ALL ON TABLE "public"."logs" TO "anon";
GRANT ALL ON TABLE "public"."logs" TO "authenticated";
GRANT ALL ON TABLE "public"."logs" TO "service_role";
GRANT ALL ON TABLE "public"."onboarding_tokens" TO "anon";
GRANT ALL ON TABLE "public"."onboarding_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."onboarding_tokens" TO "service_role";
GRANT ALL ON TABLE "public"."organization_agent_capacity" TO "anon";
GRANT ALL ON TABLE "public"."organization_agent_capacity" TO "authenticated";
GRANT ALL ON TABLE "public"."organization_agent_capacity" TO "service_role";
GRANT ALL ON TABLE "public"."organization_media_storage" TO "service_role";
GRANT ALL ON TABLE "public"."organizations" TO "anon";
GRANT ALL ON TABLE "public"."organizations" TO "authenticated";
GRANT ALL ON TABLE "public"."organizations" TO "service_role";
GRANT ALL ON TABLE "public"."organizations_addresses" TO "anon";
GRANT ALL ON TABLE "public"."organizations_addresses" TO "authenticated";
GRANT ALL ON TABLE "public"."organizations_addresses" TO "service_role";
GRANT ALL ON TABLE "public"."platform_admin_access_events" TO "service_role";
GRANT ALL ON TABLE "public"."platform_admins" TO "service_role";
GRANT ALL ON TABLE "public"."platform_report_export_events" TO "service_role";
GRANT ALL ON TABLE "public"."routing_queue_assignment_state" TO "anon";
GRANT ALL ON TABLE "public"."routing_queue_assignment_state" TO "authenticated";
GRANT ALL ON TABLE "public"."routing_queue_assignment_state" TO "service_role";
GRANT ALL ON TABLE "public"."webhooks" TO "anon";
GRANT ALL ON TABLE "public"."webhooks" TO "authenticated";
GRANT ALL ON TABLE "public"."webhooks" TO "service_role";
GRANT ALL ON TABLE "public"."whatsapp_integration_health" TO "anon";
GRANT ALL ON TABLE "public"."whatsapp_integration_health" TO "authenticated";
GRANT ALL ON TABLE "public"."whatsapp_integration_health" TO "service_role";
