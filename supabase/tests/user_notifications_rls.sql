begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, storage;

select no_plan();

insert into public.organizations (id, name, extra) values
  ('99000000-0000-4000-8000-000000000001', 'Notifications Org A', '{}'),
  ('98000000-0000-4000-8000-000000000001', 'Notifications Org B', '{}');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at, created_at,
  updated_at, confirmation_token, recovery_token, email_change_token_new,
  email_change
) values
  ('00000000-0000-0000-0000-000000000000', '99100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'notifications-owner@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '99100000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'notifications-admin@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '99100000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'notifications-supervisor@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '99100000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'notifications-member@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '99100000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'notifications-agent@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '99100000-0000-4000-8000-000000000006', 'authenticated', 'authenticated', 'notifications-other-agent@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '99100000-0000-4000-8000-000000000007', 'authenticated', 'authenticated', 'notifications-ai@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '99100000-0000-4000-8000-000000000008', 'authenticated', 'authenticated', 'notifications-pending@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '99100000-0000-4000-8000-000000000009', 'authenticated', 'authenticated', 'notifications-rejected@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '98100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'notifications-cross-tenant@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', '');

insert into public.agents (
  id, organization_id, user_id, name, ai, extra
) values
  ('99200000-0000-4000-8000-000000000001', '99000000-0000-4000-8000-000000000001', '99100000-0000-4000-8000-000000000001', 'Owner', false, '{"role":"owner"}'),
  ('99200000-0000-4000-8000-000000000002', '99000000-0000-4000-8000-000000000001', '99100000-0000-4000-8000-000000000002', 'Admin', false, '{"role":"admin"}'),
  ('99200000-0000-4000-8000-000000000003', '99000000-0000-4000-8000-000000000001', '99100000-0000-4000-8000-000000000003', 'Supervisor', false, '{"role":"supervisor"}'),
  ('99200000-0000-4000-8000-000000000004', '99000000-0000-4000-8000-000000000001', '99100000-0000-4000-8000-000000000004', 'Member', false, '{"role":"member"}'),
  ('99200000-0000-4000-8000-000000000005', '99000000-0000-4000-8000-000000000001', '99100000-0000-4000-8000-000000000005', 'Agent', false, '{"role":"agent"}'),
  ('99200000-0000-4000-8000-000000000006', '99000000-0000-4000-8000-000000000001', '99100000-0000-4000-8000-000000000006', 'Other Agent', false, '{"role":"agent"}'),
  ('99200000-0000-4000-8000-000000000007', '99000000-0000-4000-8000-000000000001', '99100000-0000-4000-8000-000000000007', 'AI Agent', true, '{"role":"agent"}'),
  ('99200000-0000-4000-8000-000000000008', '99000000-0000-4000-8000-000000000001', '99100000-0000-4000-8000-000000000008', 'Pending Human', false, '{"role":"agent","invitation":{"email":"notifications-pending@example.test","status":"pending"}}'),
  ('99200000-0000-4000-8000-000000000009', '99000000-0000-4000-8000-000000000001', '99100000-0000-4000-8000-000000000009', 'Rejected Human', false, '{"role":"member","invitation":{"email":"notifications-rejected@example.test","status":"rejected"}}'),
  ('98200000-0000-4000-8000-000000000001', '98000000-0000-4000-8000-000000000001', '98100000-0000-4000-8000-000000000001', 'Cross Tenant Agent', false, '{"role":"agent"}');

insert into public.user_notifications (
  id,
  organization_id,
  recipient_agent_id,
  actor_agent_id,
  notification_type,
  source_event_key,
  payload,
  created_at
) values
  ('99300000-0000-4000-8000-000000000001', '99000000-0000-4000-8000-000000000001', '99200000-0000-4000-8000-000000000001', null, 'conversation_assigned', 'shared-assignment-event', '{}', '2026-08-17 01:00:00+00'),
  ('99300000-0000-4000-8000-000000000002', '99000000-0000-4000-8000-000000000001', '99200000-0000-4000-8000-000000000002', '99200000-0000-4000-8000-000000000001', 'conversation_assigned', 'shared-assignment-event', '{}', '2026-08-17 02:00:00+00'),
  ('99300000-0000-4000-8000-000000000003', '99000000-0000-4000-8000-000000000001', '99200000-0000-4000-8000-000000000003', '99200000-0000-4000-8000-000000000001', 'conversation_assigned', 'shared-assignment-event', '{}', '2026-08-17 03:00:00+00'),
  ('99300000-0000-4000-8000-000000000004', '99000000-0000-4000-8000-000000000001', '99200000-0000-4000-8000-000000000004', '99200000-0000-4000-8000-000000000001', 'conversation_assigned', 'shared-assignment-event', '{}', '2026-08-17 04:00:00+00'),
  ('99300000-0000-4000-8000-000000000005', '99000000-0000-4000-8000-000000000001', '99200000-0000-4000-8000-000000000005', '99200000-0000-4000-8000-000000000001', 'conversation_assigned', 'shared-assignment-event', '{}', '2026-08-17 05:00:00+00'),
  ('99300000-0000-4000-8000-000000000006', '99000000-0000-4000-8000-000000000001', '99200000-0000-4000-8000-000000000006', '99200000-0000-4000-8000-000000000001', 'conversation_assigned', 'shared-assignment-event', '{}', '2026-08-17 06:00:00+00'),
  ('99300000-0000-4000-8000-000000000007', '99000000-0000-4000-8000-000000000001', '99200000-0000-4000-8000-000000000007', '99200000-0000-4000-8000-000000000001', 'conversation_assigned', 'shared-assignment-event', '{}', '2026-08-17 07:00:00+00'),
  ('99300000-0000-4000-8000-000000000008', '99000000-0000-4000-8000-000000000001', '99200000-0000-4000-8000-000000000008', '99200000-0000-4000-8000-000000000001', 'conversation_assigned', 'shared-assignment-event', '{}', '2026-08-17 08:00:00+00'),
  ('99300000-0000-4000-8000-000000000009', '99000000-0000-4000-8000-000000000001', '99200000-0000-4000-8000-000000000009', '99200000-0000-4000-8000-000000000001', 'conversation_assigned', 'shared-assignment-event', '{}', '2026-08-17 09:00:00+00'),
  ('98300000-0000-4000-8000-000000000001', '98000000-0000-4000-8000-000000000001', '98200000-0000-4000-8000-000000000001', null, 'conversation_assigned', 'shared-assignment-event', '{}', '2026-08-17 10:00:00+00');

select set_config('request.jwt.claim.role', 'authenticated', true);

select set_config('request.jwt.claim.sub', '99100000-0000-4000-8000-000000000001', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;
select results_eq(
  $$ select recipient_agent_id from public.user_notifications $$,
  $$ values ('99200000-0000-4000-8000-000000000001'::uuid) $$,
  'an accepted Owner reads only their own notification'
);
reset role;

select set_config('request.jwt.claim.sub', '99100000-0000-4000-8000-000000000002', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;
select results_eq(
  $$ select recipient_agent_id from public.user_notifications $$,
  $$ values ('99200000-0000-4000-8000-000000000002'::uuid) $$,
  'an accepted Admin reads only their own notification'
);
reset role;

select set_config('request.jwt.claim.sub', '99100000-0000-4000-8000-000000000003', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;
select results_eq(
  $$ select recipient_agent_id from public.user_notifications $$,
  $$ values ('99200000-0000-4000-8000-000000000003'::uuid) $$,
  'an accepted Supervisor reads only their own notification'
);
reset role;

select set_config('request.jwt.claim.sub', '99100000-0000-4000-8000-000000000004', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;
select results_eq(
  $$ select recipient_agent_id from public.user_notifications $$,
  $$ values ('99200000-0000-4000-8000-000000000004'::uuid) $$,
  'an accepted Member reads only their own notification'
);
reset role;

select set_config('request.jwt.claim.sub', '99100000-0000-4000-8000-000000000005', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;
select results_eq(
  $$ select recipient_agent_id from public.user_notifications $$,
  $$ values ('99200000-0000-4000-8000-000000000005'::uuid) $$,
  'an accepted Agent reads only their own notification and cannot read another Agent or tenant'
);

select throws_like(
  $$ insert into public.user_notifications (
    organization_id,
    recipient_agent_id,
    notification_type,
    source_event_key
  ) values (
    '99000000-0000-4000-8000-000000000001',
    '99200000-0000-4000-8000-000000000005',
    'private_note_mention',
    'client-spoofed-event'
  ) $$,
  '%permission denied for table user_notifications%',
  'authenticated clients cannot insert notifications directly'
);

select throws_like(
  $$ select public.enqueue_user_notification(
    '99000000-0000-4000-8000-000000000001',
    '99200000-0000-4000-8000-000000000005',
    null,
    null,
    'private_note_mention',
    'client-spoofed-helper-event',
    '{}'::jsonb
  ) $$,
  '%permission denied for function enqueue_user_notification%',
  'authenticated clients cannot call the internal notification producer'
);

select throws_like(
  $$ update public.user_notifications
    set read_at = now()
    where id = '99300000-0000-4000-8000-000000000005' $$,
  '%permission denied for table user_notifications%',
  'authenticated clients cannot update notifications directly'
);

select throws_like(
  $$ delete from public.user_notifications
    where id = '99300000-0000-4000-8000-000000000005' $$,
  '%permission denied for table user_notifications%',
  'authenticated clients cannot delete notifications directly'
);
reset role;

select set_config('request.jwt.claim.sub', '99100000-0000-4000-8000-000000000006', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;
select results_eq(
  $$ select recipient_agent_id from public.user_notifications $$,
  $$ values ('99200000-0000-4000-8000-000000000006'::uuid) $$,
  'a second accepted Agent reads only their own notification'
);
reset role;

select set_config('request.jwt.claim.sub', '98100000-0000-4000-8000-000000000001', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;
select results_eq(
  $$ select recipient_agent_id from public.user_notifications $$,
  $$ values ('98200000-0000-4000-8000-000000000001'::uuid) $$,
  'an Agent cannot read notifications from another tenant'
);
reset role;

select set_config('request.jwt.claim.sub', '99100000-0000-4000-8000-000000000007', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;
select is_empty(
  $$ select id from public.user_notifications $$,
  'an AI identity cannot read notifications'
);
reset role;

select set_config('request.jwt.claim.sub', '99100000-0000-4000-8000-000000000008', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;
select is_empty(
  $$ select id from public.user_notifications $$,
  'a pending human cannot read notifications'
);
reset role;

select set_config('request.jwt.claim.sub', '99100000-0000-4000-8000-000000000009', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;
select is_empty(
  $$ select id from public.user_notifications $$,
  'a rejected human cannot read notifications'
);
reset role;

insert into public.user_notifications (
  id,
  organization_id,
  recipient_agent_id,
  actor_agent_id,
  notification_type,
  source_event_key,
  payload,
  created_at,
  read_at,
  resolved_at
) values
  (
    '99300000-0000-4000-8000-000000000010',
    '99000000-0000-4000-8000-000000000001',
    '99200000-0000-4000-8000-000000000005',
    '99200000-0000-4000-8000-000000000001',
    'conversation_transferred_to_agent',
    'agent-newest-unread',
    '{}',
    '2026-08-17 14:00:00+00',
    null,
    null
  ),
  (
    '99300000-0000-4000-8000-000000000011',
    '99000000-0000-4000-8000-000000000001',
    '99200000-0000-4000-8000-000000000005',
    '99200000-0000-4000-8000-000000000001',
    'private_note_mention',
    'agent-read',
    '{}',
    '2026-08-17 13:00:00+00',
    '2026-08-17 13:30:00+00',
    null
  ),
  (
    '99300000-0000-4000-8000-000000000012',
    '99000000-0000-4000-8000-000000000001',
    '99200000-0000-4000-8000-000000000005',
    '99200000-0000-4000-8000-000000000001',
    'conversation_transferred_to_queue',
    'agent-resolved',
    '{}',
    '2026-08-17 12:00:00+00',
    null,
    '2026-08-17 12:30:00+00'
  ),
  (
    '99300000-0000-4000-8000-000000000013',
    '99000000-0000-4000-8000-000000000001',
    '99200000-0000-4000-8000-000000000005',
    '99200000-0000-4000-8000-000000000001',
    'private_note_mention',
    'agent-older-unread',
    '{}',
    '2026-08-17 11:00:00+00',
    null,
    null
  );

select set_config('request.jwt.claim.sub', '99100000-0000-4000-8000-000000000005', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select results_eq(
  $$
    select id, total_count
    from public.list_user_notifications_page(
      '99000000-0000-4000-8000-000000000001',
      1,
      2,
      false
    )
  $$,
  $$ values
    ('99300000-0000-4000-8000-000000000010'::uuid, 5::bigint),
    ('99300000-0000-4000-8000-000000000011'::uuid, 5::bigint)
  $$,
  'notification pagination returns the newest deterministic page and total count'
);

select results_eq(
  $$
    select id, total_count
    from public.list_user_notifications_page(
      '99000000-0000-4000-8000-000000000001',
      2,
      2,
      false
    )
  $$,
  $$ values
    ('99300000-0000-4000-8000-000000000012'::uuid, 5::bigint),
    ('99300000-0000-4000-8000-000000000013'::uuid, 5::bigint)
  $$,
  'notification pagination returns the next page without overlap'
);

select results_eq(
  $$
    select id, total_count
    from public.list_user_notifications_page(
      '99000000-0000-4000-8000-000000000001',
      1,
      25,
      true
    )
  $$,
  $$ values
    ('99300000-0000-4000-8000-000000000010'::uuid, 3::bigint),
    ('99300000-0000-4000-8000-000000000013'::uuid, 3::bigint),
    ('99300000-0000-4000-8000-000000000005'::uuid, 3::bigint)
  $$,
  'unread filtering excludes read and resolved notifications'
);

select is(
  public.get_unread_notification_count(
    '99000000-0000-4000-8000-000000000001'
  ),
  3::bigint,
  'unread count includes only unresolved unread notifications'
);

select isnt(
  (
    select read_at
    from public.mark_user_notification_read(
      '99300000-0000-4000-8000-000000000010'
    )
  ),
  null::timestamptz,
  'a recipient can mark their notification as read'
);

select is(
  (
    select read_at
    from public.mark_user_notification_read(
      '99300000-0000-4000-8000-000000000010'
    )
  ),
  (
    select read_at
    from public.user_notifications
    where id = '99300000-0000-4000-8000-000000000010'
  ),
  'marking an already-read notification preserves its read timestamp'
);

select throws_like(
  $$
    select *
    from public.mark_user_notification_read(
      '99300000-0000-4000-8000-000000000006'
    )
  $$,
  '%Notification not found or not authorized%',
  'a recipient cannot mark another Agent notification as read'
);

select is(
  public.mark_all_user_notifications_read(
    '99000000-0000-4000-8000-000000000001'
  ),
  2,
  'mark-all updates only the current recipient remaining unread notifications'
);

select is(
  public.get_unread_notification_count(
    '99000000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'the current recipient has no unread notifications after mark-all'
);

select is(
  (
    select count(*)
    from public.user_notifications
    where recipient_agent_id = '99200000-0000-4000-8000-000000000006'
      and read_at is null
      and resolved_at is null
  ),
  0::bigint,
  'RLS still prevents the current recipient from reading another Agent notification'
);
reset role;

select is(
  (
    select count(*)
    from public.user_notifications
    where recipient_agent_id = '99200000-0000-4000-8000-000000000006'
      and read_at is null
      and resolved_at is null
  ),
  1::bigint,
  'mark-all leaves another Agent notification unchanged'
);

select set_config('request.jwt.claim.sub', '99100000-0000-4000-8000-000000000007', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;
select throws_like(
  $$
    select *
    from public.list_user_notifications_page(
      '99000000-0000-4000-8000-000000000001',
      1,
      25,
      false
    )
  $$,
  '%Not authorized%',
  'an AI identity cannot list notifications through the RPC'
);
reset role;

select set_config('request.jwt.claim.sub', '99100000-0000-4000-8000-000000000008', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;
select throws_like(
  $$
    select public.get_unread_notification_count(
      '99000000-0000-4000-8000-000000000001'
    )
  $$,
  '%Not authorized%',
  'a pending human cannot read the unread count through the RPC'
);
reset role;

select set_config('request.jwt.claim.sub', '99100000-0000-4000-8000-000000000009', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;
select throws_like(
  $$
    select public.mark_all_user_notifications_read(
      '99000000-0000-4000-8000-000000000001'
    )
  $$,
  '%Not authorized%',
  'a rejected human cannot mark notifications through the RPC'
);
reset role;

select * from finish();
rollback;
