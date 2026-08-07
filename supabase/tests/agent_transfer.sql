begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, storage;

select no_plan();

insert into public.organizations (id, name, extra) values
  ('98000000-0000-4000-8000-000000000001', 'Transfer Org', '{}'),
  ('98000000-0000-4000-8000-000000000002', 'Other Transfer Org', '{}');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at, created_at,
  updated_at, confirmation_token, recovery_token, email_change_token_new,
  email_change
) values
  ('00000000-0000-0000-0000-000000000000', '98100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'transfer-ali@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '98100000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'transfer-sara@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '98100000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'transfer-supervisor@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '98100000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'transfer-member@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '98100000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'transfer-other@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', '');

insert into public.agents (
  id, organization_id, user_id, name, ai, extra
) values
  ('98200000-0000-4000-8000-000000000001', '98000000-0000-4000-8000-000000000001', '98100000-0000-4000-8000-000000000001', 'Ali', false, '{"role":"agent"}'),
  ('98200000-0000-4000-8000-000000000002', '98000000-0000-4000-8000-000000000001', '98100000-0000-4000-8000-000000000002', 'Sara', false, '{"role":"agent","availability":"inactive"}'),
  ('98200000-0000-4000-8000-000000000003', '98000000-0000-4000-8000-000000000001', '98100000-0000-4000-8000-000000000003', 'Supervisor', false, '{"role":"supervisor"}'),
  ('98200000-0000-4000-8000-000000000004', '98000000-0000-4000-8000-000000000001', '98100000-0000-4000-8000-000000000004', 'Member', false, '{"role":"member"}'),
  ('98200000-0000-4000-8000-000000000005', '98000000-0000-4000-8000-000000000001', null, 'AI Agent', true, '{"role":"agent"}'),
  ('98200000-0000-4000-8000-000000000006', '98000000-0000-4000-8000-000000000001', null, 'Pending Agent', false, '{"role":"agent","invitation":{"email":"pending@example.test","status":"pending"}}'),
  ('98200000-0000-4000-8000-000000000007', '98000000-0000-4000-8000-000000000001', null, 'Rejected Agent', false, '{"role":"agent","invitation":{"email":"rejected@example.test","status":"rejected"}}'),
  ('98200000-0000-4000-8000-000000000008', '98000000-0000-4000-8000-000000000002', '98100000-0000-4000-8000-000000000005', 'Other Agent', false, '{"role":"agent"}');

insert into public.organizations_addresses (
  organization_id, service, address, extra, status
) values
  ('98000000-0000-4000-8000-000000000001', 'whatsapp', 'transfer-org', '{}', 'connected'),
  ('98000000-0000-4000-8000-000000000002', 'whatsapp', 'transfer-other-org', '{}', 'connected');

insert into public.contacts (id, organization_id, name) values
  ('98300000-0000-4000-8000-000000000001', '98000000-0000-4000-8000-000000000001', 'Transfer Customer'),
  ('98300000-0000-4000-8000-000000000002', '98000000-0000-4000-8000-000000000002', 'Other Customer');

insert into public.contacts_addresses (
  organization_id, contact_id, service, address, extra
) values
  ('98000000-0000-4000-8000-000000000001', '98300000-0000-4000-8000-000000000001', 'whatsapp', '15559800001', '{}'),
  ('98000000-0000-4000-8000-000000000002', '98300000-0000-4000-8000-000000000002', 'whatsapp', '15559800002', '{}');

insert into public.conversations (
  id, organization_id, service, organization_address, contact_address,
  name, assigned_agent_id, status, extra, updated_at
) values
  ('98400000-0000-4000-8000-000000000001', '98000000-0000-4000-8000-000000000001', 'whatsapp', 'transfer-org', '15559800001', 'Successful Transfer', '98200000-0000-4000-8000-000000000001', 'active', '{}', '2026-01-01 00:00:00+00'),
  ('98400000-0000-4000-8000-000000000002', '98000000-0000-4000-8000-000000000001', 'whatsapp', 'transfer-org', '15559800001', 'Invalid Target', '98200000-0000-4000-8000-000000000001', 'active', '{}', '2026-01-02 00:00:00+00'),
  ('98400000-0000-4000-8000-000000000003', '98000000-0000-4000-8000-000000000001', 'whatsapp', 'transfer-org', '15559800001', 'Closed Transfer', '98200000-0000-4000-8000-000000000001', 'closed', '{}', '2026-01-03 00:00:00+00'),
  ('98400000-0000-4000-8000-000000000004', '98000000-0000-4000-8000-000000000001', 'whatsapp', 'transfer-org', '15559800001', 'Stale Transfer', '98200000-0000-4000-8000-000000000002', 'active', '{}', '2026-01-04 00:00:00+00'),
  ('98400000-0000-4000-8000-000000000005', '98000000-0000-4000-8000-000000000002', 'whatsapp', 'transfer-other-org', '15559800002', 'Other Org Transfer', '98200000-0000-4000-8000-000000000008', 'active', '{}', now());

insert into public.messages (
  id, organization_id, conversation_id, direction, contact_address, service,
  organization_address, content, status, timestamp
) values
  ('98500000-0000-4000-8000-000000000001', '98000000-0000-4000-8000-000000000001', '98400000-0000-4000-8000-000000000001', 'incoming', '15559800001', 'whatsapp', 'transfer-org', '{"version":"1","type":"text","kind":"text","text":"Original customer preview"}', '{}', '2026-02-01 00:00:00+00');

select set_config('request.jwt.claim.sub', '98100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select results_eq(
  $$
    select
      response->'conversation'->>'assigned_agent_id',
      response->'note'->'content'->>'text'
    from (
      select public.transfer_conversation_with_private_note(
        '98400000-0000-4000-8000-000000000001',
        '98200000-0000-4000-8000-000000000002',
        '  @Sara Please take over this marketing question  '
      ) response
    ) result
  $$,
  $$ values (
    '98200000-0000-4000-8000-000000000002'::text,
    '@Sara Please take over this marketing question'::text
  ) $$,
  'the assigned Agent atomically transfers with a required private explanation'
);

reset role;
set local search_path = extensions, public, auth, storage;

select results_eq(
  $$
    select
      direction::text,
      agent_id,
      content->>'kind',
      content->'transfer'->>'from_agent_id',
      content->'transfer'->>'to_agent_id',
      jsonb_array_length(content->'mentioned_agent_ids')
    from public.messages
    where content->>'text' = '@Sara Please take over this marketing question'
  $$,
  $$ values (
    'internal'::text,
    '98200000-0000-4000-8000-000000000001'::uuid,
    'private_note'::text,
    '98200000-0000-4000-8000-000000000001'::text,
    '98200000-0000-4000-8000-000000000002'::text,
    1
  ) $$,
  'the transfer is an internal private note with structured Agent ids'
);

select results_eq(
  $$
    select mention.mentioned_agent_id
    from public.message_mentions mention
    join public.messages message on message.id = mention.message_id
    where message.content->>'text' = '@Sara Please take over this marketing question'
  $$,
  $$ values ('98200000-0000-4000-8000-000000000002'::uuid) $$,
  'the target Agent receives a tenant-safe stored mention'
);

select is(
  (
    select assigned_agent_id
    from public.conversations
    where id = '98400000-0000-4000-8000-000000000001'
  ),
  '98200000-0000-4000-8000-000000000002'::uuid,
  'the conversation is assigned directly to the target Agent'
);

select results_eq(
  $$
    select
      topic,
      event,
      payload->>'organization_id',
      payload->>'conversation_id',
      payload->>'assigned_agent_id',
      payload ? 'name'
    from realtime.messages
    where event = 'conversation_state_changed'
      and payload->>'conversation_id' = '98400000-0000-4000-8000-000000000001'
  $$,
  $$ values (
    'conversation-queue:98000000-0000-4000-8000-000000000001'::text,
    'conversation_state_changed'::text,
    '98000000-0000-4000-8000-000000000001'::text,
    '98400000-0000-4000-8000-000000000001'::text,
    '98200000-0000-4000-8000-000000000002'::text,
    false
  ) $$,
  'assignment changes emit a tenant-scoped minimal queue reconciliation signal'
);

select set_config('request.jwt.claim.sub', '98100000-0000-4000-8000-000000000001', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select set_config(
  'realtime.topic',
  'conversation-queue:98000000-0000-4000-8000-000000000001',
  true
);

select results_eq(
  $$
    select event
    from realtime.messages
    where payload->>'conversation_id' = '98400000-0000-4000-8000-000000000001'
  $$,
  $$ values ('conversation_state_changed'::text) $$,
  'an accepted human can authorize the private queue topic for their organization'
);

select set_config(
  'realtime.topic',
  'conversation-queue:98000000-0000-4000-8000-000000000002',
  true
);

select is_empty(
  $$ select event from realtime.messages $$,
  'an accepted human cannot authorize another organization queue topic'
);

select is_empty(
  $$ select id from public.conversations where id = '98400000-0000-4000-8000-000000000001' $$,
  'the former Agent loses conversation access after transfer'
);

select throws_like(
  $$ insert into public.messages (
    organization_id, conversation_id, direction, agent_id, contact_address,
    service, organization_address, content, status
  ) values (
    '98000000-0000-4000-8000-000000000001',
    '98400000-0000-4000-8000-000000000001',
    'outgoing',
    '98200000-0000-4000-8000-000000000001',
    '15559800001',
    'whatsapp',
    'transfer-org',
    '{"version":"1","type":"text","kind":"text","text":"Ali reply blocked"}',
    '{}'
  ) $$,
  '%row-level security%',
  'the former Agent cannot reply to the customer'
);

select set_config('request.jwt.claim.sub', '98100000-0000-4000-8000-000000000002', true);
set local search_path = extensions, public, auth, storage;

select results_eq(
  $$ select id from public.conversations where id = '98400000-0000-4000-8000-000000000001' $$,
  $$ values ('98400000-0000-4000-8000-000000000001'::uuid) $$,
  'the target Agent can read the transferred conversation'
);

select lives_ok(
  $$ insert into public.messages (
    organization_id, conversation_id, direction, agent_id, contact_address,
    service, organization_address, content, status
  ) values (
    '98000000-0000-4000-8000-000000000001',
    '98400000-0000-4000-8000-000000000001',
    'outgoing',
    '98200000-0000-4000-8000-000000000002',
    '15559800001',
    'whatsapp',
    'transfer-org',
    '{"version":"1","type":"text","kind":"text","text":"Sara customer reply"}',
    '{}'
  ) $$,
  'the target Agent can reply to the customer'
);

select results_eq(
  $$
    select preview_message->'content'->>'text'
    from public.list_mentioned_conversations_page(
      '98000000-0000-4000-8000-000000000001', 1, 50, null
    )
    where id = '98400000-0000-4000-8000-000000000001'
  $$,
  $$ values ('Sara customer reply'::text) $$,
  'the Mentioned queue preview remains the latest non-private customer message'
);

select set_config('request.jwt.claim.sub', '98100000-0000-4000-8000-000000000001', true);
set local search_path = extensions, public, auth, storage;

select throws_ok(
  $$ select public.transfer_conversation_with_private_note(
    '98400000-0000-4000-8000-000000000002',
    '98200000-0000-4000-8000-000000000001',
    'self transfer'
  ) $$,
  '22023',
  'transfer target must be another accepted Agent',
  'self-transfer is rejected'
);

select throws_ok(
  $$ select public.transfer_conversation_with_private_note(
    '98400000-0000-4000-8000-000000000002',
    '98200000-0000-4000-8000-000000000005',
    'AI transfer'
  ) $$,
  '22023',
  'transfer target must be another accepted Agent',
  'AI targets are rejected'
);

select throws_ok(
  $$ select public.transfer_conversation_with_private_note(
    '98400000-0000-4000-8000-000000000002',
    '98200000-0000-4000-8000-000000000004',
    'Member transfer'
  ) $$,
  '22023',
  'transfer target must be another accepted Agent',
  'non-Agent human targets are rejected'
);

select throws_ok(
  $$ select public.transfer_conversation_with_private_note(
    '98400000-0000-4000-8000-000000000002',
    '98200000-0000-4000-8000-000000000006',
    'Pending transfer'
  ) $$,
  '22023',
  'transfer target must be another accepted Agent',
  'pending Agent targets are rejected'
);

select throws_ok(
  $$ select public.transfer_conversation_with_private_note(
    '98400000-0000-4000-8000-000000000002',
    '98200000-0000-4000-8000-000000000007',
    'Rejected transfer'
  ) $$,
  '22023',
  'transfer target must be another accepted Agent',
  'rejected Agent targets are rejected'
);

select throws_ok(
  $$ select public.transfer_conversation_with_private_note(
    '98400000-0000-4000-8000-000000000002',
    '98200000-0000-4000-8000-000000000008',
    'Cross-org transfer'
  ) $$,
  '22023',
  'transfer target must be another accepted Agent',
  'cross-organization targets are rejected'
);

select throws_ok(
  $$ select public.transfer_conversation_with_private_note(
    '98400000-0000-4000-8000-000000000002',
    null,
    'Null transfer'
  ) $$,
  '22023',
  'transfer target must be another accepted Agent',
  'a missing target is rejected'
);

select throws_ok(
  $$ select public.transfer_conversation_with_private_note(
    '98400000-0000-4000-8000-000000000002',
    '98200000-0000-4000-8000-000000000002',
    '   '
  ) $$,
  '22023',
  'transfer note text is required',
  'a private handoff explanation is required'
);

select throws_ok(
  $$ select public.transfer_conversation_with_private_note(
    '98400000-0000-4000-8000-000000000003',
    '98200000-0000-4000-8000-000000000002',
    'Closed transfer'
  ) $$,
  '22023',
  'only active conversations can be transferred',
  'closed conversations cannot be transferred'
);

select throws_ok(
  $$ select public.transfer_conversation_with_private_note(
    '98400000-0000-4000-8000-000000000004',
    '98200000-0000-4000-8000-000000000001',
    'Stale transfer'
  ) $$,
  '42501',
  'conversation is not assigned to the authenticated Agent',
  'a stale assignment cannot be seized'
);

select throws_ok(
  $$ select public.transfer_conversation_with_private_note(
    '98400000-0000-4000-8000-000000000005',
    '98200000-0000-4000-8000-000000000002',
    'Other organization'
  ) $$,
  '42501',
  'only the assigned Agent can transfer this conversation',
  'tenant isolation blocks transfers outside the Agent organization'
);

reset role;
set local search_path = extensions, public, auth, storage;

select is(
  (
    select count(*)
    from public.messages
    where conversation_id = '98400000-0000-4000-8000-000000000002'
  ),
  0::bigint,
  'failed transfers roll back without creating private notes'
);

select set_config('request.jwt.claim.sub', '98100000-0000-4000-8000-000000000003', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select throws_ok(
  $$ select public.transfer_conversation_with_private_note(
    '98400000-0000-4000-8000-000000000002',
    '98200000-0000-4000-8000-000000000002',
    'Supervisor transfer through Agent RPC'
  ) $$,
  '42501',
  'only the assigned Agent can transfer this conversation',
  'supervisors keep using their existing assignment control'
);

select * from finish();
rollback;
