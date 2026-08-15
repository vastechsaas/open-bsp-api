begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, storage;
select no_plan();

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at, created_at,
  updated_at, confirmation_token, recovery_token, email_change_token_new,
  email_change
) values
  ('00000000-0000-0000-0000-000000000000', 'd1100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'automation-owner@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'd1100000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'automation-admin@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'd1100000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'automation-supervisor@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'd1100000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'automation-agent@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'd1100000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'automation-member@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'd1100000-0000-4000-8000-000000000006', 'authenticated', 'authenticated', 'automation-platform@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'd1100000-0000-4000-8000-000000000007', 'authenticated', 'authenticated', 'automation-other@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'd1100000-0000-4000-8000-000000000008', 'authenticated', 'authenticated', 'automation-pending@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', '');

insert into public.organizations (id, name, extra) values
  ('d1000000-0000-4000-8000-000000000001', 'Automation Org', '{}'),
  ('d1000000-0000-4000-8000-000000000002', 'Other Automation Org', '{}');

select is(
  (select auto_save_whatsapp_contacts from public.organization_automation_settings where organization_id = 'd1000000-0000-4000-8000-000000000001'),
  true,
  'new organizations initialize contact auto-save to enabled'
);

insert into public.agents (id, organization_id, user_id, name, ai, extra) values
  ('d1200000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'd1100000-0000-4000-8000-000000000001', 'Owner', false, '{"role":"owner"}'),
  ('d1200000-0000-4000-8000-000000000002', 'd1000000-0000-4000-8000-000000000001', 'd1100000-0000-4000-8000-000000000002', 'Admin', false, '{"role":"admin"}'),
  ('d1200000-0000-4000-8000-000000000003', 'd1000000-0000-4000-8000-000000000001', 'd1100000-0000-4000-8000-000000000003', 'Supervisor', false, '{"role":"supervisor"}'),
  ('d1200000-0000-4000-8000-000000000004', 'd1000000-0000-4000-8000-000000000001', 'd1100000-0000-4000-8000-000000000004', 'Agent', false, '{"role":"agent"}'),
  ('d1200000-0000-4000-8000-000000000005', 'd1000000-0000-4000-8000-000000000001', 'd1100000-0000-4000-8000-000000000005', 'Member', false, '{"role":"member"}'),
  ('d1200000-0000-4000-8000-000000000006', 'd1000000-0000-4000-8000-000000000001', null, 'AI', true, '{"role":"admin"}'),
  ('d1200000-0000-4000-8000-000000000007', 'd1000000-0000-4000-8000-000000000002', 'd1100000-0000-4000-8000-000000000007', 'Other Owner', false, '{"role":"owner"}'),
  ('d1200000-0000-4000-8000-000000000008', 'd1000000-0000-4000-8000-000000000001', 'd1100000-0000-4000-8000-000000000008', 'Pending Admin', false, '{"role":"admin","invitation":{"status":"pending"}}');

insert into public.platform_admins (user_id, active)
values ('d1100000-0000-4000-8000-000000000006', true);

-- Each accepted manager role can update the setting.
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000001', true);
select is((select auto_save_whatsapp_contacts from public.update_organization_contact_auto_save('d1000000-0000-4000-8000-000000000001', false)), false, 'Owner can disable auto-save');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000002', true);
select is((select auto_save_whatsapp_contacts from public.update_organization_contact_auto_save('d1000000-0000-4000-8000-000000000001', true)), true, 'Admin can enable auto-save');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000003', true);
select is((select updated_by_scope from public.update_organization_contact_auto_save('d1000000-0000-4000-8000-000000000001', false)), 'organization'::text, 'Supervisor can update and is attributed to organization scope');
select throws_like(
  $$ insert into public.organization_automation_settings (organization_id) values ('d1000000-0000-4000-8000-000000000002') $$,
  '%permission denied for table organization_automation_settings%',
  'direct client writes are blocked'
);
reset role;

-- Agent, Member, pending and cross-tenant humans cannot manage the setting.
set local role authenticated;
select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000004', true);
select throws_ok($$ select public.update_organization_contact_auto_save('d1000000-0000-4000-8000-000000000001', true) $$, '42501', 'owner, admin, or supervisor role required to manage automation settings', 'Agent cannot update');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000005', true);
select throws_ok($$ select public.get_organization_automation_settings('d1000000-0000-4000-8000-000000000001') $$, '42501', 'owner, admin, or supervisor role required to manage automation settings', 'Member cannot read manager settings');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000008', true);
select throws_ok($$ select public.update_organization_contact_auto_save('d1000000-0000-4000-8000-000000000001', true) $$, '42501', 'owner, admin, or supervisor role required to manage automation settings', 'Pending human cannot update');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000007', true);
select throws_ok($$ select public.update_organization_contact_auto_save('d1000000-0000-4000-8000-000000000001', true) $$, '42501', 'owner, admin, or supervisor role required to manage automation settings', 'cross-tenant owner cannot update');
reset role;

-- Disabled first inbound messages remain unlinked permanently.
insert into public.contacts_addresses (organization_id, service, address, extra)
values ('d1000000-0000-4000-8000-000000000001', 'whatsapp', '923000000001', '{"name":"Disabled Customer","has_inbound_message":true}');

select ok((select contact_id is null from public.contacts_addresses where organization_id = 'd1000000-0000-4000-8000-000000000001' and address = '923000000001'), 'disabled first inbound does not create a Contact');

set local role authenticated;
select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000003', true);
select is((select auto_save_whatsapp_contacts from public.update_organization_contact_auto_save('d1000000-0000-4000-8000-000000000001', true)), true, 'Supervisor re-enables auto-save');
reset role;

update public.contacts_addresses
set extra = '{"name":"Disabled Customer Again","has_inbound_message":true}'
where organization_id = 'd1000000-0000-4000-8000-000000000001'
  and address = '923000000001';
select ok((select contact_id is null from public.contacts_addresses where organization_id = 'd1000000-0000-4000-8000-000000000001' and address = '923000000001'), 're-enabling does not backfill an address first seen while disabled');

insert into public.contacts_addresses (organization_id, service, address, extra)
values ('d1000000-0000-4000-8000-000000000001', 'whatsapp', '923000000002', '{"name":"Enabled Customer","has_inbound_message":true}');
select ok((select contact_id is not null from public.contacts_addresses where organization_id = 'd1000000-0000-4000-8000-000000000001' and address = '923000000002'), 'a new address creates a Contact after re-enabling');

select is((select count(*) from public.contacts where organization_id = 'd1000000-0000-4000-8000-000000000001'), 1::bigint, 'retries and disabled identities do not create duplicates');

-- Platform Admin updates are tenant-safe, attributed and idempotently audited.
set local role authenticated;
select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000006', true);
select results_eq(
  $$ select auto_save_whatsapp_contacts, updated_by_scope from public.update_platform_organization_contact_auto_save('d1000000-0000-4000-8000-000000000001', false, 'd1400000-0000-4000-8000-000000000001') $$,
  $$ values (false, 'platform'::text) $$,
  'Platform Admin can update a selected tenant'
);
reset role;
select is((select count(*) from public.platform_admin_action_events where request_id = 'd1400000-0000-4000-8000-000000000001'), 1::bigint, 'Platform update records one audit event');
select results_eq(
  $$ select before_state->>'auto_save_whatsapp_contacts', after_state->>'auto_save_whatsapp_contacts' from public.platform_admin_action_events where request_id = 'd1400000-0000-4000-8000-000000000001' $$,
  $$ values ('true'::text, 'false'::text) $$,
  'audit event records previous and resulting state'
);
set local role authenticated;
select set_config('request.jwt.claim.sub', 'd1100000-0000-4000-8000-000000000006', true);
select lives_ok(
  $$ select public.update_platform_organization_contact_auto_save('d1000000-0000-4000-8000-000000000001', false, 'd1400000-0000-4000-8000-000000000001') $$,
  'retrying the same Platform request succeeds idempotently'
);
reset role;
select is((select count(*) from public.platform_admin_action_events where request_id = 'd1400000-0000-4000-8000-000000000001'), 1::bigint, 'retrying a request ID does not duplicate the audit event');

select * from finish();
rollback;
