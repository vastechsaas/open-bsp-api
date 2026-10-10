begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, storage;
select no_plan();

insert into public.organizations (id, name) values
  ('a5100000-0000-4000-8000-000000000001', 'Notification Preferences A'),
  ('a5100000-0000-4000-8000-000000000002', 'Notification Preferences B');

insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
  ('a5200000-0000-4000-8000-000000000001', 'pref-owner@example.test', '{}', '{}'),
  ('a5200000-0000-4000-8000-000000000002', 'pref-admin@example.test', '{}', '{}'),
  ('a5200000-0000-4000-8000-000000000003', 'pref-supervisor@example.test', '{}', '{}'),
  ('a5200000-0000-4000-8000-000000000004', 'pref-member@example.test', '{}', '{}'),
  ('a5200000-0000-4000-8000-000000000005', 'pref-agent@example.test', '{}', '{}'),
  ('a5200000-0000-4000-8000-000000000006', 'pref-other-owner@example.test', '{}', '{}'),
  ('a5200000-0000-4000-8000-000000000007', 'pref-pending-owner@example.test', '{}', '{}');

insert into public.agents (id, organization_id, user_id, name, ai, extra) values
  ('a5300000-0000-4000-8000-000000000001', 'a5100000-0000-4000-8000-000000000001', 'a5200000-0000-4000-8000-000000000001', 'Owner', false, '{"role":"owner"}'),
  ('a5300000-0000-4000-8000-000000000002', 'a5100000-0000-4000-8000-000000000001', 'a5200000-0000-4000-8000-000000000002', 'Admin', false, '{"role":"admin"}'),
  ('a5300000-0000-4000-8000-000000000003', 'a5100000-0000-4000-8000-000000000001', 'a5200000-0000-4000-8000-000000000003', 'Supervisor', false, '{"role":"supervisor"}'),
  ('a5300000-0000-4000-8000-000000000004', 'a5100000-0000-4000-8000-000000000001', 'a5200000-0000-4000-8000-000000000004', 'Member', false, '{"role":"member"}'),
  ('a5300000-0000-4000-8000-000000000005', 'a5100000-0000-4000-8000-000000000001', 'a5200000-0000-4000-8000-000000000005', 'Agent', false, '{"role":"agent"}'),
  ('a5300000-0000-4000-8000-000000000006', 'a5100000-0000-4000-8000-000000000002', 'a5200000-0000-4000-8000-000000000006', 'Other Owner', false, '{"role":"owner"}'),
  ('a5300000-0000-4000-8000-000000000007', 'a5100000-0000-4000-8000-000000000001', 'a5200000-0000-4000-8000-000000000007', 'Pending Owner', false, '{"role":"owner","invitation":{"status":"pending"}}');

select set_config('request.jwt.claim.sub', 'a5200000-0000-4000-8000-000000000001', true);
set local role authenticated;
select is((select count(*) from public.get_organization_notification_preferences('a5100000-0000-4000-8000-000000000001')), 4::bigint, 'four supported preferences are returned');
select ok((select bool_and(enabled) from public.get_organization_notification_preferences('a5100000-0000-4000-8000-000000000001')), 'new and unconfigured tenants default to all enabled');
select throws_like($$select public.get_organization_notification_preferences('a5100000-0000-4000-8000-000000000002')$$, '%organization owner role required%', 'owner cannot read another tenant preferences');
select throws_like($$select public.update_organization_notification_preference('a5100000-0000-4000-8000-000000000002', 'private_note_mention', false)$$, '%organization owner role required%', 'owner cannot update another tenant preferences');
select throws_like($$select public.update_organization_notification_preference('a5100000-0000-4000-8000-000000000001', 'unknown_event', false)$$, '%unsupported notification type%', 'unknown event is rejected');
select throws_like($$select public.update_organization_notification_preference('a5100000-0000-4000-8000-000000000001', null, false)$$, '%unsupported notification type%', 'null event is rejected');
select throws_like($$select public.update_organization_notification_preference('a5100000-0000-4000-8000-000000000001', 'private_note_mention', null)$$, '%enabled state is required%', 'null enabled is rejected');
select throws_like($$select * from public.organization_notification_preferences$$, '%permission denied for table organization_notification_preferences%', 'direct REST reads are restricted to protected RPCs');
select throws_like($$insert into public.organization_notification_preferences (organization_id, notification_type, enabled) values ('a5100000-0000-4000-8000-000000000001', 'private_note_mention', false)$$, '%permission denied for table organization_notification_preferences%', 'direct REST writes cannot bypass owner checks');
reset role;

-- Existing notifications remain intact when a type is later disabled.
select ok(public.enqueue_user_notification('a5100000-0000-4000-8000-000000000001', 'a5300000-0000-4000-8000-000000000005', null, null, 'private_note_mention', 'historical-mention') is not null, 'default producer behavior is preserved');

set local role authenticated;
select lives_ok($$select public.update_organization_notification_preference('a5100000-0000-4000-8000-000000000001', notification_type, false) from public.get_organization_notification_preferences('a5100000-0000-4000-8000-000000000001')$$, 'owner can disable every notification type');
select ok((select bool_and(not enabled) from public.get_organization_notification_preferences('a5100000-0000-4000-8000-000000000001')), 'all disabled values are persisted');
reset role;

select ok(public.enqueue_user_notification('a5100000-0000-4000-8000-000000000001', 'a5300000-0000-4000-8000-000000000005', null, null, type, 'disabled:' || type) is null, 'disabled type is suppressed: ' || type)
from (values ('conversation_assigned'), ('conversation_transferred_to_agent'), ('conversation_transferred_to_queue'), ('private_note_mention')) as types(type);
select is((select count(*) from public.user_notifications where organization_id = 'a5100000-0000-4000-8000-000000000001'), 1::bigint, 'disabled events add no notifications and preserve history');
select is((select count(*) from public.organization_notification_preferences where updated_by_user_id = 'a5200000-0000-4000-8000-000000000001'), 4::bigint, 'preference changes record the actor');
select ok(public.enqueue_user_notification('a5100000-0000-4000-8000-000000000002', 'a5300000-0000-4000-8000-000000000006', null, null, 'private_note_mention', 'other-tenant') is not null, 'disabled preferences do not affect another tenant');
select throws_like($$select public.enqueue_user_notification('a5100000-0000-4000-8000-000000000001', 'a5300000-0000-4000-8000-000000000007', null, null, 'private_note_mention', 'invalid-recipient')$$, '%notification recipient must be an accepted human%', 'disabled events do not bypass recipient validation');

set local role authenticated;
select lives_ok($$select public.update_organization_notification_preference('a5100000-0000-4000-8000-000000000001', 'private_note_mention', true)$$, 'owner can re-enable a type');
select lives_ok($$select public.update_organization_notification_preference('a5100000-0000-4000-8000-000000000001', 'private_note_mention', true)$$, 'repeating a save is idempotent');
select is((select count(*) from public.get_organization_notification_preferences('a5100000-0000-4000-8000-000000000001') where enabled), 1::bigint, 'saving one toggle does not overwrite others');
reset role;
select is((select count(*) from public.user_notifications where organization_id = 'a5100000-0000-4000-8000-000000000001'), 1::bigint, 're-enabling does not replay suppressed notifications');
select ok(public.enqueue_user_notification('a5100000-0000-4000-8000-000000000001', 'a5300000-0000-4000-8000-000000000005', null, null, 'private_note_mention', 'enabled-new') is not null, 're-enabled type resumes future notifications');
select ok(public.enqueue_user_notification('a5100000-0000-4000-8000-000000000001', 'a5300000-0000-4000-8000-000000000005', null, null, 'private_note_mention', 'enabled-new') is not null, 'duplicate producer calls return the existing event');
select is((select count(*) from public.user_notifications where organization_id = 'a5100000-0000-4000-8000-000000000001'), 2::bigint, 'notification deduplication remains intact');

-- Disabling delivery does not disable the action that produces it.
insert into public.organizations_addresses (organization_id, service, address) values
  ('a5100000-0000-4000-8000-000000000001', 'whatsapp', 'preferences-test-number');
insert into public.conversations (id, organization_id, service, organization_address, group_address) values
  ('a5400000-0000-4000-8000-000000000001', 'a5100000-0000-4000-8000-000000000001', 'whatsapp', 'preferences-test-number', 'preferences-test-group');
set local role authenticated;
select lives_ok($$select public.set_conversation_agent_assignment('a5400000-0000-4000-8000-000000000001', 'a5300000-0000-4000-8000-000000000005')$$, 'manual assignment succeeds with its notification disabled');
select lives_ok($$select public.update_organization_notification_preference('a5100000-0000-4000-8000-000000000001', 'private_note_mention', false)$$, 'owner disables private-note notification before adding note');
select lives_ok($$select public.create_private_note('a5400000-0000-4000-8000-000000000001', 'Please review this request', array['a5300000-0000-4000-8000-000000000005'::uuid])$$, 'private notes and mentions succeed with their notification disabled');
reset role;
select is((select assigned_agent_id from public.conversations where id = 'a5400000-0000-4000-8000-000000000001'), 'a5300000-0000-4000-8000-000000000005'::uuid, 'assignment state is unchanged by preferences');
select is((select count(*) from public.message_mentions where organization_id = 'a5100000-0000-4000-8000-000000000001'), 1::bigint, 'mention record remains actionable');
select is((select count(*) from public.user_notifications where organization_id = 'a5100000-0000-4000-8000-000000000001'), 2::bigint, 'assignment and mention actions create no disabled notifications');

-- Every non-owner role is rejected even when its UI is bypassed.
select set_config('request.jwt.claim.sub', 'a5200000-0000-4000-8000-000000000002', true);
set local role authenticated;
select throws_like($$select public.get_organization_notification_preferences('a5100000-0000-4000-8000-000000000001')$$, '%organization owner role required%', 'admin cannot read preferences');
select throws_like($$select public.update_organization_notification_preference('a5100000-0000-4000-8000-000000000001', 'private_note_mention', false)$$, '%organization owner role required%', 'admin cannot save preferences');
select set_config('request.jwt.claim.sub', 'a5200000-0000-4000-8000-000000000003', true);
select throws_like($$select public.update_organization_notification_preference('a5100000-0000-4000-8000-000000000001', 'private_note_mention', false)$$, '%organization owner role required%', 'supervisor cannot save preferences');
select set_config('request.jwt.claim.sub', 'a5200000-0000-4000-8000-000000000004', true);
select throws_like($$select public.update_organization_notification_preference('a5100000-0000-4000-8000-000000000001', 'private_note_mention', false)$$, '%organization owner role required%', 'member cannot save preferences');
select set_config('request.jwt.claim.sub', 'a5200000-0000-4000-8000-000000000005', true);
select throws_like($$select public.update_organization_notification_preference('a5100000-0000-4000-8000-000000000001', 'private_note_mention', false)$$, '%organization owner role required%', 'agent cannot save preferences');
select is(public.get_unread_notification_count('a5100000-0000-4000-8000-000000000001'), 2::bigint, 'agent still sees previous notification unread count');
select set_config('request.jwt.claim.sub', 'a5200000-0000-4000-8000-000000000007', true);
select throws_like($$select public.update_organization_notification_preference('a5100000-0000-4000-8000-000000000001', 'private_note_mention', false)$$, '%organization owner role required%', 'pending owner cannot save preferences');
reset role;

update public.organization_lifecycle set status = 'archived' where organization_id = 'a5100000-0000-4000-8000-000000000001';
select set_config('request.jwt.claim.sub', 'a5200000-0000-4000-8000-000000000001', true);
set local role authenticated;
select throws_like($$select public.update_organization_notification_preference('a5100000-0000-4000-8000-000000000001', 'private_note_mention', false)$$, '%organization owner role required%', 'archived tenant owner cannot save');
select set_config('request.jwt.claim.sub', '', true);
select throws_like($$select public.update_organization_notification_preference('a5100000-0000-4000-8000-000000000001', 'private_note_mention', false)$$, '%organization owner role required%', 'missing session cannot save');
reset role;
set local role anon;
select throws_like($$select public.get_organization_notification_preferences('a5100000-0000-4000-8000-000000000001')$$, '%permission denied for function get_organization_notification_preferences%', 'anonymous cannot read preferences');
select throws_like($$select public.update_organization_notification_preference('a5100000-0000-4000-8000-000000000001', 'private_note_mention', false)$$, '%permission denied for function update_organization_notification_preference%', 'anonymous cannot save preferences');
reset role;
select * from finish();
rollback;
