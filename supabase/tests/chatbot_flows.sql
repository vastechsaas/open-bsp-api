begin;

create extension if not exists pgtap with schema extensions;

set local search_path = extensions, public, auth;

select plan(27);

insert into public.organizations (id, name, extra)
values
  (
    '14000000-0000-4000-8000-000000000001',
    'Chatbot Test Org A',
    '{}'
  ),
  (
    '14000000-0000-4000-8000-000000000002',
    'Chatbot Test Org B',
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
values
  (
    '00000000-0000-0000-0000-000000000000',
    '24000000-0000-4000-8000-000000000001',
    'authenticated',
    'authenticated',
    'chatbot-admin-a@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Chatbot Admin A"}',
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
    '24000000-0000-4000-8000-000000000002',
    'authenticated',
    'authenticated',
    'chatbot-admin-b@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Chatbot Admin B"}',
    now(),
    now(),
    now(),
    '',
    '',
    '',
    ''
  );

insert into public.agents (id, organization_id, user_id, name, ai, extra)
values
  (
    '34000000-0000-4000-8000-000000000001',
    '14000000-0000-4000-8000-000000000001',
    '24000000-0000-4000-8000-000000000001',
    'Chatbot Admin A',
    false,
    '{"role":"admin"}'
  ),
  (
    '34000000-0000-4000-8000-000000000002',
    '14000000-0000-4000-8000-000000000002',
    '24000000-0000-4000-8000-000000000002',
    'Chatbot Admin B',
    false,
    '{"role":"admin"}'
  ),
  (
    '34000000-0000-4000-8000-000000000101',
    '14000000-0000-4000-8000-000000000001',
    null,
    'Chatbot Runtime A',
    true,
    '{"mode":"active"}'
  ),
  (
    '34000000-0000-4000-8000-000000000102',
    '14000000-0000-4000-8000-000000000002',
    null,
    'Chatbot Runtime B',
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
    '14000000-0000-4000-8000-000000000001',
    'whatsapp',
    'chatbot-org-a-address',
    '{}',
    'connected'
  ),
  (
    '14000000-0000-4000-8000-000000000002',
    'whatsapp',
    'chatbot-org-b-address',
    '{}',
    'connected'
  );

insert into public.contacts (id, organization_id, name, status)
values
  (
    '44000000-0000-4000-8000-000000000001',
    '14000000-0000-4000-8000-000000000001',
    'Chatbot Contact A',
    'active'
  ),
  (
    '44000000-0000-4000-8000-000000000002',
    '14000000-0000-4000-8000-000000000002',
    'Chatbot Contact B',
    'active'
  );

insert into public.contacts_addresses (
  organization_id,
  contact_id,
  service,
  address,
  extra,
  status
)
values
  (
    '14000000-0000-4000-8000-000000000001',
    '44000000-0000-4000-8000-000000000001',
    'whatsapp',
    '15551400001',
    '{}',
    'active'
  ),
  (
    '14000000-0000-4000-8000-000000000002',
    '44000000-0000-4000-8000-000000000002',
    'whatsapp',
    '15551400002',
    '{}',
    'active'
  );

insert into public.conversations (
  organization_id,
  id,
  service,
  organization_address,
  contact_address,
  name,
  extra
)
values
  (
    '14000000-0000-4000-8000-000000000001',
    '54000000-0000-4000-8000-000000000001',
    'whatsapp',
    'chatbot-org-a-address',
    '15551400001',
    'Chatbot Conversation A',
    '{}'
  ),
  (
    '14000000-0000-4000-8000-000000000002',
    '54000000-0000-4000-8000-000000000002',
    'whatsapp',
    'chatbot-org-b-address',
    '15551400002',
    'Chatbot Conversation B',
    '{}'
  );

insert into public.messages (
  organization_id,
  conversation_id,
  id,
  external_id,
  direction,
  contact_address,
  service,
  organization_address,
  content,
  status
)
values
  (
    '14000000-0000-4000-8000-000000000001',
    '54000000-0000-4000-8000-000000000001',
    '64000000-0000-4000-8000-000000000001',
    'chatbot-message-a',
    'incoming',
    '15551400001',
    'whatsapp',
    'chatbot-org-a-address',
    '{"version":"1","type":"text","kind":"text","text":"12345"}',
    '{}'
  ),
  (
    '14000000-0000-4000-8000-000000000002',
    '54000000-0000-4000-8000-000000000002',
    '64000000-0000-4000-8000-000000000002',
    'chatbot-message-b',
    'incoming',
    '15551400002',
    'whatsapp',
    'chatbot-org-b-address',
    '{"version":"1","type":"text","kind":"text","text":"hello"}',
    '{}'
  );

insert into public.chatbot_flows (
  organization_id,
  id,
  created_by,
  name
)
values
  (
    '14000000-0000-4000-8000-000000000001',
    '74000000-0000-4000-8000-000000000001',
    '34000000-0000-4000-8000-000000000001',
    'Order Status'
  ),
  (
    '14000000-0000-4000-8000-000000000002',
    '74000000-0000-4000-8000-000000000002',
    '34000000-0000-4000-8000-000000000002',
    'Support Router'
  );

insert into public.chatbot_flow_versions (
  organization_id,
  flow_id,
  id,
  created_by,
  version,
  status,
  editor_graph,
  definition,
  published_at
)
values
  (
    '14000000-0000-4000-8000-000000000001',
    '74000000-0000-4000-8000-000000000001',
    '84000000-0000-4000-8000-000000000001',
    '34000000-0000-4000-8000-000000000001',
    1,
    'published',
    '{"nodes":[{"id":"start"}],"edges":[]}',
    '{"schema_version":1,"start_node_id":"start","nodes":[{"id":"start","type":"start"}],"edges":[]}',
    now()
  ),
  (
    '14000000-0000-4000-8000-000000000001',
    '74000000-0000-4000-8000-000000000001',
    '84000000-0000-4000-8000-000000000002',
    '34000000-0000-4000-8000-000000000001',
    2,
    'draft',
    '{"nodes":[{"id":"start"},{"id":"ask_order"}],"edges":[{"source":"start","target":"ask_order"}]}',
    null,
    null
  ),
  (
    '14000000-0000-4000-8000-000000000002',
    '74000000-0000-4000-8000-000000000002',
    '84000000-0000-4000-8000-000000000003',
    '34000000-0000-4000-8000-000000000002',
    1,
    'published',
    '{"nodes":[{"id":"start"}],"edges":[]}',
    '{"schema_version":1,"start_node_id":"start","nodes":[{"id":"start","type":"start"}],"edges":[]}',
    now()
  );

insert into public.chatbot_flow_runs (
  organization_id,
  conversation_id,
  flow_version_id,
  agent_id,
  id,
  current_node_id,
  status,
  waiting_for,
  variables,
  last_processed_message_id,
  expires_at
)
values
  (
    '14000000-0000-4000-8000-000000000001',
    '54000000-0000-4000-8000-000000000001',
    '84000000-0000-4000-8000-000000000001',
    '34000000-0000-4000-8000-000000000101',
    '94000000-0000-4000-8000-000000000001',
    'ask_order',
    'waiting',
    'free_text',
    '{"customer_name":"Ali"}',
    '64000000-0000-4000-8000-000000000001',
    now() + interval '24 hours'
  ),
  (
    '14000000-0000-4000-8000-000000000002',
    '54000000-0000-4000-8000-000000000002',
    '84000000-0000-4000-8000-000000000003',
    '34000000-0000-4000-8000-000000000102',
    '94000000-0000-4000-8000-000000000002',
    'start',
    'running',
    null,
    '{}',
    '64000000-0000-4000-8000-000000000002',
    now() + interval '24 hours'
  );

select is(
  (
    select name
    from public.chatbot_flows
    where id = '74000000-0000-4000-8000-000000000001'
  ),
  'Order Status'::text,
  'a chatbot flow stores its stable identity and name'
);

select is(
  (
    select jsonb_array_length(editor_graph->'nodes')
    from public.chatbot_flow_versions
    where id = '84000000-0000-4000-8000-000000000002'
  ),
  2,
  'a draft version stores the complete editor graph'
);

select throws_like(
  $$
    insert into public.chatbot_flows (organization_id, name)
    values ('14000000-0000-4000-8000-000000000001', '   ')
  $$,
  '%chatbot_flows_name_check%',
  'flow names cannot be blank'
);

select throws_like(
  $$
    insert into public.chatbot_flows (organization_id, name)
    values ('14000000-0000-4000-8000-000000000001', ' order status ')
  $$,
  '%chatbot_flows_organization_name_key%',
  'flow names are unique per organization after trimming and case folding'
);

select throws_like(
  $$
    insert into public.chatbot_flow_versions (
      organization_id,
      flow_id,
      version,
      editor_graph
    ) values (
      '14000000-0000-4000-8000-000000000002',
      '74000000-0000-4000-8000-000000000002',
      2,
      '{"nodes":[]}'
    )
  $$,
  '%chatbot_flow_versions_editor_graph_check%',
  'editor graphs require node and edge arrays'
);

select throws_like(
  $$
    update public.chatbot_flow_versions
    set definition = '{"schema_version":1,"nodes":[],"edges":[]}'
    where id = '84000000-0000-4000-8000-000000000002'
  $$,
  '%chatbot_flow_versions_definition_check%',
  'executable definitions require a start node identifier'
);

select throws_like(
  $$
    insert into public.chatbot_flow_versions (
      organization_id,
      flow_id,
      version
    ) values (
      '14000000-0000-4000-8000-000000000001',
      '74000000-0000-4000-8000-000000000001',
      3
    )
  $$,
  '%chatbot_flow_versions_one_draft_per_flow_idx%',
  'a flow can have only one editable draft'
);

select throws_like(
  $$
    insert into public.chatbot_flow_versions (
      organization_id,
      flow_id,
      version,
      status,
      published_at
    ) values (
      '14000000-0000-4000-8000-000000000002',
      '74000000-0000-4000-8000-000000000002',
      2,
      'published',
      now()
    )
  $$,
  '%chatbot_flow_versions_published_state_check%',
  'published versions require an executable definition'
);

select throws_ok(
  $$
    update public.chatbot_flow_versions
    set editor_graph = '{"nodes":[],"edges":[]}'
    where id = '84000000-0000-4000-8000-000000000001'
  $$,
  '23514',
  'published chatbot flow versions are immutable',
  'published flow versions cannot be modified'
);

select is(
  (
    select status || ':' || waiting_for
    from public.chatbot_flow_runs
    where id = '94000000-0000-4000-8000-000000000001'
  ),
  'waiting:free_text'::text,
  'a run records what input the conversation is waiting for'
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
      '14000000-0000-4000-8000-000000000001',
      '54000000-0000-4000-8000-000000000001',
      '84000000-0000-4000-8000-000000000002',
      '34000000-0000-4000-8000-000000000101',
      'start'
    )
  $$,
  '23514',
  'chatbot flow runs require a published flow version',
  'runs cannot start from a draft version'
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
      '14000000-0000-4000-8000-000000000001',
      '54000000-0000-4000-8000-000000000002',
      '84000000-0000-4000-8000-000000000001',
      '34000000-0000-4000-8000-000000000101',
      'start'
    )
  $$,
  '23514',
  'chatbot flow run conversation must belong to the same organization',
  'runs cannot attach a conversation from another organization'
);

select throws_ok(
  $$
    update public.chatbot_flow_runs
    set last_processed_message_id = '64000000-0000-4000-8000-000000000002'
    where id = '94000000-0000-4000-8000-000000000001'
  $$,
  '23514',
  'last processed message must belong to the chatbot flow run conversation',
  'a run cannot claim a message from another conversation'
);

select throws_like(
  $$
    insert into public.chatbot_flow_runs (
      organization_id,
      conversation_id,
      flow_version_id,
      agent_id,
      current_node_id
    ) values (
      '14000000-0000-4000-8000-000000000001',
      '54000000-0000-4000-8000-000000000001',
      '84000000-0000-4000-8000-000000000001',
      '34000000-0000-4000-8000-000000000101',
      'start'
    )
  $$,
  '%chatbot_flow_runs_one_active_per_conversation_idx%',
  'a conversation can have only one active flow run'
);

select throws_like(
  $$
    update public.chatbot_flow_runs
    set variables = '[]'
    where id = '94000000-0000-4000-8000-000000000001'
  $$,
  '%chatbot_flow_runs_variables_check%',
  'run variables must be a JSON object'
);

select throws_like(
  $$
    update public.chatbot_flow_runs
    set waiting_for = null
    where id = '94000000-0000-4000-8000-000000000001'
  $$,
  '%chatbot_flow_runs_waiting_for_check%',
  'waiting runs must identify the expected customer input'
);

select throws_like(
  $$
    update public.chatbot_flow_runs
    set status = 'completed', waiting_for = null
    where id = '94000000-0000-4000-8000-000000000001'
  $$,
  '%chatbot_flow_runs_ended_at_check%',
  'terminal runs require an end timestamp'
);

select lives_ok(
  $$
    update public.chatbot_flow_runs
    set status = 'completed', waiting_for = null, ended_at = now()
    where id = '94000000-0000-4000-8000-000000000001'
  $$,
  'a waiting run can be completed with an end timestamp'
);

select throws_ok(
  $$
    update public.chatbot_flow_runs
    set conversation_id = '54000000-0000-4000-8000-000000000002'
    where id = '94000000-0000-4000-8000-000000000001'
  $$,
  '23514',
  'chatbot flow run identity is immutable',
  'a run remains pinned to its original conversation and flow version'
);

select set_config(
  'request.jwt.claim.sub',
  '24000000-0000-4000-8000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth;

select is(
  (select count(*)::integer from public.chatbot_flows),
  1,
  'flow RLS hides flows from other organizations'
);

select is(
  (select count(*)::integer from public.chatbot_flow_versions),
  2,
  'flow version RLS hides versions from other organizations'
);

select is(
  (select count(*)::integer from public.chatbot_flow_runs),
  1,
  'flow run RLS hides conversation state from other organizations'
);

select lives_ok(
  $$
    insert into public.chatbot_flows (
      organization_id,
      created_by,
      name
    ) values (
      '14000000-0000-4000-8000-000000000001',
      '34000000-0000-4000-8000-000000000001',
      'Returns Assistant'
    )
  $$,
  'an organization admin can create a chatbot flow'
);

select throws_like(
  $$
    insert into public.chatbot_flows (organization_id, name)
    values (
      '14000000-0000-4000-8000-000000000002',
      'Unauthorized Flow'
    )
  $$,
  '%row-level security policy%',
  'an admin cannot create a flow for another organization'
);

select throws_like(
  $$
    insert into public.chatbot_flow_runs (
      organization_id,
      conversation_id,
      flow_version_id,
      agent_id,
      current_node_id
    ) values (
      '14000000-0000-4000-8000-000000000001',
      '54000000-0000-4000-8000-000000000001',
      '84000000-0000-4000-8000-000000000001',
      '34000000-0000-4000-8000-000000000101',
      'start'
    )
  $$,
  '%row-level security policy%',
  'browser clients cannot create runtime-owned flow runs'
);

select is_empty(
  $$
    update public.chatbot_flow_versions
    set editor_graph = '{"nodes":[],"edges":[]}'
    where id = '84000000-0000-4000-8000-000000000001'
    returning 1
  $$,
  'admins cannot modify a published flow version'
);

select is_empty(
  $$
    delete from public.chatbot_flows
    where id = '74000000-0000-4000-8000-000000000001'
    returning 1
  $$,
  'admins archive flows with published history instead of deleting them'
);

select * from finish();

rollback;
