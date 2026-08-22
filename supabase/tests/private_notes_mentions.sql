begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, storage;

select no_plan();

insert into public.organizations (id, name, extra) values
  ('96000000-0000-4000-8000-000000000001', 'Private Notes Org', '{}'),
  ('97000000-0000-4000-8000-000000000001', 'Other Org', '{}');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at, created_at,
  updated_at, confirmation_token, recovery_token, email_change_token_new,
  email_change
) values
  ('00000000-0000-0000-0000-000000000000', '96100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'ali@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '96100000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'sara@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '96100000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'owner@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '96100000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'admin@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '96100000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'supervisor@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '96100000-0000-4000-8000-000000000006', 'authenticated', 'authenticated', 'member@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '97100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'other@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', '');

insert into public.agents (
  id, organization_id, user_id, name, ai, extra
) values
  ('96200000-0000-4000-8000-000000000001', '96000000-0000-4000-8000-000000000001', '96100000-0000-4000-8000-000000000001', 'Ali', false, '{"role":"agent"}'),
  ('96200000-0000-4000-8000-000000000002', '96000000-0000-4000-8000-000000000001', '96100000-0000-4000-8000-000000000002', 'Sara', false, '{"role":"agent"}'),
  ('96200000-0000-4000-8000-000000000003', '96000000-0000-4000-8000-000000000001', '96100000-0000-4000-8000-000000000003', 'Owner', false, '{"role":"owner"}'),
  ('96200000-0000-4000-8000-000000000004', '96000000-0000-4000-8000-000000000001', '96100000-0000-4000-8000-000000000004', 'Admin', false, '{"role":"admin"}'),
  ('96200000-0000-4000-8000-000000000005', '96000000-0000-4000-8000-000000000001', '96100000-0000-4000-8000-000000000005', 'Supervisor', false, '{"role":"supervisor"}'),
  ('96200000-0000-4000-8000-000000000006', '96000000-0000-4000-8000-000000000001', '96100000-0000-4000-8000-000000000006', 'Inactive Member', false, '{"role":"member","availability":"inactive"}'),
  ('96200000-0000-4000-8000-000000000007', '96000000-0000-4000-8000-000000000001', null, 'AI Helper', true, '{"role":"agent"}'),
  ('96200000-0000-4000-8000-000000000008', '96000000-0000-4000-8000-000000000001', null, 'Pending Human', false, '{"role":"agent","invitation":{"email":"pending@example.test","status":"pending"}}'),
  ('96200000-0000-4000-8000-000000000009', '96000000-0000-4000-8000-000000000001', null, 'Rejected Human', false, '{"role":"member","invitation":{"email":"rejected@example.test","status":"rejected"}}'),
  ('97200000-0000-4000-8000-000000000001', '97000000-0000-4000-8000-000000000001', '97100000-0000-4000-8000-000000000001', 'Other Human', false, '{"role":"member"}');

insert into public.organizations_addresses (
  organization_id, service, address, extra, status
) values
  ('96000000-0000-4000-8000-000000000001', 'whatsapp', 'notes-org', '{}', 'connected'),
  ('97000000-0000-4000-8000-000000000001', 'whatsapp', 'other-org', '{}', 'connected');

insert into public.contacts (id, organization_id, name) values
  ('96300000-0000-4000-8000-000000000001', '96000000-0000-4000-8000-000000000001', 'Main Customer'),
  ('97300000-0000-4000-8000-000000000001', '97000000-0000-4000-8000-000000000001', 'Other Customer');

insert into public.contacts_addresses (
  organization_id, contact_id, service, address, extra
) values
  ('96000000-0000-4000-8000-000000000001', '96300000-0000-4000-8000-000000000001', 'whatsapp', '15559600001', '{}'),
  ('97000000-0000-4000-8000-000000000001', '97300000-0000-4000-8000-000000000001', 'whatsapp', '15559700001', '{}');

insert into public.conversations (
  id, organization_id, service, organization_address, contact_address,
  name, assigned_agent_id, status, extra, updated_at
) values
  ('96400000-0000-4000-8000-000000000001', '96000000-0000-4000-8000-000000000001', 'whatsapp', 'notes-org', '15559600001', 'Active Customer', '96200000-0000-4000-8000-000000000001', 'active', '{}', '2026-01-01 00:00:00+00'),
  ('96400000-0000-4000-8000-000000000002', '96000000-0000-4000-8000-000000000001', 'whatsapp', 'notes-org', '15559600001', 'Closed Customer', '96200000-0000-4000-8000-000000000001', 'active', '{}', '2026-01-02 00:00:00+00'),
  ('96400000-0000-4000-8000-000000000003', '96000000-0000-4000-8000-000000000001', 'whatsapp', 'notes-org', '15559600001', 'Spam Customer', '96200000-0000-4000-8000-000000000001', 'active', '{}', '2026-01-03 00:00:00+00'),
  ('97400000-0000-4000-8000-000000000001', '97000000-0000-4000-8000-000000000001', 'whatsapp', 'other-org', '15559700001', 'Other Customer', '97200000-0000-4000-8000-000000000001', 'active', '{}', now());

insert into public.messages (
  id, organization_id, conversation_id, direction, contact_address, service,
  organization_address, content, status, timestamp
) values
  ('96500000-0000-4000-8000-000000000001', '96000000-0000-4000-8000-000000000001', '96400000-0000-4000-8000-000000000001', 'incoming', '15559600001', 'whatsapp', 'notes-org', '{"version":"1","type":"text","kind":"text","text":"Active preview"}', '{}', '2026-02-01 00:00:00+00'),
  ('96500000-0000-4000-8000-000000000002', '96000000-0000-4000-8000-000000000001', '96400000-0000-4000-8000-000000000002', 'incoming', '15559600001', 'whatsapp', 'notes-org', '{"version":"1","type":"text","kind":"text","text":"Closed preview"}', '{}', '2026-02-02 00:00:00+00'),
  ('96500000-0000-4000-8000-000000000003', '96000000-0000-4000-8000-000000000001', '96400000-0000-4000-8000-000000000003', 'incoming', '15559600001', 'whatsapp', 'notes-org', '{"version":"1","type":"text","kind":"text","text":"Spam preview"}', '{}', '2026-02-03 00:00:00+00');

select set_config('request.jwt.claim.sub', '96100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select lives_ok(
  $$ select public.create_private_note(
    '96400000-0000-4000-8000-000000000001',
    '  Please review this customer  ',
    array[
      '96200000-0000-4000-8000-000000000002'::uuid,
      '96200000-0000-4000-8000-000000000006'::uuid
    ]
  ) $$,
  'an assigned Agent can create a text-only private note with multiple mentions'
);

select results_eq(
  $$
    select direction::text, agent_id, content->>'kind', content->>'text', status
    from public.messages
    where content->>'text' = 'Please review this customer'
  $$,
  $$ values (
    'internal'::text,
    '96200000-0000-4000-8000-000000000001'::uuid,
    'private_note'::text,
    'Please review this customer'::text,
    '{}'::jsonb
  ) $$,
  'the RPC derives the author and stores an undispatched internal private note'
);

select is(
  (
    select jsonb_array_length(content->'mentioned_agent_ids')
    from public.messages
    where content->>'text' = 'Please review this customer'
  ),
  2,
  'the message content keeps the selected mention ids'
);

reset role;

select results_eq(
  $$
    select recipient_agent_id, actor_agent_id, notification_type, payload->>'text'
    from public.user_notifications
    where notification_type = 'private_note_mention'
    order by recipient_agent_id
  $$,
  $$ values
    (
      '96200000-0000-4000-8000-000000000002'::uuid,
      '96200000-0000-4000-8000-000000000001'::uuid,
      'private_note_mention'::text,
      'Please review this customer'::text
    ),
    (
      '96200000-0000-4000-8000-000000000006'::uuid,
      '96200000-0000-4000-8000-000000000001'::uuid,
      'private_note_mention'::text,
      'Please review this customer'::text
    )
  $$,
  'each mentioned human receives one private-note notification'
);

select is(
  (
    select count(*)
    from public.message_mentions mention
    join public.messages message on message.id = mention.message_id
    where message.content->>'text' = 'Please review this customer'
  ),
  2::bigint,
  'tenant-safe mention rows are stored for every distinct recipient'
);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select is(
  (
    select updated_at
    from public.conversations
    where id = '96400000-0000-4000-8000-000000000001'
  ),
  '2026-01-01 00:00:00+00'::timestamptz,
  'private notes do not change ordinary conversation ordering timestamps'
);

select throws_like(
  $$ insert into public.messages (
    organization_id, conversation_id, direction, agent_id, contact_address,
    service, organization_address, content, status
  ) values (
    '96000000-0000-4000-8000-000000000001',
    '96400000-0000-4000-8000-000000000001',
    'internal',
    '96200000-0000-4000-8000-000000000001',
    '15559600001',
    'whatsapp',
    'notes-org',
    '{"version":"1","type":"text","kind":"private_note","text":"spoof","mentioned_agent_ids":[]}',
    '{}'
  ) $$,
  '%row-level security%',
  'generic Agent message insertion cannot create private notes'
);

select throws_ok(
  $$ select public.create_private_note(
    '96400000-0000-4000-8000-000000000001',
    'self mention',
    array['96200000-0000-4000-8000-000000000001'::uuid]
  ) $$,
  '22023',
  'authors cannot mention themselves',
  'self mentions are rejected'
);

select throws_ok(
  $$ select public.create_private_note(
    '96400000-0000-4000-8000-000000000001',
    'invalid targets',
    array['96200000-0000-4000-8000-000000000007'::uuid]
  ) $$,
  '22023',
  'mentions must target accepted humans in the same organization',
  'AI mentions are rejected'
);

select throws_ok(
  $$ select public.create_private_note(
    '96400000-0000-4000-8000-000000000001',
    'invalid targets',
    array['96200000-0000-4000-8000-000000000008'::uuid]
  ) $$,
  '22023',
  'mentions must target accepted humans in the same organization',
  'pending invitations are rejected'
);

select throws_ok(
  $$ select public.create_private_note(
    '96400000-0000-4000-8000-000000000001',
    'invalid targets',
    array['96200000-0000-4000-8000-000000000009'::uuid]
  ) $$,
  '22023',
  'mentions must target accepted humans in the same organization',
  'rejected invitations are rejected'
);

select throws_ok(
  $$ select public.create_private_note(
    '96400000-0000-4000-8000-000000000001',
    'invalid targets',
    array['97200000-0000-4000-8000-000000000001'::uuid]
  ) $$,
  '22023',
  'mentions must target accepted humans in the same organization',
  'cross-organization mentions are rejected'
);

select lives_ok(
  $$ select public.create_private_note(
    '96400000-0000-4000-8000-000000000001',
    'duplicate mentions normalize',
    array[
      '96200000-0000-4000-8000-000000000002'::uuid,
      '96200000-0000-4000-8000-000000000002'::uuid
    ]
  ) $$,
  'duplicate mention selections are normalized safely'
);

reset role;
select is(
  (
    select count(*)
    from public.message_mentions mention
    join public.messages message on message.id = mention.message_id
    where message.content->>'text' = 'duplicate mentions normalize'
  ),
  1::bigint,
  'normalized duplicates create one mention row'
);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select lives_ok(
  $$ select public.create_private_note(
    '96400000-0000-4000-8000-000000000002',
    'Closed history mention',
    array['96200000-0000-4000-8000-000000000002'::uuid]
  ) $$,
  'a note can mention Sara while the conversation is active'
);

select lives_ok(
  $$ select public.create_private_note(
    '96400000-0000-4000-8000-000000000003',
    'Spam history mention',
    array['96200000-0000-4000-8000-000000000002'::uuid]
  ) $$,
  'a second active conversation can mention Sara'
);

reset role;
update public.message_mentions mention
set created_at = case message.conversation_id
  when '96400000-0000-4000-8000-000000000001'::uuid then '2026-03-03 00:00:00+00'::timestamptz
  when '96400000-0000-4000-8000-000000000002'::uuid then '2026-03-02 00:00:00+00'::timestamptz
  when '96400000-0000-4000-8000-000000000003'::uuid then '2026-03-01 00:00:00+00'::timestamptz
end
from public.messages message
where message.id = mention.message_id
  and mention.mentioned_agent_id = '96200000-0000-4000-8000-000000000002';

update public.conversations
set status = case id
  when '96400000-0000-4000-8000-000000000002'::uuid then 'closed'
  when '96400000-0000-4000-8000-000000000003'::uuid then 'spam'
end
where id in (
  '96400000-0000-4000-8000-000000000002',
  '96400000-0000-4000-8000-000000000003'
);

select set_config('request.jwt.claim.sub', '96100000-0000-4000-8000-000000000002', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select results_eq(
  $$
    select name, status
    from public.list_mentioned_conversations_page(
      '96000000-0000-4000-8000-000000000001', 1, 25, null
    )
  $$,
  $$ values
    ('Active Customer'::text, 'active'::text),
    ('Closed Customer'::text, 'closed'::text),
    ('Spam Customer'::text, 'spam'::text)
  $$,
  'Mentioned is backend-filtered by latest mention time and keeps closed/spam history'
);

select results_eq(
  $$
    select preview_message->'content'->>'text', total_count
    from public.list_mentioned_conversations_page(
      '96000000-0000-4000-8000-000000000001', 1, 1, null
    )
  $$,
  $$ values ('Active preview'::text, 3::bigint) $$,
  'Mentioned pagination returns total count and the latest non-private preview'
);

select results_eq(
  $$
    select name
    from public.list_mentioned_conversations_page(
      '96000000-0000-4000-8000-000000000001', 1, 25, 'closed'
    )
  $$,
  $$ values ('Closed Customer'::text) $$,
  'Mentioned search is applied before counting and pagination'
);

select is(
  (
    select count(*)
    from public.conversations
    where id in (
      '96400000-0000-4000-8000-000000000001',
      '96400000-0000-4000-8000-000000000002',
      '96400000-0000-4000-8000-000000000003'
    )
  ),
  3::bigint,
  'a mentioned Agent receives read access to active, closed, and spam conversations'
);

select lives_ok(
  $$ select public.create_private_note(
    '96400000-0000-4000-8000-000000000001',
    'Sara internal reply',
    array[]::uuid[]
  ) $$,
  'a mentioned unassigned Agent can reply with another private note'
);

select throws_like(
  $$ insert into public.messages (
    organization_id, conversation_id, direction, agent_id, contact_address,
    service, organization_address, content
  ) values (
    '96000000-0000-4000-8000-000000000001',
    '96400000-0000-4000-8000-000000000001',
    'outgoing',
    '96200000-0000-4000-8000-000000000002',
    '15559600001',
    'whatsapp',
    'notes-org',
    '{"version":"1","type":"text","kind":"text","text":"customer reply blocked"}'
  ) $$,
  '%row-level security%',
  'a mentioned but unassigned Agent still cannot reply to the customer'
);

select throws_ok(
  $$ select public.create_private_note(
    '96400000-0000-4000-8000-000000000002',
    'closed reply blocked',
    array[]::uuid[]
  ) $$,
  '22023',
  'private notes can only be added to active conversations',
  'closed Mentioned history is read-only'
);

select throws_ok(
  $$ select public.create_private_note(
    '96400000-0000-4000-8000-000000000003',
    'spam reply blocked',
    array[]::uuid[]
  ) $$,
  '22023',
  'private notes can only be added to active conversations',
  'spam Mentioned history is read-only'
);

select results_eq(
  $$
    select name, total_count
    from public.list_mentionable_humans_page(
      '96000000-0000-4000-8000-000000000001', 1, 50, null
    )
  $$,
  $$ values
    ('Admin'::text, 5::bigint),
    ('Ali'::text, 5::bigint),
    ('Inactive Member'::text, 5::bigint),
    ('Owner'::text, 5::bigint),
    ('Supervisor'::text, 5::bigint)
  $$,
  'mention candidates include every other accepted human regardless of availability'
);

select throws_ok(
  $$ select * from public.list_mentioned_conversations_page(
    '97000000-0000-4000-8000-000000000001', 1, 25, null
  ) $$,
  '42501',
  'organization is not accessible to the authenticated user',
  'Mentioned pagination enforces organization isolation'
);

reset role;
with inserted_conversations as (
  insert into public.conversations (
    organization_id,
    service,
    organization_address,
    contact_address,
    name,
    assigned_agent_id,
    status,
    extra
  )
  select
    '96000000-0000-4000-8000-000000000001'::uuid,
    'whatsapp'::public.service,
    'notes-org',
    '15559600001',
    'Bulk Mention ' || sequence,
    '96200000-0000-4000-8000-000000000001'::uuid,
    'active',
    '{}'
  from generate_series(1, 51) sequence
  returning id
), inserted_messages as (
  insert into public.messages (
    organization_id,
    conversation_id,
    direction,
    agent_id,
    contact_address,
    service,
    organization_address,
    content,
    status
  )
  select
    '96000000-0000-4000-8000-000000000001'::uuid,
    conversation.id,
    'internal'::public.direction,
    '96200000-0000-4000-8000-000000000001'::uuid,
    '15559600001',
    'whatsapp'::public.service,
    'notes-org',
    '{"version":"1","type":"text","kind":"private_note","text":"bulk","mentioned_agent_ids":["96200000-0000-4000-8000-000000000002"]}'::jsonb,
    '{}'::jsonb
  from inserted_conversations conversation
  returning id, created_at
)
insert into public.message_mentions (
  organization_id,
  message_id,
  mentioned_agent_id,
  created_at
)
select
  '96000000-0000-4000-8000-000000000001'::uuid,
  message.id,
  '96200000-0000-4000-8000-000000000002'::uuid,
  message.created_at
from inserted_messages message;

set local role authenticated;
set local search_path = extensions, public, auth, storage;

select results_eq(
  $$
    select count(*)::integer, max(total_count)::integer
    from public.list_mentioned_conversations_page(
      '96000000-0000-4000-8000-000000000001', 1, 500, null
    )
  $$,
  $$ values (50, 54) $$,
  'Mentioned pagination caps page size at 50 while retaining the full total'
);

reset role;

select set_config('request.jwt.claim.sub', '96100000-0000-4000-8000-000000000003', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;
select lives_ok($$ select public.create_private_note('96400000-0000-4000-8000-000000000001', 'Owner note', array[]::uuid[]) $$, 'Owners can author private notes');

reset role;
select set_config('request.jwt.claim.sub', '96100000-0000-4000-8000-000000000004', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;
select lives_ok($$ select public.create_private_note('96400000-0000-4000-8000-000000000001', 'Admin note', array[]::uuid[]) $$, 'Admins can author private notes');

reset role;
select set_config('request.jwt.claim.sub', '96100000-0000-4000-8000-000000000005', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;
select lives_ok($$ select public.create_private_note('96400000-0000-4000-8000-000000000001', 'Supervisor note', array[]::uuid[]) $$, 'Supervisors can author private notes');

reset role;
select set_config('request.jwt.claim.sub', '96100000-0000-4000-8000-000000000006', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;
select lives_ok($$ select public.create_private_note('96400000-0000-4000-8000-000000000001', 'Member note', array[]::uuid[]) $$, 'Members can author private notes regardless of availability');

select throws_like(
  $$ insert into public.messages (
    organization_id, conversation_id, direction, agent_id, contact_address,
    service, organization_address, content, status
  ) values (
    '96000000-0000-4000-8000-000000000001',
    '96400000-0000-4000-8000-000000000001',
    'internal',
    '96200000-0000-4000-8000-000000000006',
    '15559600001',
    'whatsapp',
    'notes-org',
    '{"version":"1","type":"text","kind":"private_note","text":"spoof","mentioned_agent_ids":[]}',
    '{}'
  ) $$,
  '%row-level security%',
  'generic member message insertion cannot bypass the private-note RPC'
);

reset role;

select ok(
  position(
    'private_note' in pg_get_functiondef('public.notify_webhook()'::regprocedure)
  ) > 0,
  'organization webhook delivery explicitly excludes private notes'
);

select * from finish();

rollback;
