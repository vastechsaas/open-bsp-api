begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, storage;

select plan(43);

insert into public.organizations (id, name, extra) values
  ('95000000-0000-4000-8000-000000000001', 'Agent Org A', '{}'),
  ('95000000-0000-4000-8000-000000000002', 'Agent Org B', '{}');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at, created_at,
  updated_at, confirmation_token, recovery_token, email_change_token_new,
  email_change
) values
  ('00000000-0000-0000-0000-000000000000', '95100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'agent-one@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '95100000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'agent-two@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '95100000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'supervisor@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '95100000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'member@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', '');

insert into public.agents (id, organization_id, user_id, name, ai, extra) values
  ('95200000-0000-4000-8000-000000000001', '95000000-0000-4000-8000-000000000001', '95100000-0000-4000-8000-000000000001', 'Agent One', false, '{"role":"agent"}'),
  ('95200000-0000-4000-8000-000000000002', '95000000-0000-4000-8000-000000000001', '95100000-0000-4000-8000-000000000002', 'Agent Two', false, '{"role":"agent"}'),
  ('95200000-0000-4000-8000-000000000003', '95000000-0000-4000-8000-000000000001', '95100000-0000-4000-8000-000000000003', 'Supervisor', false, '{"role":"supervisor"}'),
  ('95200000-0000-4000-8000-000000000004', '95000000-0000-4000-8000-000000000001', '95100000-0000-4000-8000-000000000004', 'Member', false, '{"role":"member"}');

insert into public.organizations_addresses (organization_id, service, address, extra, status) values
  ('95000000-0000-4000-8000-000000000001', 'whatsapp', 'agent-org-a', '{}', 'connected'),
  ('95000000-0000-4000-8000-000000000002', 'whatsapp', 'agent-org-b', '{}', 'connected');

insert into public.contacts (id, organization_id, name) values
  ('95300000-0000-4000-8000-000000000001', '95000000-0000-4000-8000-000000000001', 'Contact A'),
  ('95300000-0000-4000-8000-000000000002', '95000000-0000-4000-8000-000000000002', 'Contact B');

insert into public.contacts_addresses (organization_id, contact_id, service, address, extra) values
  ('95000000-0000-4000-8000-000000000001', '95300000-0000-4000-8000-000000000001', 'whatsapp', '15559500001', '{}'),
  ('95000000-0000-4000-8000-000000000002', '95300000-0000-4000-8000-000000000002', 'whatsapp', '15559500002', '{}');

insert into public.conversations (
  id, organization_id, service, organization_address, contact_address,
  name, assigned_agent_id, status, extra
) values
  ('95400000-0000-4000-8000-000000000001', '95000000-0000-4000-8000-000000000001', 'whatsapp', 'agent-org-a', '15559500001', 'Pending', null, 'active', '{}'),
  ('95400000-0000-4000-8000-000000000002', '95000000-0000-4000-8000-000000000001', 'whatsapp', 'agent-org-a', '15559500001', 'Mine', '95200000-0000-4000-8000-000000000001', 'active', '{}'),
  ('95400000-0000-4000-8000-000000000003', '95000000-0000-4000-8000-000000000001', 'whatsapp', 'agent-org-a', '15559500001', 'Other Agent', '95200000-0000-4000-8000-000000000002', 'active', '{}'),
  ('95400000-0000-4000-8000-000000000004', '95000000-0000-4000-8000-000000000001', 'whatsapp', 'agent-org-a', '15559500001', 'Member Owned', '95200000-0000-4000-8000-000000000004', 'active', '{}'),
  ('95400000-0000-4000-8000-000000000005', '95000000-0000-4000-8000-000000000001', 'whatsapp', 'agent-org-a', '15559500001', 'Closed Mine', '95200000-0000-4000-8000-000000000001', 'closed', '{}'),
  ('95400000-0000-4000-8000-000000000006', '95000000-0000-4000-8000-000000000001', 'whatsapp', 'agent-org-a', '15559500001', 'Spam Mine', '95200000-0000-4000-8000-000000000001', 'spam', '{}'),
  ('95400000-0000-4000-8000-000000000007', '95000000-0000-4000-8000-000000000001', 'whatsapp', 'agent-org-a', '15559500001', 'Closed Other Agent', '95200000-0000-4000-8000-000000000002', 'closed', '{}'),
  ('95400000-0000-4000-8000-000000000008', '95000000-0000-4000-8000-000000000001', 'whatsapp', 'agent-org-a', '15559500001', 'Expired Mine', '95200000-0000-4000-8000-000000000001', 'active', '{}');

insert into public.messages (
  id, organization_id, conversation_id, direction, contact_address, service,
  organization_address, content
) values
  ('95500000-0000-4000-8000-000000000001', '95000000-0000-4000-8000-000000000001', '95400000-0000-4000-8000-000000000001', 'incoming', '15559500001', 'whatsapp', 'agent-org-a', '{"version":"1","type":"file","kind":"document","file":{"uri":"internal://media/organizations/95000000-0000-4000-8000-000000000001/attachments/pending.pdf"}}'),
  ('95500000-0000-4000-8000-000000000002', '95000000-0000-4000-8000-000000000001', '95400000-0000-4000-8000-000000000003', 'incoming', '15559500001', 'whatsapp', 'agent-org-a', '{"version":"1","type":"file","kind":"document","file":{"uri":"internal://media/organizations/95000000-0000-4000-8000-000000000001/attachments/other.pdf"}}'),
  ('95500000-0000-4000-8000-000000000003', '95000000-0000-4000-8000-000000000001', '95400000-0000-4000-8000-000000000008', 'incoming', '15559500001', 'whatsapp', 'agent-org-a', '{"version":"1","type":"text","kind":"text","text":"expired"}');

update public.messages
set timestamp = now() - interval '25 hours'
where id = '95500000-0000-4000-8000-000000000003';

insert into public.quick_replies (id, organization_id, shortcut, content) values
  ('95600000-0000-4000-8000-000000000001', '95000000-0000-4000-8000-000000000001', '/greeting', 'Hello');

insert into public.message_templates (
  organization_id, id, organization_address, external_id, name, language,
  category, status, components
) values
  ('95000000-0000-4000-8000-000000000001', '95700000-0000-4000-8000-000000000001', 'agent-org-a', 'approved-agent', 'approved_agent', 'en_US', 'utility', 'approved', '[]'),
  ('95000000-0000-4000-8000-000000000001', '95700000-0000-4000-8000-000000000002', 'agent-org-a', 'pending-agent', 'pending_agent', 'en_US', 'utility', 'pending', '[]');

select ok('agent' = any(enum_range(null::public.role)::text[]), 'Agent role exists');
select results_eq($$ values (public.role_rank('owner')), (public.role_rank('admin')), (public.role_rank('supervisor')), (public.role_rank('member')), (public.role_rank('agent')) $$, $$ values (5), (4), (3), (2), (1) $$, 'role ranks are ordered');
select lives_ok($$ insert into public.api_keys (organization_id, role, name, key) values ('95000000-0000-4000-8000-000000000001', 'member', 'Member key', 'agent-role-member-key') $$, 'existing API-key role remains valid');
select throws_like($$ insert into public.api_keys (organization_id, role, name, key) values ('95000000-0000-4000-8000-000000000001', 'agent', 'Agent key', 'agent-role-agent-key') $$, '%api_keys_role_check%', 'Agent API keys are rejected');

select set_config('request.jwt.claim.sub', '95100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select results_eq($$ select public.get_authorized_orgs('agent') $$, $$ values ('95000000-0000-4000-8000-000000000001'::uuid) $$, 'Agent authorizes its organization');
select is_empty($$ select public.get_authorized_orgs('member') $$, 'Agent does not inherit Member access');
select results_eq($$ select key, "order" from public.get_conversation_queues('95000000-0000-4000-8000-000000000001') $$, $$ values ('pending'::text, 1), ('assigned'::text, 2), ('mentioned'::text, 3), ('spam'::text, 4), ('closed'::text, 5), ('expired'::text, 6) $$, 'Agent receives assignment, mention, and lifecycle queues');
select results_eq($$ select id from public.get_conversation_queue_conversations('95000000-0000-4000-8000-000000000001', 'pending') $$, $$ values ('95400000-0000-4000-8000-000000000001'::uuid) $$, 'Pending contains active unassigned conversations');
select results_eq($$ select id from public.get_conversation_queue_conversations('95000000-0000-4000-8000-000000000001', 'assigned') order by id $$, $$ values ('95400000-0000-4000-8000-000000000002'::uuid), ('95400000-0000-4000-8000-000000000008'::uuid) $$, 'Assigned contains only active conversations assigned to the current Agent');
select results_eq($$ select id from public.get_conversation_queue_conversations('95000000-0000-4000-8000-000000000001', 'spam') $$, $$ values ('95400000-0000-4000-8000-000000000006'::uuid) $$, 'Spam contains only the current Agent conversations');
select results_eq($$ select id from public.get_conversation_queue_conversations('95000000-0000-4000-8000-000000000001', 'closed') $$, $$ values ('95400000-0000-4000-8000-000000000005'::uuid) $$, 'Closed contains only the current Agent conversations');
select results_eq($$ select id from public.get_conversation_queue_conversations('95000000-0000-4000-8000-000000000001', 'expired') $$, $$ values ('95400000-0000-4000-8000-000000000008'::uuid) $$, 'Expired contains only visible stale active conversations');
select throws_like($$ select * from public.get_conversation_queue_conversations('95000000-0000-4000-8000-000000000001', 'all_active') $$, '%not available to Agent%', 'Agent cannot request All Active');
select results_eq($$ select id from public.conversations order by id $$, $$ values ('95400000-0000-4000-8000-000000000001'::uuid), ('95400000-0000-4000-8000-000000000002'::uuid), ('95400000-0000-4000-8000-000000000005'::uuid), ('95400000-0000-4000-8000-000000000006'::uuid), ('95400000-0000-4000-8000-000000000008'::uuid) $$, 'Agent sees unassigned active and own assigned lifecycle conversations only');
select results_eq($$ select id from public.messages order by id $$, $$ values ('95500000-0000-4000-8000-000000000001'::uuid), ('95500000-0000-4000-8000-000000000003'::uuid) $$, 'Agent reads messages only in visible conversations');
select throws_like($$ insert into public.messages (organization_id, conversation_id, direction, agent_id, service, organization_address, contact_address, content) values ('95000000-0000-4000-8000-000000000001', '95400000-0000-4000-8000-000000000001', 'outgoing', '95200000-0000-4000-8000-000000000001', 'whatsapp', 'agent-org-a', '15559500001', '{"version":"1","type":"text","kind":"text","text":"blocked"}') $$, '%row-level security%', 'Agent cannot reply before assignment');
select lives_ok($$ select public.assign_conversation_to_me('95400000-0000-4000-8000-000000000001') $$, 'Agent can self-assign Pending');
select lives_ok($$ insert into public.messages (organization_id, conversation_id, direction, agent_id, service, organization_address, contact_address, content) values ('95000000-0000-4000-8000-000000000001', '95400000-0000-4000-8000-000000000001', 'outgoing', '95200000-0000-4000-8000-000000000001', 'whatsapp', 'agent-org-a', '15559500001', '{"version":"1","type":"text","kind":"text","text":"allowed"}') $$, 'Agent can send from an assigned conversation');
select throws_like($$ insert into public.messages (organization_id, conversation_id, direction, agent_id, service, organization_address, contact_address, content) values ('95000000-0000-4000-8000-000000000001', '95400000-0000-4000-8000-000000000001', 'incoming', '95200000-0000-4000-8000-000000000001', 'whatsapp', 'agent-org-a', '15559500001', '{"version":"1","type":"text","kind":"text","text":"spoof"}') $$, '%row-level security%', 'Agent cannot send as contact');
select throws_like($$ insert into public.messages (organization_id, conversation_id, direction, agent_id, service, organization_address, contact_address, content) values ('95000000-0000-4000-8000-000000000001', '95400000-0000-4000-8000-000000000001', 'outgoing', '95200000-0000-4000-8000-000000000002', 'whatsapp', 'agent-org-a', '15559500001', '{"version":"1","type":"text","kind":"text","text":"spoof"}') $$, '%row-level security%', 'Agent cannot spoof another Agent identity');
select lives_ok($$ insert into public.messages (organization_id, conversation_id, direction, agent_id, service, organization_address, contact_address, content) values ('95000000-0000-4000-8000-000000000001', '95400000-0000-4000-8000-000000000001', 'outgoing', '95200000-0000-4000-8000-000000000001', 'whatsapp', 'agent-org-a', '15559500001', '{"version":"1","type":"data","kind":"template","data":{"name":"approved_agent","language":{"code":"en_US"}},"text":"Approved"}') $$, 'Agent can send an approved template from an assigned conversation');
select throws_like($$ insert into public.messages (organization_id, conversation_id, direction, agent_id, service, organization_address, contact_address, content) values ('95000000-0000-4000-8000-000000000001', '95400000-0000-4000-8000-000000000001', 'outgoing', '95200000-0000-4000-8000-000000000001', 'whatsapp', 'agent-org-a', '15559500001', '{"version":"1","type":"data","kind":"template","data":{"name":"pending_agent","language":{"code":"en_US"}},"text":"Pending"}') $$, '%row-level security%', 'Agent cannot send an unapproved template');
select ok(public.agent_can_download_media_object('organizations/95000000-0000-4000-8000-000000000001/attachments/pending.pdf'), 'Agent can download media referenced by a visible message');
select is(public.agent_can_download_media_object('organizations/95000000-0000-4000-8000-000000000001/attachments/other.pdf'), false, 'Agent cannot download media referenced by another Agent conversation');
select lives_ok($$ select public.unassign_conversation_from_me('95400000-0000-4000-8000-000000000001') $$, 'Agent can self-unassign');
select lives_ok($$ insert into public.contacts (id, organization_id, name) values ('95300000-0000-4000-8000-000000000003', '95000000-0000-4000-8000-000000000001', 'Created by Agent') $$, 'Agent can create contacts');
select lives_ok($$ update public.contacts set name = 'Updated by Agent' where id = '95300000-0000-4000-8000-000000000003' $$, 'Agent can update contacts');
select lives_ok($$ insert into public.contacts_addresses (organization_id, contact_id, service, address, extra) values ('95000000-0000-4000-8000-000000000001', '95300000-0000-4000-8000-000000000003', 'whatsapp', '15559500003', '{}') $$, 'Agent can create permitted contact addresses');
select lives_ok($$ delete from public.contacts_addresses where organization_id = '95000000-0000-4000-8000-000000000001' and address = '15559500003' $$, 'Agent can delete permitted contact addresses');
select lives_ok($$ delete from public.contacts where id = '95300000-0000-4000-8000-000000000003' $$, 'Agent can delete contacts');
select is((select count(*) from public.contacts where organization_id = '95000000-0000-4000-8000-000000000002'), 0::bigint, 'Agent cannot read another organization contacts');
select is((select count(*) from public.quick_replies), 1::bigint, 'Agent can read quick replies');
select throws_like($$ insert into public.quick_replies (organization_id, shortcut, content) values ('95000000-0000-4000-8000-000000000001', '/blocked', 'Blocked') $$, '%permission denied for table quick_replies%', 'Agent cannot manage quick replies');
select results_eq($$ select status from public.message_templates $$, $$ values ('approved'::text) $$, 'Agent reads approved templates only');
select is_empty($$ select id from public.campaigns $$, 'Agent cannot access campaigns');
select results_eq($$ select assigned_agent_id from public.create_conversation_for_me('95000000-0000-4000-8000-000000000001', 'whatsapp', 'agent-org-a', '15559500001') $$, $$ values ('95200000-0000-4000-8000-000000000001'::uuid) $$, 'Agent-created conversation is persisted assigned to self');

reset role;
select set_config('request.jwt.claim.sub', '95100000-0000-4000-8000-000000000003', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select results_eq($$ select assigned_agent_id from public.set_conversation_agent_assignment('95400000-0000-4000-8000-000000000001', '95200000-0000-4000-8000-000000000001') $$, $$ values ('95200000-0000-4000-8000-000000000001'::uuid) $$, 'Supervisor can assign an unassigned conversation to Agent');
select results_eq($$ select assigned_agent_id from public.set_conversation_agent_assignment('95400000-0000-4000-8000-000000000001', '95200000-0000-4000-8000-000000000002') $$, $$ values ('95200000-0000-4000-8000-000000000002'::uuid) $$, 'Supervisor can reassign between Agents');
select results_eq($$ select assigned_agent_id from public.set_conversation_agent_assignment('95400000-0000-4000-8000-000000000001', null) $$, $$ values (null::uuid) $$, 'Supervisor can unassign an Agent conversation');
select throws_like($$ select public.set_conversation_agent_assignment('95400000-0000-4000-8000-000000000004', '95200000-0000-4000-8000-000000000001') $$, '%non-Agent users cannot be reassigned%', 'Supervisor cannot seize a Member conversation');
select lives_ok($$ insert into public.agents (organization_id, name, ai, extra) values ('95000000-0000-4000-8000-000000000001', 'Invited Agent', false, '{"role":"agent","invitation":{"email":"invited-agent@example.test","status":"pending"}}') $$, 'Supervisor can invite an Agent');
select lives_ok($$ update public.agents set name = 'Agent One Renamed' where id = '95200000-0000-4000-8000-000000000001' $$, 'Supervisor can rename an Agent');
select throws_like($$ update public.agents set extra = jsonb_set(extra, '{role}', '"member"') where id = '95200000-0000-4000-8000-000000000001' $$, '%row-level security%', 'Supervisor cannot change Agent roles');

select * from finish();
rollback;
