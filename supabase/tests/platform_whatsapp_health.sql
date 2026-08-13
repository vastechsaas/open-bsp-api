begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select plan(24);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at,
  created_at, updated_at, confirmation_token, recovery_token,
  email_change_token_new, email_change
) values
  ('00000000-0000-0000-0000-000000000000', '24000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'health-admin@example.test', crypt('password', gen_salt('bf')), '{"provider":"email","providers":["email"]}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '24000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'health-user@example.test', crypt('password', gen_salt('bf')), '{"provider":"email","providers":["email"]}', '{}', now(), now(), now(), '', '', '', '');

insert into public.organizations (id, name, extra) values
  ('14000000-0000-4000-8000-000000000001', 'Health Alpha', '{}'),
  ('14000000-0000-4000-8000-000000000002', 'Health Beta', '{}');
insert into public.platform_admins (user_id, active)
values ('24000000-0000-4000-8000-000000000001', true);

insert into public.organizations_addresses (organization_id, service, address, status, extra) values
  ('14000000-0000-4000-8000-000000000001', 'whatsapp', 'health-connected', 'connected', '{"verified_name":"Alpha Support","phone_number":"923001111111","waba_id":"waba-alpha","business_id":"business-alpha","application_id":"app-alpha","quality_rating":"GREEN","messaging_limit_tier":"TIER_1K","phone_number_status":"CONNECTED"}'),
  ('14000000-0000-4000-8000-000000000001', 'whatsapp', 'health-warning', 'connected', '{"verified_name":"Warning Support","phone_number":"923001111112","waba_id":"waba-warning","quality_rating":"YELLOW"}'),
  ('14000000-0000-4000-8000-000000000001', 'whatsapp', 'health-disconnected', 'disconnected', '{"verified_name":"Old Support","phone_number":"923001111113"}'),
  ('14000000-0000-4000-8000-000000000001', 'instagram', 'health-instagram', 'connected', '{}'),
  ('14000000-0000-4000-8000-000000000002', 'whatsapp', 'health-beta', 'connected', '{"verified_name":"Beta Support"}');

insert into public.whatsapp_integration_health (
  organization_id, phone_number_id, last_check_attempted_at,
  last_check_succeeded_at, token_status, token_validated_at,
  webhook_subscription_status, webhook_validated_at,
  last_webhook_received_at, last_webhook_succeeded_at
) values
  ('14000000-0000-4000-8000-000000000001', 'health-connected', now(), now(), 'valid', now(), 'subscribed', now(), now(), now()),
  ('14000000-0000-4000-8000-000000000001', 'health-warning', now() - interval '10 minutes', now() - interval '10 minutes', 'valid', now() - interval '10 minutes', 'subscribed', now() - interval '10 minutes', now(), now());

insert into public.contacts (id, organization_id, name) values
  ('44000000-0000-4000-8000-000000000001', '14000000-0000-4000-8000-000000000001', 'Health Customer');
insert into public.contacts_addresses (organization_id, contact_id, service, address, status) values
  ('14000000-0000-4000-8000-000000000001', '44000000-0000-4000-8000-000000000001', 'whatsapp', '923009999999', 'active');
insert into public.conversations (id, organization_id, service, organization_address, contact_address, status) values
  ('54000000-0000-4000-8000-000000000001', '14000000-0000-4000-8000-000000000001', 'whatsapp', 'health-connected', '923009999999', 'active');
insert into public.messages (organization_id, conversation_id, id, direction, contact_address, service, organization_address, content, status, timestamp) values
  ('14000000-0000-4000-8000-000000000001', '54000000-0000-4000-8000-000000000001', '64000000-0000-4000-8000-000000000001', 'incoming', '923009999999', 'whatsapp', 'health-connected', '{"version":"1","type":"text","kind":"message","text":"hello"}', '{}', now() - interval '2 hours');
insert into public.messages (organization_id, conversation_id, id, direction, service, organization_address, content, status, timestamp) values
  ('14000000-0000-4000-8000-000000000001', '54000000-0000-4000-8000-000000000001', '64000000-0000-4000-8000-000000000002', 'outgoing', 'whatsapp', 'health-connected', '{"version":"1","type":"text","kind":"message","text":"reply"}', '{}', now() - interval '1 hour');

insert into public.message_templates (organization_id, organization_address, external_id, name, language, category, status) values
  ('14000000-0000-4000-8000-000000000001', 'health-connected', 'template-approved', 'welcome', 'en', 'utility', 'approved'),
  ('14000000-0000-4000-8000-000000000001', 'health-connected', 'template-rejected', 'offer', 'en', 'marketing', 'rejected');
insert into public.logs (organization_id, organization_address, level, category, service, message, created_at) values
  ('14000000-0000-4000-8000-000000000001', 'health-warning', 'error', 'webhook', 'whatsapp', 'recent processing error', now() - interval '1 hour'),
  ('14000000-0000-4000-8000-000000000001', 'health-connected', 'error', 'messages', 'whatsapp', 'old processing error', now() - interval '2 days'),
  ('14000000-0000-4000-8000-000000000001', 'health-connected', 'error', 'delivery', 'whatsapp', 'recipient failure', now() - interval '1 hour');

select ok(not has_table_privilege('authenticated', 'public.whatsapp_integration_health', 'SELECT'), 'authenticated users cannot directly read health snapshots');
select ok(not has_table_privilege('authenticated', 'public.whatsapp_integration_health', 'INSERT'), 'authenticated users cannot directly write health snapshots');

select set_config('request.jwt.claim.sub', '24000000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;

select is((select count(*) from public.list_platform_whatsapp_health_page('14000000-0000-4000-8000-000000000001', 1, 10, null, null)), 3::bigint, 'list includes connected and disconnected WhatsApp accounts only');
select results_eq($$select health_status from public.get_platform_whatsapp_health('14000000-0000-4000-8000-000000000001', 'health-connected')$$, $$values ('healthy'::text)$$, 'fresh successful account is healthy');
select results_eq($$select health_status from public.get_platform_whatsapp_health('14000000-0000-4000-8000-000000000001', 'health-warning')$$, $$values ('warning'::text)$$, 'stale account is warning');
select results_eq($$select health_status from public.get_platform_whatsapp_health('14000000-0000-4000-8000-000000000001', 'health-disconnected')$$, $$values ('disconnected'::text)$$, 'stored disconnection takes precedence');
select is((select count(*) from public.list_platform_whatsapp_health_page('14000000-0000-4000-8000-000000000001', 1, 10, 'alpha', null)), 1::bigint, 'search matches the verified account name');
select is((select count(*) from public.list_platform_whatsapp_health_page('14000000-0000-4000-8000-000000000001', 1, 10, null, 'warning')), 1::bigint, 'status filtering uses calculated health');
select is((select max(total_count) from public.list_platform_whatsapp_health_page('14000000-0000-4000-8000-000000000001', 1, 1, null, null)), 3::bigint, 'pagination returns the full filtered total');
select results_eq($$select webhook_error_count_24h from public.get_platform_whatsapp_health('14000000-0000-4000-8000-000000000001', 'health-warning')$$, $$values (1::bigint)$$, 'only recent operational webhook errors are counted');
select results_eq($$select last_incoming_message_at is not null, last_outgoing_message_at is not null from public.get_platform_whatsapp_health('14000000-0000-4000-8000-000000000001', 'health-connected')$$, $$values (true, true)$$, 'external incoming and outgoing activity is derived');
select results_eq($$select template_status_summary from public.get_platform_whatsapp_health('14000000-0000-4000-8000-000000000001', 'health-connected')$$, $$values ('{"approved": 1, "rejected": 1}'::jsonb)$$, 'template status totals are derived');
select is((select count(*) from public.get_platform_whatsapp_health('14000000-0000-4000-8000-000000000001', 'health-beta')), 0::bigint, 'account detail enforces tenant isolation');
select ok(public.record_platform_whatsapp_action('14000000-0000-4000-8000-000000000001', 'health-connected', 'whatsapp.health_check', '84000000-0000-4000-8000-000000000001', '{"success":true}') is not null, 'health actions are audited');
select is(public.get_platform_whatsapp_action_result('14000000-0000-4000-8000-000000000001', 'health-connected', 'whatsapp.health_check', '84000000-0000-4000-8000-000000000001'), '{"success": true}'::jsonb, 'idempotent action result can be replayed');
select throws_ok($$select public.record_platform_whatsapp_action('14000000-0000-4000-8000-000000000001', 'health-warning', 'whatsapp.health_check', '84000000-0000-4000-8000-000000000001', '{"success":true}')$$, '22023', 'request id was already used for a different platform action', 'request ids cannot be reused across accounts');
select throws_ok($$select * from public.list_platform_whatsapp_health_page('14000000-0000-4000-8000-000000000001', 1, 10, null, 'bad')$$, '22023', 'invalid WhatsApp health status', 'invalid filters are rejected');
select throws_ok($$select public.record_platform_whatsapp_action('14000000-0000-4000-8000-000000000001', 'missing', 'whatsapp.health_check', '84000000-0000-4000-8000-000000000002', '{"success":true}')$$, 'P0002', 'WhatsApp integration not found', 'actions reject unknown accounts');

reset role;
select is((select count(*) from public.platform_admin_action_events where request_id = '84000000-0000-4000-8000-000000000001'), 1::bigint, 'idempotent action audit stores one row');
select is((select target_id from public.platform_admin_action_events where request_id = '84000000-0000-4000-8000-000000000001'), 'health-connected'::text, 'audit storage supports textual Phone Number IDs');

set local role authenticated;
select set_config('request.jwt.claim.sub', '24000000-0000-4000-8000-000000000002', true);
select throws_ok($$select * from public.list_platform_whatsapp_health_page('14000000-0000-4000-8000-000000000001', 1, 10, null, null)$$, '42501', 'platform administrator access required', 'ordinary users cannot list health');
select throws_ok($$select public.record_platform_whatsapp_action('14000000-0000-4000-8000-000000000001', 'health-connected', 'whatsapp.health_check', '84000000-0000-4000-8000-000000000003', '{"success":true}')$$, '42501', 'platform administrator access required', 'ordinary users cannot audit health actions');
select ok(not has_function_privilege('anon', 'public.list_platform_whatsapp_health_page(uuid,integer,integer,text,text)', 'EXECUTE'), 'anonymous users cannot execute health list RPC');

reset role;
update public.whatsapp_integration_health set token_status = 'invalid' where organization_id = '14000000-0000-4000-8000-000000000001' and phone_number_id = 'health-connected';
set local role authenticated;
select set_config('request.jwt.claim.sub', '24000000-0000-4000-8000-000000000001', true);
select results_eq($$select health_status from public.get_platform_whatsapp_health('14000000-0000-4000-8000-000000000001', 'health-connected')$$, $$values ('disconnected'::text)$$, 'invalid token takes disconnection precedence');

select * from finish();
rollback;
