begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, storage;

select no_plan();

insert into public.organizations (id, name, extra) values
  ('aa000000-0000-4000-8000-000000000001', 'Queue Transfer Org', '{}'),
  ('aa000000-0000-4000-8000-000000000002', 'Other Queue Transfer Org', '{}');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at, created_at,
  updated_at, confirmation_token, recovery_token, email_change_token_new,
  email_change
) values
  ('00000000-0000-0000-0000-000000000000', 'aa100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'queue-transfer-ali@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'aa100000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'queue-transfer-sara@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'aa100000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'queue-transfer-supervisor@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'aa100000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'queue-transfer-member@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-8000-000000000000', 'aa100000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'queue-transfer-other@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', '');

insert into public.agents (
  id, organization_id, user_id, name, ai, extra
) values
  ('aa200000-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000001', 'aa100000-0000-4000-8000-000000000001', 'Ali', false, '{"role":"agent"}'),
  ('aa200000-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000001', 'aa100000-0000-4000-8000-000000000002', 'Sara', false, '{"role":"agent"}'),
  ('aa200000-0000-4000-8000-000000000003', 'aa000000-0000-4000-8000-000000000001', 'aa100000-0000-4000-8000-000000000003', 'Supervisor', false, '{"role":"supervisor"}'),
  ('aa200000-0000-4000-8000-000000000004', 'aa000000-0000-4000-8000-000000000001', 'aa100000-0000-4000-8000-000000000004', 'Member', false, '{"role":"member"}'),
  ('aa200000-0000-4000-8000-000000000005', 'aa000000-0000-4000-8000-000000000002', 'aa100000-0000-4000-8000-000000000005', 'Other Agent', false, '{"role":"agent"}');

insert into public.organizations_addresses (
  organization_id, service, address, extra, status
) values
  ('aa000000-0000-4000-8000-000000000001', 'whatsapp', 'queue-transfer-org', '{}', 'connected'),
  ('aa000000-0000-4000-8000-000000000002', 'whatsapp', 'queue-transfer-other', '{}', 'connected');

insert into public.contacts (id, organization_id, name) values
  ('aa300000-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000001', 'VIP Customer'),
  ('aa300000-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000002', 'Other Customer');

insert into public.contacts_addresses (
  organization_id, contact_id, service, address, extra
) values
  ('aa000000-0000-4000-8000-000000000001', 'aa300000-0000-4000-8000-000000000001', 'whatsapp', '15551100001', '{}'),
  ('aa000000-0000-4000-8000-000000000002', 'aa300000-0000-4000-8000-000000000002', 'whatsapp', '15551100002', '{}');

insert into public.routing_queues (
  id, organization_id, name, status
) values
  ('aa400000-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000001', 'VIP Support', 'active'),
  ('aa400000-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000001', 'Marketing', 'active'),
  ('aa400000-0000-4000-8000-000000000003', 'aa000000-0000-4000-8000-000000000001', 'Archived Queue', 'archived'),
  ('aa400000-0000-4000-8000-000000000004', 'aa000000-0000-4000-8000-000000000002', 'Other Queue', 'active');

insert into public.routing_queue_members (
  organization_id, routing_queue_id, agent_id
) values
  ('aa000000-0000-4000-8000-000000000001', 'aa400000-0000-4000-8000-000000000001', 'aa200000-0000-4000-8000-000000000001'),
  ('aa000000-0000-4000-8000-000000000001', 'aa400000-0000-4000-8000-000000000002', 'aa200000-0000-4000-8000-000000000002'),
  ('aa000000-0000-4000-8000-000000000002', 'aa400000-0000-4000-8000-000000000004', 'aa200000-0000-4000-8000-000000000005');

insert into public.conversations (
  id, organization_id, service, organization_address, contact_address,
  name, assigned_agent_id, routing_queue_id, routed_at, status, extra
) values
  ('aa500000-0000-4000-8000-000000000001', 'aa000000-0000-4000-8000-000000000001', 'whatsapp', 'queue-transfer-org', '15551100001', 'Ali VIP Transfer', 'aa200000-0000-4000-8000-000000000001', 'aa400000-0000-4000-8000-000000000001', '2026-08-01 00:00:00+00', 'active', '{}'),
  ('aa500000-0000-4000-8000-000000000002', 'aa000000-0000-4000-8000-000000000001', 'whatsapp', 'queue-transfer-org', '15551100001', 'Invalid Transfer', 'aa200000-0000-4000-8000-000000000001', 'aa400000-0000-4000-8000-000000000001', '2026-08-01 00:00:00+00', 'active', '{}'),
  ('aa500000-0000-4000-8000-000000000003', 'aa000000-0000-4000-8000-000000000001', 'whatsapp', 'queue-transfer-org', '15551100001', 'Closed Transfer', 'aa200000-0000-4000-8000-000000000001', 'aa400000-0000-4000-8000-000000000001', '2026-08-01 00:00:00+00', 'closed', '{}'),
  ('aa500000-0000-4000-8000-000000000004', 'aa000000-0000-4000-8000-000000000001', 'whatsapp', 'queue-transfer-org', '15551100001', 'Manager Transfer', 'aa200000-0000-4000-8000-000000000001', 'aa400000-0000-4000-8000-000000000001', '2026-08-01 00:00:00+00', 'active', '{}'),
  ('aa500000-0000-4000-8000-000000000005', 'aa000000-0000-4000-8000-000000000002', 'whatsapp', 'queue-transfer-other', '15551100002', 'Other Transfer', 'aa200000-0000-4000-8000-000000000005', 'aa400000-0000-4000-8000-000000000004', '2026-08-01 00:00:00+00', 'active', '{}'),
  ('aa500000-0000-4000-8000-000000000006', 'aa000000-0000-4000-8000-000000000001', 'whatsapp', 'queue-transfer-org', '15551100001', 'Chatbot Handoff', null, null, null, 'active', '{}');

insert into public.messages (
  id, organization_id, conversation_id, direction, contact_address, service,
  organization_address, content, status, timestamp
) values (
  'aa600000-0000-4000-8000-000000000001',
  'aa000000-0000-4000-8000-000000000001',
  'aa500000-0000-4000-8000-000000000001',
  'incoming',
  '15551100001',
  'whatsapp',
  'queue-transfer-org',
  '{"version":"1","type":"text","kind":"text","text":"Original customer preview"}',
  '{}',
  '2026-08-02 00:00:00+00'
);

select set_config('request.jwt.claim.sub', 'aa100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select results_eq(
  $$
    select id, name
    from public.list_transferable_routing_queue_options(
      'aa500000-0000-4000-8000-000000000001'
    )
  $$,
  $$ values (
    'aa400000-0000-4000-8000-000000000002'::uuid,
    'Marketing'::text
  ) $$,
  'the assigned Agent sees every active destination except the current queue even without membership'
);

select results_eq(
  $$
    select
      result->'conversation'->>'routing_queue_id',
      result->'conversation'->>'assigned_agent_id',
      result->'note'->'content'->'routing_transfer'->>'from_queue_name',
      result->'note'->'content'->'routing_transfer'->>'to_queue_name',
      result->'routing_event'->>'source'
    from (
      select public.transfer_conversation_to_queue_with_private_note(
        'aa500000-0000-4000-8000-000000000001',
        'aa400000-0000-4000-8000-000000000002',
        '  Customer now needs help with a marketing campaign.  '
      ) result
    ) transfer
  $$,
  $$ values (
    'aa400000-0000-4000-8000-000000000002'::text,
    null::text,
    'VIP Support'::text,
    'Marketing'::text,
    'manual_transfer'::text
  ) $$,
  'queue transfer atomically returns the unassigned conversation, private note, and routing event'
);

select is_empty(
  $$
    select id from public.conversations
    where id = 'aa500000-0000-4000-8000-000000000001'
  $$,
  'the former Agent loses access after transfer to a queue they do not belong to'
);

select throws_ok(
  $$ select public.transfer_conversation_to_queue_with_private_note(
    'aa500000-0000-4000-8000-000000000002',
    'aa400000-0000-4000-8000-000000000001',
    'Same queue'
  ) $$,
  '22023',
  'destination queue must be different from the current queue',
  'the current queue is rejected'
);

select throws_ok(
  $$ select public.transfer_conversation_to_queue_with_private_note(
    'aa500000-0000-4000-8000-000000000002',
    'aa400000-0000-4000-8000-000000000003',
    'Archived queue'
  ) $$,
  '22023',
  'destination must be an active queue in the same organization',
  'archived destinations are rejected'
);

select throws_ok(
  $$ select public.transfer_conversation_to_queue_with_private_note(
    'aa500000-0000-4000-8000-000000000002',
    'aa400000-0000-4000-8000-000000000004',
    'Cross tenant queue'
  ) $$,
  '22023',
  'destination must be an active queue in the same organization',
  'cross-tenant destinations are rejected'
);

select throws_ok(
  $$ select public.transfer_conversation_to_queue_with_private_note(
    'aa500000-0000-4000-8000-000000000002',
    'aa400000-0000-4000-8000-000000000002',
    '   '
  ) $$,
  '22023',
  'queue transfer explanation is required',
  'a queue transfer explanation is mandatory'
);

select throws_ok(
  $$ select public.transfer_conversation_to_queue_with_private_note(
    'aa500000-0000-4000-8000-000000000003',
    'aa400000-0000-4000-8000-000000000002',
    'Closed conversation'
  ) $$,
  '22023',
  'only active conversations can be transferred',
  'inactive conversations cannot be transferred'
);

reset role;
set local search_path = extensions, public, auth, storage;

select results_eq(
  $$
    select recipient_agent_id, actor_agent_id, conversation_id, notification_type,
      payload->>'to_queue_name'
    from public.user_notifications
  $$,
  $$ values (
    'aa200000-0000-4000-8000-000000000002'::uuid,
    'aa200000-0000-4000-8000-000000000001'::uuid,
    'aa500000-0000-4000-8000-000000000001'::uuid,
    'conversation_transferred_to_queue'::text,
    'Marketing'::text
  ) $$,
  'each destination queue member receives one queue-transfer notification'
);

select results_eq(
  $$
    select
      direction::text,
      agent_id,
      content->>'kind',
      content->>'text',
      jsonb_array_length(content->'mentioned_agent_ids')
    from public.messages
    where conversation_id = 'aa500000-0000-4000-8000-000000000001'
      and content->>'kind' = 'private_note'
  $$,
  $$ values (
    'internal'::text,
    'aa200000-0000-4000-8000-000000000001'::uuid,
    'private_note'::text,
    'Customer now needs help with a marketing campaign.'::text,
    0
  ) $$,
  'the transfer explanation is an undispatched internal private note without synthetic mentions'
);

select results_eq(
  $$
    select
      previous_routing_queue_id,
      previous_routing_queue_name,
      destination_routing_queue_id,
      destination_routing_queue_name,
      actor_agent_id,
      source,
      explanation
    from public.conversation_routing_events
    where conversation_id = 'aa500000-0000-4000-8000-000000000001'
  $$,
  $$ values (
    'aa400000-0000-4000-8000-000000000001'::uuid,
    'VIP Support'::text,
    'aa400000-0000-4000-8000-000000000002'::uuid,
    'Marketing'::text,
    'aa200000-0000-4000-8000-000000000001'::uuid,
    'manual_transfer'::text,
    'Customer now needs help with a marketing campaign.'::text
  ) $$,
  'routing history preserves queue and actor snapshots with the normalized explanation'
);

select is(
  (
    select count(*)
    from public.messages
    where conversation_id = 'aa500000-0000-4000-8000-000000000002'
  ),
  0::bigint,
  'failed transfers roll back without creating a private note'
);

select is(
  (
    select count(*)
    from public.conversation_routing_events
    where conversation_id = 'aa500000-0000-4000-8000-000000000002'
  ),
  0::bigint,
  'failed transfers roll back without creating a routing event'
);

select results_eq(
  $$
    select payload->>'routing_queue_id', payload->>'assigned_agent_id'
    from realtime.messages
    where event = 'conversation_state_changed'
      and payload->>'conversation_id' = 'aa500000-0000-4000-8000-000000000001'
    order by inserted_at desc
    limit 1
  $$,
  $$ values (
    'aa400000-0000-4000-8000-000000000002'::text,
    null::text
  ) $$,
  'queue transfer broadcasts the destination queue and cleared assignment'
);

select ok(
  position(
    'private_note' in pg_get_functiondef('public.notify_webhook()'::regprocedure)
  ) > 0,
  'message webhooks continue to exclude queue-transfer private notes'
);

select public.route_conversation_to_queue(
  'aa500000-0000-4000-8000-000000000006',
  'aa400000-0000-4000-8000-000000000001'
);

select results_eq(
  $$
    select
      previous_routing_queue_id,
      destination_routing_queue_name,
      actor_agent_id,
      source,
      explanation
    from public.conversation_routing_events
    where conversation_id = 'aa500000-0000-4000-8000-000000000006'
  $$,
  $$ values (
    null::uuid,
    'VIP Support'::text,
    null::uuid,
    'chatbot_handoff'::text,
    null::text
  ) $$,
  'the chatbot Route Resolver records the initial queue handoff'
);

select set_config('request.jwt.claim.sub', 'aa100000-0000-4000-8000-000000000003', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select results_eq(
  $$
    select
      result->'conversation'->>'routing_queue_id',
      result->'conversation'->>'assigned_agent_id'
    from (
      select public.transfer_conversation_to_queue_with_private_note(
        'aa500000-0000-4000-8000-000000000004',
        'aa400000-0000-4000-8000-000000000002',
        'Supervisor moved this to Marketing.'
      ) result
    ) transfer
  $$,
  $$ values (
    'aa400000-0000-4000-8000-000000000002'::text,
    null::text
  ) $$,
  'a Supervisor can transfer any active conversation in organization scope'
);

select set_config('request.jwt.claim.sub', 'aa100000-0000-4000-8000-000000000004', true);
set local search_path = extensions, public, auth, storage;

select throws_ok(
  $$ select public.list_transferable_routing_queue_options(
    'aa500000-0000-4000-8000-000000000004'
  ) $$,
  '42501',
  'conversation queue transfer is not permitted',
  'ordinary Members cannot transfer queue ownership'
);

select set_config('request.jwt.claim.sub', 'aa100000-0000-4000-8000-000000000002', true);
set local search_path = extensions, public, auth, storage;

select results_eq(
  $$
    select routing_queue_id, assigned_agent_id
    from public.conversations
    where id = 'aa500000-0000-4000-8000-000000000001'
  $$,
  $$ values (
    'aa400000-0000-4000-8000-000000000002'::uuid,
    null::uuid
  ) $$,
  'a destination queue member can see the transferred Pending conversation'
);

select lives_ok(
  $$ select public.assign_conversation_to_me(
    'aa500000-0000-4000-8000-000000000001'
  ) $$,
  'a destination queue member can claim the transferred conversation'
);

reset role;
set local search_path = extensions, public, auth, storage;

select is(
  (
    select assigned_agent_id
    from public.conversations
    where id = 'aa500000-0000-4000-8000-000000000001'
  ),
  'aa200000-0000-4000-8000-000000000002'::uuid,
  'claiming assigns the destination Agent without changing the routing queue'
);

select throws_like(
  $$
    set local role authenticated;
    insert into public.conversation_routing_events (
      organization_id,
      conversation_id,
      destination_routing_queue_id,
      destination_routing_queue_name,
      source
    ) values (
      'aa000000-0000-4000-8000-000000000001',
      'aa500000-0000-4000-8000-000000000001',
      'aa400000-0000-4000-8000-000000000002',
      'Marketing',
      'chatbot_handoff'
    )
  $$,
  '%permission denied%',
  'clients cannot write append-only routing history directly'
);

select * from finish();
rollback;
