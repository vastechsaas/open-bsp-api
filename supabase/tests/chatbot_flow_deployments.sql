begin;

create extension if not exists pgtap with schema extensions;

set local search_path = extensions, public, auth;

select plan(15);

insert into public.organizations (id, name, extra)
values
  ('16000000-0000-4000-8000-000000000001', 'Deployment Org A', '{}'),
  ('16000000-0000-4000-8000-000000000002', 'Deployment Org B', '{}');

insert into public.agents (id, organization_id, name, ai, extra)
values
  (
    '36000000-0000-4000-8000-000000000001',
    '16000000-0000-4000-8000-000000000001',
    'Chatbot Runtime',
    true,
    '{"kind":"chatbot_runtime","mode":"active","system":true}'
  ),
  (
    '36000000-0000-4000-8000-000000000002',
    '16000000-0000-4000-8000-000000000001',
    'Deployment Admin A',
    false,
    '{"role":"admin"}'
  ),
  (
    '36000000-0000-4000-8000-000000000003',
    '16000000-0000-4000-8000-000000000001',
    'Inactive Deployment Bot A',
    true,
    '{"mode":"inactive"}'
  ),
  (
    '36000000-0000-4000-8000-000000000004',
    '16000000-0000-4000-8000-000000000002',
    'Deployment Bot B',
    true,
    '{"mode":"active"}'
  ),
  (
    '36000000-0000-4000-8000-000000000005',
    '16000000-0000-4000-8000-000000000001',
    'Regular AI Agent A',
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
    '16000000-0000-4000-8000-000000000001',
    'whatsapp',
    'deployment-whatsapp-connected',
    '{}',
    'connected'
  ),
  (
    '16000000-0000-4000-8000-000000000001',
    'whatsapp',
    'deployment-whatsapp-disconnected',
    '{}',
    'disconnected'
  ),
  (
    '16000000-0000-4000-8000-000000000001',
    'local',
    'deployment-local',
    '{}',
    'connected'
  );

insert into public.chatbot_flows (organization_id, id, name, status, archived_at)
values
  (
    '16000000-0000-4000-8000-000000000001',
    '76000000-0000-4000-8000-000000000001',
    'Deployment Flow A',
    'active',
    null
  ),
  (
    '16000000-0000-4000-8000-000000000001',
    '76000000-0000-4000-8000-000000000002',
    'Archived Deployment Flow A',
    'archived',
    now()
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
    '16000000-0000-4000-8000-000000000001',
    '76000000-0000-4000-8000-000000000001',
    '86000000-0000-4000-8000-000000000001',
    1,
    'published',
    '{"nodes":[],"edges":[]}',
    '{"schema_version":1,"start_node_id":"start","nodes":[{"id":"start","type":"start","config":{}},{"id":"end","type":"end","config":{}}],"edges":[{"id":"edge-1","source":"start","target":"end","kind":"default"}]}',
    now()
  ),
  (
    '16000000-0000-4000-8000-000000000001',
    '76000000-0000-4000-8000-000000000001',
    '86000000-0000-4000-8000-000000000002',
    2,
    'published',
    '{"nodes":[],"edges":[]}',
    '{"schema_version":1,"start_node_id":"start","nodes":[{"id":"start","type":"start","config":{}},{"id":"end","type":"end","config":{}}],"edges":[{"id":"edge-2","source":"start","target":"end","kind":"default"}]}',
    now()
  ),
  (
    '16000000-0000-4000-8000-000000000001',
    '76000000-0000-4000-8000-000000000001',
    '86000000-0000-4000-8000-000000000003',
    3,
    'draft',
    '{"nodes":[],"edges":[]}',
    null,
    null
  ),
  (
    '16000000-0000-4000-8000-000000000001',
    '76000000-0000-4000-8000-000000000002',
    '86000000-0000-4000-8000-000000000004',
    1,
    'published',
    '{"nodes":[],"edges":[]}',
    '{"schema_version":1,"start_node_id":"start","nodes":[{"id":"start","type":"start","config":{}},{"id":"end","type":"end","config":{}}],"edges":[{"id":"edge-4","source":"start","target":"end","kind":"default"}]}',
    now()
  );

insert into public.chatbot_flow_deployments (
  organization_id,
  organization_address,
  flow_id,
  flow_version_id,
  agent_id,
  activated_by
)
values (
  '16000000-0000-4000-8000-000000000001',
  'deployment-whatsapp-connected',
  '76000000-0000-4000-8000-000000000001',
  '86000000-0000-4000-8000-000000000001',
  '36000000-0000-4000-8000-000000000001',
  '36000000-0000-4000-8000-000000000002'
);

select ok(
  exists (
    select 1
    from public.chatbot_flow_deployments
    where organization_address = 'deployment-whatsapp-connected'
      and flow_version_id = '86000000-0000-4000-8000-000000000001'
  ),
  'a published flow can be deployed to a connected WhatsApp address'
);

select is(
  public.ensure_chatbot_runtime_agent(
    '16000000-0000-4000-8000-000000000001'
  ),
  '36000000-0000-4000-8000-000000000001'::uuid,
  'the existing organization runtime identity is reused'
);

select is(
  public.ensure_chatbot_runtime_agent(
    '16000000-0000-4000-8000-000000000002'
  ),
  public.ensure_chatbot_runtime_agent(
    '16000000-0000-4000-8000-000000000002'
  ),
  'runtime identity creation is idempotent'
);

select is(
  (
    select count(*)
    from public.agents
    where organization_id = '16000000-0000-4000-8000-000000000002'
      and ai = true
      and extra->>'kind' = 'chatbot_runtime'
  ),
  1::bigint,
  'an organization has exactly one chatbot runtime identity'
);

select throws_ok(
  $$
    insert into public.chatbot_flow_deployments
    values (
      '16000000-0000-4000-8000-000000000001',
      'deployment-whatsapp-disconnected',
      '76000000-0000-4000-8000-000000000001',
      '86000000-0000-4000-8000-000000000001',
      '36000000-0000-4000-8000-000000000001',
      null,
      now(),
      now()
    )
  $$,
  '23514',
  'chatbot deployments require a connected WhatsApp address',
  'a disconnected WhatsApp address is rejected'
);

select throws_ok(
  $$
    insert into public.chatbot_flow_deployments
    values (
      '16000000-0000-4000-8000-000000000001',
      'deployment-local',
      '76000000-0000-4000-8000-000000000001',
      '86000000-0000-4000-8000-000000000001',
      '36000000-0000-4000-8000-000000000001',
      null,
      now(),
      now()
    )
  $$,
  '23514',
  'chatbot deployments require a connected WhatsApp address',
  'a non-WhatsApp address is rejected'
);

select throws_ok(
  $$
    update public.chatbot_flow_deployments
    set flow_version_id = '86000000-0000-4000-8000-000000000003'
    where organization_address = 'deployment-whatsapp-connected'
  $$,
  '23514',
  'chatbot deployments require a published version of the selected flow',
  'a draft version is rejected'
);

select throws_ok(
  $$
    update public.chatbot_flow_deployments
    set flow_version_id = '86000000-0000-4000-8000-000000000004'
    where organization_address = 'deployment-whatsapp-connected'
  $$,
  '23514',
  'chatbot deployments require a published version of the selected flow',
  'a version belonging to another flow is rejected'
);

select throws_ok(
  $$
    update public.chatbot_flow_deployments
    set agent_id = '36000000-0000-4000-8000-000000000002'
    where organization_address = 'deployment-whatsapp-connected'
  $$,
  '23514',
  'chatbot deployments require the organization chatbot runtime identity',
  'a human agent is rejected'
);

select throws_ok(
  $$
    update public.chatbot_flow_deployments
    set agent_id = '36000000-0000-4000-8000-000000000003'
    where organization_address = 'deployment-whatsapp-connected'
  $$,
  '23514',
  'chatbot deployments require the organization chatbot runtime identity',
  'an inactive AI agent is rejected'
);

select throws_ok(
  $$
    update public.chatbot_flow_deployments
    set agent_id = '36000000-0000-4000-8000-000000000004'
    where organization_address = 'deployment-whatsapp-connected'
  $$,
  '23514',
  'chatbot deployments require the organization chatbot runtime identity',
  'an AI agent from another organization is rejected'
);

select throws_ok(
  $$
    update public.chatbot_flow_deployments
    set agent_id = '36000000-0000-4000-8000-000000000005'
    where organization_address = 'deployment-whatsapp-connected'
  $$,
  '23514',
  'chatbot deployments require the organization chatbot runtime identity',
  'a regular active AI agent is rejected'
);

select throws_ok(
  $$
    update public.chatbot_flow_deployments
    set flow_id = '76000000-0000-4000-8000-000000000002',
        flow_version_id = '86000000-0000-4000-8000-000000000004'
    where organization_address = 'deployment-whatsapp-connected'
  $$,
  '23514',
  'chatbot deployments require an active flow from the same organization',
  'an archived flow is rejected'
);

update public.chatbot_flow_deployments
set flow_version_id = '86000000-0000-4000-8000-000000000002',
    activated_at = now()
where organization_address = 'deployment-whatsapp-connected';

select is(
  (
    select flow_version_id
    from public.chatbot_flow_deployments
    where organization_address = 'deployment-whatsapp-connected'
  ),
  '86000000-0000-4000-8000-000000000002'::uuid,
  'the deployment can atomically move an address to a newer published version'
);

select is(
  (
    select count(*)
    from public.chatbot_flow_deployments
    where organization_address = 'deployment-whatsapp-connected'
  ),
  1::bigint,
  'an address has exactly one current chatbot deployment'
);

select * from finish();

rollback;
