begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, storage;
select no_plan();

insert into public.organizations (id, name, extra) values
  ('a1000000-0000-4000-8000-000000000001', 'VIP Routing Org', '{}'),
  ('a1000000-0000-4000-8000-000000000002', 'Other Routing Org', '{}');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at, created_at,
  updated_at, confirmation_token, recovery_token, email_change_token_new,
  email_change
) values
  ('00000000-0000-0000-0000-000000000000', 'a1100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'vip-supervisor@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'a1100000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'vip-ali@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'a1100000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'vip-nonmember@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'a1100000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'vip-pending@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'a1100000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'other-agent@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', '');

insert into public.agents (id, organization_id, user_id, name, ai, extra) values
  ('a1200000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', 'a1100000-0000-4000-8000-000000000001', 'Supervisor', false, '{"role":"supervisor"}'),
  ('a1200000-0000-4000-8000-000000000002', 'a1000000-0000-4000-8000-000000000001', 'a1100000-0000-4000-8000-000000000002', 'Ali', false, '{"role":"agent"}'),
  ('a1200000-0000-4000-8000-000000000003', 'a1000000-0000-4000-8000-000000000001', 'a1100000-0000-4000-8000-000000000003', 'Nonmember', false, '{"role":"agent"}'),
  ('a1200000-0000-4000-8000-000000000004', 'a1000000-0000-4000-8000-000000000001', 'a1100000-0000-4000-8000-000000000004', 'Pending', false, '{"role":"agent","invitation":{"status":"pending","email":"vip-pending@example.test"}}'),
  ('a1200000-0000-4000-8000-000000000005', 'a1000000-0000-4000-8000-000000000001', null, 'Runtime', true, '{"kind":"chatbot_runtime","mode":"active"}'),
  ('a1200000-0000-4000-8000-000000000006', 'a1000000-0000-4000-8000-000000000002', 'a1100000-0000-4000-8000-000000000005', 'Other Agent', false, '{"role":"agent"}');

insert into public.organizations_addresses (
  organization_id, service, address, extra, status
) values
  ('a1000000-0000-4000-8000-000000000001', 'local', 'vip-routing-address', '{}', 'connected'),
  ('a1000000-0000-4000-8000-000000000002', 'local', 'other-routing-address', '{}', 'connected');

select set_config('request.jwt.claim.sub', 'a1100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select results_eq(
  $$
    select name, status
    from public.create_routing_queue(
      'a1000000-0000-4000-8000-000000000001',
      '  VIP Support  ',
      array['a1200000-0000-4000-8000-000000000002'::uuid]
    )
  $$,
  $$ values ('VIP Support'::text, 'active'::text) $$,
  'Supervisor creates the VIP queue with normalized name'
);

select results_eq(
  $$
    select name, member_count, total_count
    from public.list_routing_queues_page(
      'a1000000-0000-4000-8000-000000000001', 1, 10, 'VIP'
    )
  $$,
  $$ values ('VIP Support'::text, 1::bigint, 1::bigint) $$,
  'Queue management list searches and counts members'
);

select throws_ok(
  $$ select public.create_routing_queue(
    'a1000000-0000-4000-8000-000000000001',
    'Invalid Members',
    array['a1200000-0000-4000-8000-000000000004'::uuid]
  ) $$,
  '22023',
  'routing queue members must be accepted human Agents in the same organization',
  'Pending Agents cannot become queue members'
);

select throws_ok(
  $$ select public.create_routing_queue(
    'a1000000-0000-4000-8000-000000000001',
    'Cross Tenant',
    array['a1200000-0000-4000-8000-000000000006'::uuid]
  ) $$,
  '22023',
  'routing queue members must be accepted human Agents in the same organization',
  'Cross-tenant Agents cannot become queue members'
);

select throws_like(
  $$ insert into public.routing_queues (organization_id, name)
     values ('a1000000-0000-4000-8000-000000000001', 'Blocked') $$,
  '%permission denied for table routing_queues%',
  'Direct client queue writes are blocked'
);

reset role;

insert into public.conversations (
  organization_id, id, service, organization_address, name, extra
) values (
  'a1000000-0000-4000-8000-000000000001',
  'a1300000-0000-4000-8000-000000000001',
  'local',
  'vip-routing-address',
  'VIP Customer',
  '{}'
);

insert into public.messages (
  organization_id, conversation_id, id, external_id, direction, service,
  organization_address, content, status, created_at
) values (
  'a1000000-0000-4000-8000-000000000001',
  'a1300000-0000-4000-8000-000000000001',
  'a1400000-0000-4000-8000-000000000001',
  'vip-message-1',
  'incoming',
  'local',
  'vip-routing-address',
  '{"version":"1","type":"text","kind":"text","text":"human"}',
  '{}',
  now()
);

insert into public.chatbot_flows (organization_id, id, name) values (
  'a1000000-0000-4000-8000-000000000001',
  'a1500000-0000-4000-8000-000000000001',
  'VIP Flow'
);

insert into public.chatbot_flow_versions (
  organization_id, flow_id, id, version, status, definition, published_at
) values (
  'a1000000-0000-4000-8000-000000000001',
  'a1500000-0000-4000-8000-000000000001',
  'a1600000-0000-4000-8000-000000000001',
  1,
  'published',
  jsonb_build_object(
    'schema_version', 1,
    'start_node_id', 'handoff',
    'nodes', jsonb_build_array(jsonb_build_object(
      'id', 'handoff',
      'type', 'assign_agent',
      'config', jsonb_build_object(
        'routing_queue_id', (
          select id from public.routing_queues
          where organization_id = 'a1000000-0000-4000-8000-000000000001'
            and name = 'VIP Support'
        )
      )
    )),
    'edges', '[]'::jsonb
  ),
  now()
);

insert into public.chatbot_flow_runs (
  organization_id, conversation_id, flow_version_id, agent_id, id,
  current_node_id
) values (
  'a1000000-0000-4000-8000-000000000001',
  'a1300000-0000-4000-8000-000000000001',
  'a1600000-0000-4000-8000-000000000001',
  'a1200000-0000-4000-8000-000000000005',
  'a1700000-0000-4000-8000-000000000001',
  'handoff'
);

select is(
  (
    select outcome
    from public.commit_chatbot_flow_execution(
      p_run_id => 'a1700000-0000-4000-8000-000000000001',
      p_expected_lock_version => 0,
      p_message_id => 'a1400000-0000-4000-8000-000000000001',
      p_current_node_id => 'handoff',
      p_status => 'handed_off',
      p_waiting_for => null,
      p_variables => '{}',
      p_error => null,
      p_outgoing_texts => array[]::text[],
      p_handoff_routing_queue_id => (
        select id from public.routing_queues
        where organization_id = 'a1000000-0000-4000-8000-000000000001'
          and name = 'VIP Support'
      )
    )
  ),
  'committed',
  'Chatbot handoff commits to the VIP queue'
);

select results_eq(
  $$
    select queue.name, conversation.assigned_agent_id, conversation.routed_at is not null
    from public.conversations conversation
    join public.routing_queues queue on queue.id = conversation.routing_queue_id
    where conversation.id = 'a1300000-0000-4000-8000-000000000001'
  $$,
  $$ values ('VIP Support'::text, null::uuid, true) $$,
  'Queue handoff records routing while leaving the conversation unassigned'
);

select set_config('request.jwt.claim.sub', 'a1100000-0000-4000-8000-000000000003', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select is_empty(
  $$ select * from public.list_routing_queue_options(
    'a1000000-0000-4000-8000-000000000001'
  ) $$,
  'Nonmember Agent receives no VIP queue option'
);

select is(
  (
    select count(*)
    from public.conversations
    where id = 'a1300000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'Nonmember Agent cannot read an unassigned VIP conversation'
);

select throws_ok(
  $$ select public.assign_conversation_to_me(
    'a1300000-0000-4000-8000-000000000001'
  ) $$,
  '42501',
  'conversation is not accessible to the authenticated user',
  'Nonmember Agent cannot claim the VIP conversation'
);

reset role;
select set_config('request.jwt.claim.sub', 'a1100000-0000-4000-8000-000000000002', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select results_eq(
  $$ select name from public.list_routing_queue_options(
    'a1000000-0000-4000-8000-000000000001'
  ) $$,
  $$ values ('VIP Support'::text) $$,
  'VIP member sees the queue option'
);

select is(
  (
    select assigned_agent_id
    from public.assign_conversation_to_me(
      'a1300000-0000-4000-8000-000000000001'
    )
  ),
  'a1200000-0000-4000-8000-000000000002'::uuid,
  'VIP member claims the conversation'
);

select throws_ok(
  $$ select public.transfer_conversation_with_private_note(
    'a1300000-0000-4000-8000-000000000001',
    'a1200000-0000-4000-8000-000000000003',
    'Please continue'
  ) $$,
  '22023',
  'transfer target must belong to the conversation routing queue',
  'Transfer rejects an Agent outside the routing queue'
);

reset role;
select set_config('request.jwt.claim.sub', 'a1100000-0000-4000-8000-000000000001', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select throws_ok(
  $$ select public.set_conversation_agent_assignment(
    'a1300000-0000-4000-8000-000000000001',
    'a1200000-0000-4000-8000-000000000003'
  ) $$,
  '23514',
  'assignee must belong to the conversation routing queue',
  'Manager assignment rejects a nonmember Agent'
);

select * from finish();
rollback;
