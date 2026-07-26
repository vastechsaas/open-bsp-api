begin;

create extension if not exists pgtap with schema extensions;

set local search_path = extensions, public, auth;

select plan(15);

insert into public.organizations (id, name, extra)
values
  (
    '15000000-0000-4000-8000-000000000001',
    'Chatbot Management Org A',
    '{}'
  ),
  (
    '15000000-0000-4000-8000-000000000002',
    'Chatbot Management Org B',
    '{}'
  );

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
values (
  '00000000-0000-0000-0000-000000000000',
  '25000000-0000-4000-8000-000000000001',
  'authenticated',
  'authenticated',
  'chatbot-management-admin@example.test',
  crypt('password', gen_salt('bf')),
  '{"provider":"email","providers":["email"]}',
  '{"name":"Chatbot Management Admin"}',
  now(),
  now(),
  now(),
  '',
  '',
  '',
  ''
);

insert into public.agents (id, organization_id, user_id, name, ai, extra)
values (
  '35000000-0000-4000-8000-000000000001',
  '15000000-0000-4000-8000-000000000001',
  '25000000-0000-4000-8000-000000000001',
  'Chatbot Management Admin',
  false,
  '{"role":"admin"}'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.create_chatbot_flow_draft(uuid,text,uuid)',
    'execute'
  ),
  'authenticated clients cannot call the atomic create RPC directly'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.duplicate_chatbot_flow_draft(uuid,uuid,text,uuid)',
    'execute'
  ),
  'authenticated clients cannot call the atomic duplicate RPC directly'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.publish_chatbot_flow_draft(uuid,uuid,uuid,timestamptz,jsonb,uuid)',
    'execute'
  ),
  'authenticated clients cannot call the publish RPC directly'
);

set local role service_role;
set local search_path = extensions, public, auth;

select lives_ok(
  $$
    select *
    from public.create_chatbot_flow_draft(
      '15000000-0000-4000-8000-000000000001',
      '  Support Assistant  ',
      '35000000-0000-4000-8000-000000000001'
    )
  $$,
  'the management service can atomically create a flow and draft'
);

select is(
  (
    select count(*)::integer
    from public.chatbot_flows
    where organization_id = '15000000-0000-4000-8000-000000000001'
      and name = 'Support Assistant'
  ),
  1,
  'create trims and persists the flow name'
);

select is(
  (
    select count(*)::integer
    from public.chatbot_flow_versions as version
    join public.chatbot_flows as flow on flow.id = version.flow_id
    where flow.name = 'Support Assistant'
      and version.status = 'draft'
      and version.version = 1
  ),
  1,
  'create produces exactly one initial draft'
);

update public.chatbot_flow_versions as version
set editor_graph = '{
  "nodes": [
    {"id":"start","type":"chatbotNode","data":{"node_type":"start","config":{}}},
    {"id":"end","type":"chatbotNode","data":{"node_type":"end","config":{}}}
  ],
  "edges": [
    {"id":"start-end","source":"start","target":"end","data":{"kind":"default"}}
  ]
}'::jsonb
from public.chatbot_flows as flow
where flow.id = version.flow_id
  and flow.name = 'Support Assistant'
  and version.status = 'draft';

select lives_ok(
  $$
    select *
    from public.duplicate_chatbot_flow_draft(
      '15000000-0000-4000-8000-000000000001',
      (
        select id
        from public.chatbot_flows
        where name = 'Support Assistant'
      ),
      'Support Assistant Copy',
      '35000000-0000-4000-8000-000000000001'
    )
  $$,
  'the management service can duplicate a flow'
);

select is(
  (
    select copy_version.editor_graph
    from public.chatbot_flow_versions as copy_version
    join public.chatbot_flows as copy_flow
      on copy_flow.id = copy_version.flow_id
    where copy_flow.name = 'Support Assistant Copy'
  ),
  (
    select source_version.editor_graph
    from public.chatbot_flow_versions as source_version
    join public.chatbot_flows as source_flow
      on source_flow.id = source_version.flow_id
    where source_flow.name = 'Support Assistant'
  ),
  'duplicate copies the source editor graph into a new draft'
);

create temporary table captured_chatbot_draft as
select
  version.id,
  version.flow_id,
  version.updated_at - interval '1 second' as updated_at
from public.chatbot_flow_versions as version
join public.chatbot_flows as flow on flow.id = version.flow_id
where flow.name = 'Support Assistant'
  and version.status = 'draft';

update public.chatbot_flow_versions
set editor_graph = editor_graph || '{"viewport":{"x":0,"y":0,"zoom":1}}'::jsonb
where id = (select id from captured_chatbot_draft);

select is(
  (
    select outcome
    from public.publish_chatbot_flow_draft(
      '15000000-0000-4000-8000-000000000001',
      (select flow_id from captured_chatbot_draft),
      (select id from captured_chatbot_draft),
      (select updated_at from captured_chatbot_draft),
      '{
        "schema_version":1,
        "start_node_id":"start",
        "nodes":[
          {"id":"start","type":"start","config":{}},
          {"id":"end","type":"end","config":{}}
        ],
        "edges":[
          {"id":"start-end","source":"start","target":"end","kind":"default"}
        ]
      }'::jsonb,
      '35000000-0000-4000-8000-000000000001'
    )
  ),
  'conflict',
  'publish rejects a stale draft timestamp'
);

select is(
  (
    select outcome
    from public.publish_chatbot_flow_draft(
      '15000000-0000-4000-8000-000000000001',
      (select flow_id from captured_chatbot_draft),
      (select id from captured_chatbot_draft),
      (
        select updated_at
        from public.chatbot_flow_versions
        where id = (select id from captured_chatbot_draft)
      ),
      '{
        "schema_version":1,
        "start_node_id":"start",
        "nodes":[
          {"id":"start","type":"start","config":{}},
          {"id":"end","type":"end","config":{}}
        ],
        "edges":[
          {"id":"start-end","source":"start","target":"end","kind":"default"}
        ]
      }'::jsonb,
      '35000000-0000-4000-8000-000000000001'
    )
  ),
  'published',
  'publish atomically promotes the current draft'
);

select is(
  (
    select count(*)::integer
    from public.chatbot_flow_versions
    where flow_id = (select flow_id from captured_chatbot_draft)
      and status = 'published'
      and version = 1
      and definition is not null
  ),
  1,
  'publish stores one immutable executable version'
);

select is(
  (
    select count(*)::integer
    from public.chatbot_flow_versions
    where flow_id = (select flow_id from captured_chatbot_draft)
      and status = 'draft'
      and version = 2
  ),
  1,
  'publish creates the next editable draft'
);

select throws_like(
  $$
    update public.chatbot_flow_versions
    set editor_graph = '{"nodes":[],"edges":[]}'
    where id = (select id from captured_chatbot_draft)
  $$,
  '%published chatbot flow versions are immutable%',
  'published versions remain immutable'
);

reset role;
select set_config(
  'request.jwt.claim.sub',
  '25000000-0000-4000-8000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth;

select throws_like(
  $$
    update public.chatbot_flow_versions
    set
      status = 'published',
      published_at = now(),
      definition = '{
        "schema_version":1,
        "start_node_id":"start",
        "nodes":[],
        "edges":[]
      }'::jsonb
    where flow_id = (
      select id
      from public.chatbot_flows
      where name = 'Support Assistant Copy'
    )
      and status = 'draft'
  $$,
  '%row-level security policy%',
  'browser clients cannot bypass management to publish a draft'
);

select is(
  (
    select count(*)::integer
    from public.chatbot_flow_versions
    where status = 'draft'
  ),
  2,
  'failed direct publishing leaves drafts unchanged'
);

select * from finish();

rollback;
