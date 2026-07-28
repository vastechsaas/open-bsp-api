begin;

create extension if not exists pgtap with schema extensions;

set local search_path = extensions, public, auth;

select plan(7);

insert into public.organizations (id, name, extra)
values
  ('16000000-0000-4000-8000-000000000001', 'Handoff Org A', '{}'),
  ('16000000-0000-4000-8000-000000000002', 'Handoff Org B', '{}');

insert into auth.users (
  instance_id,
  id,
  aud,
  role,
  email,
  encrypted_password,
  raw_app_meta_data,
  raw_user_meta_data,
  email_confirmed_at,
  created_at,
  updated_at,
  confirmation_token,
  recovery_token,
  email_change_token_new,
  email_change
)
values
  (
    '00000000-0000-0000-0000-000000000000',
    '26000000-0000-4000-8000-000000000001',
    'authenticated',
    'authenticated',
    'handoff-a@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Handoff Agent A"}',
    now(),
    now(),
    now(),
    '',
    '',
    '',
    ''
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '26000000-0000-4000-8000-000000000002',
    'authenticated',
    'authenticated',
    'handoff-pending@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Pending Agent"}',
    now(),
    now(),
    now(),
    '',
    '',
    '',
    ''
  );

insert into public.agents (
  id,
  organization_id,
  user_id,
  name,
  ai,
  extra
)
values
  (
    '36000000-0000-4000-8000-000000000001',
    '16000000-0000-4000-8000-000000000001',
    null,
    'Handoff Runtime',
    true,
    '{"mode":"active","kind":"chatbot_runtime"}'
  ),
  (
    '36000000-0000-4000-8000-000000000002',
    '16000000-0000-4000-8000-000000000001',
    '26000000-0000-4000-8000-000000000001',
    'Human Agent A',
    false,
    '{"role":"member"}'
  ),
  (
    '36000000-0000-4000-8000-000000000003',
    '16000000-0000-4000-8000-000000000001',
    '26000000-0000-4000-8000-000000000002',
    'Pending Agent',
    false,
    '{"role":"member","invitation":{"organization_name":"Handoff Org A","email":"handoff-pending@example.test","status":"pending"}}'
  );

insert into public.organizations_addresses (
  organization_id,
  service,
  address,
  extra,
  status
)
values (
  '16000000-0000-4000-8000-000000000001',
  'local',
  'handoff-org-a',
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
    '16000000-0000-4000-8000-000000000001',
    '56000000-0000-4000-8000-000000000001',
    'local',
    'handoff-org-a',
    'Handoff Conversation',
    '{}'
  ),
  (
    '16000000-0000-4000-8000-000000000001',
    '56000000-0000-4000-8000-000000000002',
    'local',
    'handoff-org-a',
    'Invalid Handoff Conversation',
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
    '16000000-0000-4000-8000-000000000001',
    '56000000-0000-4000-8000-000000000001',
    '66000000-0000-4000-8000-000000000001',
    'handoff-message-1',
    'incoming',
    'local',
    'handoff-org-a',
    '{"version":"1","type":"text","kind":"text","text":"human"}',
    '{}',
    now() - interval '1 minute'
  ),
  (
    '16000000-0000-4000-8000-000000000001',
    '56000000-0000-4000-8000-000000000001',
    '66000000-0000-4000-8000-000000000002',
    'handoff-message-2',
    'incoming',
    'local',
    'handoff-org-a',
    '{"version":"1","type":"text","kind":"text","text":"still there"}',
    '{}',
    now()
  ),
  (
    '16000000-0000-4000-8000-000000000001',
    '56000000-0000-4000-8000-000000000002',
    '66000000-0000-4000-8000-000000000003',
    'handoff-message-3',
    'incoming',
    'local',
    'handoff-org-a',
    '{"version":"1","type":"text","kind":"text","text":"pending"}',
    '{}',
    now()
  );

insert into public.chatbot_flows (organization_id, id, name)
values (
  '16000000-0000-4000-8000-000000000001',
  '76000000-0000-4000-8000-000000000001',
  'Handoff Flow'
);

insert into public.chatbot_flow_versions (
  organization_id,
  flow_id,
  id,
  version,
  status,
  definition,
  published_at
)
values (
  '16000000-0000-4000-8000-000000000001',
  '76000000-0000-4000-8000-000000000001',
  '86000000-0000-4000-8000-000000000001',
  1,
  'published',
  '{"schema_version":1,"start_node_id":"handoff","nodes":[{"id":"handoff","type":"assign_agent","config":{"agent_id":"36000000-0000-4000-8000-000000000002"}}],"edges":[]}',
  now()
);

insert into public.chatbot_flow_runs (
  organization_id,
  conversation_id,
  flow_version_id,
  agent_id,
  id,
  current_node_id
)
values
  (
    '16000000-0000-4000-8000-000000000001',
    '56000000-0000-4000-8000-000000000001',
    '86000000-0000-4000-8000-000000000001',
    '36000000-0000-4000-8000-000000000001',
    '96000000-0000-4000-8000-000000000001',
    'handoff'
  ),
  (
    '16000000-0000-4000-8000-000000000001',
    '56000000-0000-4000-8000-000000000002',
    '86000000-0000-4000-8000-000000000001',
    '36000000-0000-4000-8000-000000000001',
    '96000000-0000-4000-8000-000000000002',
    'handoff'
  );

select is(
  (
    select outcome
    from public.commit_chatbot_flow_execution(
      p_run_id => '96000000-0000-4000-8000-000000000001',
      p_expected_lock_version => 0,
      p_message_id => '66000000-0000-4000-8000-000000000001',
      p_current_node_id => 'handoff',
      p_status => 'handed_off',
      p_waiting_for => null,
      p_variables => '{}',
      p_error => null,
      p_outgoing_texts => array[]::text[],
      p_handoff_agent_id => '36000000-0000-4000-8000-000000000002'
    )
  ),
  'committed',
  'handoff commit succeeds'
);

select is(
  (
    select assigned_agent_id
    from public.conversations
    where id = '56000000-0000-4000-8000-000000000001'
  ),
  '36000000-0000-4000-8000-000000000002'::uuid,
  'handoff assigns the conversation atomically'
);

select results_eq(
  $$
    select status, waiting_for, ended_at is not null
    from public.chatbot_flow_runs
    where id = '96000000-0000-4000-8000-000000000001'
  $$,
  $$ values ('handed_off'::text, null::text, true) $$,
  'handoff ends automation on the run'
);

select is(
  (
    select outcome
    from public.commit_chatbot_flow_execution(
      p_run_id => '96000000-0000-4000-8000-000000000001',
      p_expected_lock_version => 0,
      p_message_id => '66000000-0000-4000-8000-000000000001',
      p_current_node_id => 'handoff',
      p_status => 'handed_off',
      p_waiting_for => null,
      p_variables => '{}',
      p_error => null,
      p_outgoing_texts => array[]::text[],
      p_handoff_agent_id => '36000000-0000-4000-8000-000000000002'
    )
  ),
  'conflict',
  'handoff is committed exactly once'
);

select is(
  (
    select outcome
    from public.prepare_chatbot_flow_execution(
      '66000000-0000-4000-8000-000000000002',
      '86000000-0000-4000-8000-000000000001',
      '36000000-0000-4000-8000-000000000001'
    )
  ),
  'not_started',
  'assigned conversations bypass chatbot automation'
);

select throws_ok(
  $$
    select *
    from public.commit_chatbot_flow_execution(
      p_run_id => '96000000-0000-4000-8000-000000000002',
      p_expected_lock_version => 0,
      p_message_id => '66000000-0000-4000-8000-000000000003',
      p_current_node_id => 'handoff',
      p_status => 'handed_off',
      p_waiting_for => null,
      p_variables => '{}',
      p_error => null,
      p_outgoing_texts => array[]::text[],
      p_handoff_agent_id => '36000000-0000-4000-8000-000000000003'
    )
  $$,
  '23514',
  'chatbot handoff requires an active human agent from the same organization',
  'pending human agents cannot receive handoffs'
);

select is(
  (
    select assigned_agent_id
    from public.conversations
    where id = '56000000-0000-4000-8000-000000000002'
  ),
  null::uuid,
  'failed handoff leaves the conversation unchanged'
);

select * from finish();

rollback;
