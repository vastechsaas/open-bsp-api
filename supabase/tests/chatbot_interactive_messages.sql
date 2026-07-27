begin;

create extension if not exists pgtap with schema extensions;

set local search_path = extensions, public, auth;

select plan(5);

insert into public.organizations (id, name, extra)
values ('16000000-0000-4000-8000-000000000001', 'Interactive Org', '{}');

insert into public.agents (id, organization_id, name, ai, extra)
values (
  '36000000-0000-4000-8000-000000000001',
  '16000000-0000-4000-8000-000000000001',
  'Interactive Bot',
  true,
  '{"mode":"active"}'
);

insert into public.organizations_addresses (
  organization_id,
  service,
  address,
  extra,
  status
) values (
  '16000000-0000-4000-8000-000000000001',
  'local',
  'interactive-org',
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
) values (
  '16000000-0000-4000-8000-000000000001',
  '56000000-0000-4000-8000-000000000001',
  'local',
  'interactive-org',
  'Interactive Conversation',
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
  status
) values
  (
    '16000000-0000-4000-8000-000000000001',
    '56000000-0000-4000-8000-000000000001',
    '66000000-0000-4000-8000-000000000001',
    'interactive-message-1',
    'incoming',
    'local',
    'interactive-org',
    '{"version":"1","type":"text","kind":"text","text":"hello"}',
    '{}'
  ),
  (
    '16000000-0000-4000-8000-000000000001',
    '56000000-0000-4000-8000-000000000001',
    '66000000-0000-4000-8000-000000000002',
    'interactive-message-2',
    'incoming',
    'local',
    'interactive-org',
    '{"version":"1","type":"text","kind":"text","text":"again"}',
    '{}'
  );

insert into public.chatbot_flows (organization_id, id, name)
values (
  '16000000-0000-4000-8000-000000000001',
  '76000000-0000-4000-8000-000000000001',
  'Interactive Flow'
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
) values (
  '16000000-0000-4000-8000-000000000001',
  '76000000-0000-4000-8000-000000000001',
  '86000000-0000-4000-8000-000000000001',
  1,
  'published',
  '{"nodes":[],"edges":[]}',
  '{"schema_version":1,"start_node_id":"buttons","nodes":[{"id":"buttons","type":"interactive_buttons","config":{"body":"Choose","buttons":[{"id":"support","title":"Support"}]}},{"id":"end","type":"end","config":{}}],"edges":[{"id":"support-edge","source":"buttons","target":"end","kind":"option","option_id":"support"}]}',
  now()
);

insert into public.chatbot_flow_runs (
  organization_id,
  conversation_id,
  id,
  flow_version_id,
  agent_id,
  current_node_id
) values (
  '16000000-0000-4000-8000-000000000001',
  '56000000-0000-4000-8000-000000000001',
  '96000000-0000-4000-8000-000000000001',
  '86000000-0000-4000-8000-000000000001',
  '36000000-0000-4000-8000-000000000001',
  'buttons'
);

select is(
  (
    select outcome
    from public.commit_chatbot_flow_execution(
      '96000000-0000-4000-8000-000000000001',
      0,
      '66000000-0000-4000-8000-000000000001',
      'buttons',
      'waiting',
      'button',
      '{}',
      null,
      array[]::text[],
      '[{"type":"interactive","interactive":{"type":"button","body":{"text":"Choose"},"action":{"buttons":[{"type":"reply","reply":{"id":"support","title":"Support"}}]}}}]'
    )
  ),
  'committed'::text,
  'interactive output commits atomically'
);

select is(
  (
    select waiting_for
    from public.chatbot_flow_runs
    where id = '96000000-0000-4000-8000-000000000001'
  ),
  'button'::text,
  'button wait state is persisted'
);

select is(
  (
    select content->>'kind'
    from public.messages
    where conversation_id = '56000000-0000-4000-8000-000000000001'
      and direction = 'outgoing'
  ),
  'interactive'::text,
  'interactive output uses the shared message content contract'
);

select is(
  (
    select content->'data'->'action'->'buttons'->0->'reply'->>'id'
    from public.messages
    where conversation_id = '56000000-0000-4000-8000-000000000001'
      and direction = 'outgoing'
  ),
  'support'::text,
  'stable reply IDs are preserved for WhatsApp dispatch'
);

select throws_ok(
  $$
    select * from public.commit_chatbot_flow_execution(
      '96000000-0000-4000-8000-000000000001',
      1,
      '66000000-0000-4000-8000-000000000002',
      'buttons',
      'waiting',
      'button',
      '{}',
      null,
      array[]::text[],
      '{"type":"interactive"}'
    )
  $$,
  '23514',
  'outgoing chatbot messages must be a JSON array',
  'invalid structured output is rejected'
);

select * from finish();

rollback;
