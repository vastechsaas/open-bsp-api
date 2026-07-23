begin;

create extension if not exists pgtap with schema extensions;

set local search_path = extensions, public, auth;

select plan(25);

insert into public.organizations (id, name, extra)
values
  ('15000000-0000-4000-8000-000000000001', 'Execution Org A', '{}'),
  ('15000000-0000-4000-8000-000000000002', 'Execution Org B', '{}');

insert into public.agents (id, organization_id, name, ai, extra)
values
  (
    '35000000-0000-4000-8000-000000000001',
    '15000000-0000-4000-8000-000000000001',
    'Execution Bot A',
    true,
    '{"mode":"active"}'
  ),
  (
    '35000000-0000-4000-8000-000000000002',
    '15000000-0000-4000-8000-000000000001',
    'Execution Human A',
    false,
    '{"role":"admin"}'
  ),
  (
    '35000000-0000-4000-8000-000000000003',
    '15000000-0000-4000-8000-000000000002',
    'Execution Bot B',
    true,
    '{"mode":"active"}'
  );

insert into public.organizations_addresses (
  organization_id,
  service,
  address,
  extra,
  status
)
values
  (
    '15000000-0000-4000-8000-000000000001',
    'local',
    'execution-org-a',
    '{}',
    'connected'
  ),
  (
    '15000000-0000-4000-8000-000000000002',
    'local',
    'execution-org-b',
    '{}',
    'connected'
  );

insert into public.conversations (
  organization_id,
  id,
  service,
  organization_address,
  name,
  extra
)
values
  (
    '15000000-0000-4000-8000-000000000001',
    '55000000-0000-4000-8000-000000000001',
    'local',
    'execution-org-a',
    'Execution Conversation A1',
    '{}'
  ),
  (
    '15000000-0000-4000-8000-000000000001',
    '55000000-0000-4000-8000-000000000002',
    'local',
    'execution-org-a',
    'Execution Conversation A2',
    '{}'
  ),
  (
    '15000000-0000-4000-8000-000000000002',
    '55000000-0000-4000-8000-000000000003',
    'local',
    'execution-org-b',
    'Execution Conversation B',
    '{}'
  );

insert into public.messages (
  organization_id,
  conversation_id,
  id,
  external_id,
  direction,
  service,
  organization_address,
  content,
  status,
  created_at
)
values
  (
    '15000000-0000-4000-8000-000000000001',
    '55000000-0000-4000-8000-000000000001',
    '65000000-0000-4000-8000-000000000001',
    'execution-message-1',
    'incoming',
    'local',
    'execution-org-a',
    '{"version":"1","type":"text","kind":"text","text":"hello"}',
    '{}',
    now() - interval '3 minutes'
  ),
  (
    '15000000-0000-4000-8000-000000000001',
    '55000000-0000-4000-8000-000000000001',
    '65000000-0000-4000-8000-000000000002',
    'execution-message-2',
    'incoming',
    'local',
    'execution-org-a',
    '{"version":"1","type":"text","kind":"text","text":"Lahore"}',
    '{}',
    now() - interval '2 minutes'
  ),
  (
    '15000000-0000-4000-8000-000000000001',
    '55000000-0000-4000-8000-000000000001',
    '65000000-0000-4000-8000-000000000003',
    'execution-message-3',
    'incoming',
    'local',
    'execution-org-a',
    '{"version":"1","type":"text","kind":"text","text":"next"}',
    '{}',
    now() - interval '1 minute'
  ),
  (
    '15000000-0000-4000-8000-000000000001',
    '55000000-0000-4000-8000-000000000002',
    '65000000-0000-4000-8000-000000000004',
    'execution-message-4',
    'incoming',
    'local',
    'execution-org-a',
    '{"version":"1","type":"text","kind":"text","text":"other"}',
    '{}',
    now()
  ),
  (
    '15000000-0000-4000-8000-000000000001',
    '55000000-0000-4000-8000-000000000001',
    '65000000-0000-4000-8000-000000000005',
    'execution-outgoing-message',
    'outgoing',
    'local',
    'execution-org-a',
    '{"version":"1","type":"text","kind":"text","text":"sent"}',
    '{}',
    now()
  );

insert into public.chatbot_flows (organization_id, id, name)
values
  (
    '15000000-0000-4000-8000-000000000001',
    '75000000-0000-4000-8000-000000000001',
    'Execution Flow A'
  ),
  (
    '15000000-0000-4000-8000-000000000002',
    '75000000-0000-4000-8000-000000000002',
    'Execution Flow B'
  );

insert into public.chatbot_flow_versions (
  organization_id,
  flow_id,
  id,
  version,
  status,
  editor_graph,
  definition,
  published_at
)
values
  (
    '15000000-0000-4000-8000-000000000001',
    '75000000-0000-4000-8000-000000000001',
    '85000000-0000-4000-8000-000000000001',
    1,
    'published',
    '{"nodes":[],"edges":[]}',
    '{"schema_version":1,"start_node_id":"start","nodes":[{"id":"start","type":"start","config":{}},{"id":"end","type":"end","config":{}}],"edges":[{"id":"edge-1","source":"start","target":"end","kind":"default"}]}',
    now()
  ),
  (
    '15000000-0000-4000-8000-000000000001',
    '75000000-0000-4000-8000-000000000001',
    '85000000-0000-4000-8000-000000000002',
    2,
    'draft',
    '{"nodes":[],"edges":[]}',
    null,
    null
  ),
  (
    '15000000-0000-4000-8000-000000000002',
    '75000000-0000-4000-8000-000000000002',
    '85000000-0000-4000-8000-000000000003',
    1,
    'published',
    '{"nodes":[],"edges":[]}',
    '{"schema_version":1,"start_node_id":"start","nodes":[{"id":"start","type":"start","config":{}},{"id":"end","type":"end","config":{}}],"edges":[{"id":"edge-1","source":"start","target":"end","kind":"default"}]}',
    now()
  );

select throws_ok(
  $$
    insert into public.chatbot_flow_runs (
      organization_id,
      conversation_id,
      flow_version_id,
      agent_id,
      current_node_id
    ) values (
      '15000000-0000-4000-8000-000000000001',
      '55000000-0000-4000-8000-000000000002',
      '85000000-0000-4000-8000-000000000001',
      '35000000-0000-4000-8000-000000000002',
      'start'
    )
  $$,
  '23514',
  'chatbot flow runs require an AI agent from the same organization',
  'runs reject human sender identities'
);

select is(
  (
    select outcome
    from public.prepare_chatbot_flow_execution(
      '65000000-0000-4000-8000-000000000001',
      '85000000-0000-4000-8000-000000000001',
      '35000000-0000-4000-8000-000000000001'
    )
  ),
  'ready'::text,
  'prepare creates a ready run'
);

select is(
  (
    select agent_id
    from public.chatbot_flow_runs
    where conversation_id = '55000000-0000-4000-8000-000000000001'
      and status = 'running'
  ),
  '35000000-0000-4000-8000-000000000001'::uuid,
  'new runs pin the AI sender identity'
);

select is(
  (
    select outcome
    from public.commit_chatbot_flow_execution(
      (
        select id from public.chatbot_flow_runs
        where conversation_id = '55000000-0000-4000-8000-000000000001'
          and status = 'running'
      ),
      0,
      '65000000-0000-4000-8000-000000000001',
      'collect-city',
      'waiting',
      'free_text',
      '{}',
      null,
      array['Which city are you in?']
    )
  ),
  'committed'::text,
  'commit atomically records a waiting transition'
);

select is(
  (
    select lock_version
    from public.chatbot_flow_runs
    where conversation_id = '55000000-0000-4000-8000-000000000001'
      and status = 'waiting'
  ),
  1::bigint,
  'commit increments the optimistic lock version'
);

select ok(
  (
    select expires_at between now() + interval '59 minutes'
      and now() + interval '61 minutes'
    from public.chatbot_flow_runs
    where conversation_id = '55000000-0000-4000-8000-000000000001'
      and status = 'waiting'
  ),
  'waiting runs expire after one hour'
);

select is(
  (
    select agent_id
    from public.messages
    where content->>'text' = 'Which city are you in?'
  ),
  '35000000-0000-4000-8000-000000000001'::uuid,
  'outgoing chatbot messages use the pinned AI agent'
);

select is(
  (
    select outcome
    from public.prepare_chatbot_flow_execution(
      '65000000-0000-4000-8000-000000000001'
    )
  ),
  'duplicate'::text,
  'prepare identifies a duplicate inbound message'
);

select is(
  (
    select outcome
    from public.commit_chatbot_flow_execution(
      (
        select id from public.chatbot_flow_runs
        where conversation_id = '55000000-0000-4000-8000-000000000001'
          and status = 'waiting'
      ),
      0,
      '65000000-0000-4000-8000-000000000002',
      'collect-city',
      'waiting',
      'free_text',
      '{}',
      null,
      array[]::text[]
    )
  ),
  'conflict'::text,
  'commit rejects an outdated lock version'
);

select is(
  (
    select outcome
    from public.prepare_chatbot_flow_execution(
      '65000000-0000-4000-8000-000000000002'
    )
  ),
  'ready'::text,
  'prepare resumes an active waiting run'
);

select is(
  (
    select outcome
    from public.commit_chatbot_flow_execution(
      (
        select id from public.chatbot_flow_runs
        where conversation_id = '55000000-0000-4000-8000-000000000001'
          and status = 'waiting'
      ),
      1,
      '65000000-0000-4000-8000-000000000002',
      'collect-city',
      'waiting',
      'free_text',
      '{"customer_city":"Lahore"}',
      null,
      array['Please confirm']
    )
  ),
  'committed'::text,
  'a newer message advances the same run'
);

select is(
  (
    select outcome
    from public.prepare_chatbot_flow_execution(
      '65000000-0000-4000-8000-000000000001'
    )
  ),
  'stale'::text,
  'prepare rejects an older inbound message'
);

select is(
  (
    select outcome
    from public.prepare_chatbot_flow_execution(
      '65000000-0000-4000-8000-000000000002'
    )
  ),
  'duplicate'::text,
  'the latest committed message remains idempotent'
);

select throws_ok(
  format(
    $test$
      select * from public.commit_chatbot_flow_execution(
        %L,
        2,
        '65000000-0000-4000-8000-000000000003',
        'collect-city',
        'waiting',
        'free_text',
        '{}',
        null,
        array['   ']
      )
    $test$,
    (
      select id from public.chatbot_flow_runs
      where conversation_id = '55000000-0000-4000-8000-000000000001'
        and status = 'waiting'
    )
  ),
  '23514',
  'outgoing chatbot text must contain 1 to 4096 characters',
  'invalid outgoing text rolls back the commit'
);

select is(
  (
    select lock_version
    from public.chatbot_flow_runs
    where conversation_id = '55000000-0000-4000-8000-000000000001'
      and status = 'waiting'
  ),
  2::bigint,
  'a failed commit leaves the run version unchanged'
);

select is(
  (
    select count(*)::integer
    from public.messages
    where direction = 'outgoing'
      and conversation_id = '55000000-0000-4000-8000-000000000001'
      and agent_id = '35000000-0000-4000-8000-000000000001'
  ),
  2,
  'a failed commit inserts no partial outgoing message'
);

update public.chatbot_flow_runs
set
  started_at = now() - interval '2 hours',
  expires_at = now() - interval '1 hour'
where conversation_id = '55000000-0000-4000-8000-000000000001'
  and status = 'waiting';

select is(
  (
    select outcome
    from public.prepare_chatbot_flow_execution(
      '65000000-0000-4000-8000-000000000003'
    )
  ),
  'not_started'::text,
  'prepare does not start a replacement without version and agent inputs'
);

select is(
  (
    select status
    from public.chatbot_flow_runs
    where conversation_id = '55000000-0000-4000-8000-000000000001'
    order by created_at
    limit 1
  ),
  'expired'::text,
  'prepare expires an overdue waiting run'
);

select is(
  (
    select outcome
    from public.prepare_chatbot_flow_execution(
      '65000000-0000-4000-8000-000000000003',
      '85000000-0000-4000-8000-000000000001',
      '35000000-0000-4000-8000-000000000001'
    )
  ),
  'ready'::text,
  'prepare starts a replacement run when routing inputs are supplied'
);

select throws_ok(
  $$
    update public.chatbot_flow_runs
    set last_processed_message_id = '65000000-0000-4000-8000-000000000005'
    where conversation_id = '55000000-0000-4000-8000-000000000001'
      and status = 'running'
  $$,
  '23514',
  'last processed message must be incoming',
  'runs reject outgoing messages as processed input'
);

select throws_ok(
  $$
    select * from public.prepare_chatbot_flow_execution(
      '65000000-0000-4000-8000-000000000004',
      '85000000-0000-4000-8000-000000000001',
      '35000000-0000-4000-8000-000000000002'
    )
  $$,
  '23514',
  'chatbot execution requires an AI agent from the same organization',
  'prepare rejects a human agent'
);

select throws_ok(
  $$
    select * from public.prepare_chatbot_flow_execution(
      '65000000-0000-4000-8000-000000000004',
      '85000000-0000-4000-8000-000000000002',
      '35000000-0000-4000-8000-000000000001'
    )
  $$,
  '23514',
  'chatbot execution requires a published flow version from the same organization',
  'prepare rejects a draft version'
);

select throws_ok(
  $$
    select * from public.prepare_chatbot_flow_execution(
      '65000000-0000-4000-8000-000000000004',
      '85000000-0000-4000-8000-000000000001',
      '35000000-0000-4000-8000-000000000003'
    )
  $$,
  '23514',
  'chatbot execution requires an AI agent from the same organization',
  'prepare rejects an AI agent from another organization'
);

set local role authenticated;

select throws_like(
  $$
    select * from public.prepare_chatbot_flow_execution(
      '65000000-0000-4000-8000-000000000004'
    )
  $$,
  '%permission denied for function prepare_chatbot_flow_execution%',
  'browser roles cannot prepare runtime execution'
);

select throws_like(
  $$
    select * from public.commit_chatbot_flow_execution(
      '95000000-0000-4000-8000-000000000001',
      0,
      '65000000-0000-4000-8000-000000000004',
      'end',
      'completed',
      null,
      '{}',
      null,
      array[]::text[]
    )
  $$,
  '%permission denied for function commit_chatbot_flow_execution%',
  'browser roles cannot commit runtime execution'
);

select * from finish();

rollback;
