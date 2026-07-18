begin;

create extension if not exists pgtap with schema extensions;

set local search_path = extensions, public, auth;

select plan(12);

insert into public.organizations (id, name, extra)
values
  ('19000000-0000-4000-8000-000000000001', 'Dashboard Org A', '{}'),
  ('19000000-0000-4000-8000-000000000002', 'Dashboard Org B', '{}');

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
    '29000000-0000-4000-8000-000000000001',
    'authenticated',
    'authenticated',
    'dashboard-a@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Dashboard Agent A"}',
    now(), now(), now(), '', '', '', ''
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '29000000-0000-4000-8000-000000000002',
    'authenticated',
    'authenticated',
    'dashboard-b@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Dashboard Agent B"}',
    now(), now(), now(), '', '', '', ''
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
    '39000000-0000-4000-8000-000000000001',
    '19000000-0000-4000-8000-000000000001',
    '29000000-0000-4000-8000-000000000001',
    'Dashboard Agent A',
    false,
    '{"role":"owner"}'
  ),
  (
    '39000000-0000-4000-8000-000000000002',
    '19000000-0000-4000-8000-000000000001',
    null,
    'Pending Agent',
    false,
    '{"role":"member","invitation":{"email":"pending@example.test","status":"pending"}}'
  ),
  (
    '39000000-0000-4000-8000-000000000003',
    '19000000-0000-4000-8000-000000000002',
    '29000000-0000-4000-8000-000000000002',
    'Dashboard Agent B',
    false,
    '{"role":"owner"}'
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
    '19000000-0000-4000-8000-000000000001',
    'whatsapp',
    'dashboard-org-a',
    '{}',
    'connected'
  ),
  (
    '19000000-0000-4000-8000-000000000002',
    'whatsapp',
    'dashboard-org-b',
    '{}',
    'connected'
  );

insert into public.contacts (
  id,
  organization_id,
  name,
  status,
  created_at
)
values
  (
    '49000000-0000-4000-8000-000000000001',
    '19000000-0000-4000-8000-000000000001',
    'Recent Contact',
    'active',
    now() - interval '1 day'
  ),
  (
    '49000000-0000-4000-8000-000000000002',
    '19000000-0000-4000-8000-000000000001',
    'Existing Contact',
    'active',
    now() - interval '10 days'
  ),
  (
    '49000000-0000-4000-8000-000000000003',
    '19000000-0000-4000-8000-000000000002',
    'Other Organization Contact',
    'active',
    now()
  );

insert into public.contacts_addresses (
  organization_id,
  contact_id,
  service,
  address,
  status
)
values
  (
    '19000000-0000-4000-8000-000000000001',
    '49000000-0000-4000-8000-000000000001',
    'whatsapp',
    'dashboard-contact-recent',
    'active'
  ),
  (
    '19000000-0000-4000-8000-000000000001',
    '49000000-0000-4000-8000-000000000002',
    'whatsapp',
    'dashboard-contact-existing',
    'active'
  ),
  (
    '19000000-0000-4000-8000-000000000002',
    '49000000-0000-4000-8000-000000000003',
    'whatsapp',
    'dashboard-contact-other',
    'active'
  );

insert into public.conversations (
  id,
  organization_id,
  service,
  organization_address,
  contact_address,
  name,
  assigned_agent_id,
  status,
  extra
)
values
  (
    '59000000-0000-4000-8000-000000000001',
    '19000000-0000-4000-8000-000000000001',
    'whatsapp',
    'dashboard-org-a',
    'dashboard-contact-recent',
    'Assigned Open',
    '39000000-0000-4000-8000-000000000001',
    'active',
    '{}'
  ),
  (
    '59000000-0000-4000-8000-000000000002',
    '19000000-0000-4000-8000-000000000001',
    'whatsapp',
    'dashboard-org-a',
    'dashboard-contact-existing',
    'Unassigned Open',
    null,
    'active',
    '{}'
  ),
  (
    '59000000-0000-4000-8000-000000000003',
    '19000000-0000-4000-8000-000000000001',
    'whatsapp',
    'dashboard-org-a',
    'dashboard-contact-recent',
    'Assigned Closed',
    '39000000-0000-4000-8000-000000000001',
    'closed',
    '{}'
  ),
  (
    '59000000-0000-4000-8000-000000000004',
    '19000000-0000-4000-8000-000000000002',
    'whatsapp',
    'dashboard-org-b',
    'dashboard-contact-other',
    'Other Organization Open',
    '39000000-0000-4000-8000-000000000003',
    'active',
    '{}'
  );

insert into public.messages (
  organization_id,
  conversation_id,
  external_id,
  direction,
  agent_id,
  contact_address,
  service,
  organization_address,
  content,
  status,
  timestamp
)
values
  (
    '19000000-0000-4000-8000-000000000001',
    '59000000-0000-4000-8000-000000000001',
    'dashboard-message-a-today-in',
    'incoming',
    null,
    'dashboard-contact-recent',
    'whatsapp',
    'dashboard-org-a',
    '{"version":"1","type":"text","kind":"text","text":"hello"}',
    '{}',
    now() - interval '1 hour'
  ),
  (
    '19000000-0000-4000-8000-000000000001',
    '59000000-0000-4000-8000-000000000001',
    'dashboard-message-a-today-out',
    'outgoing',
    '39000000-0000-4000-8000-000000000001',
    null,
    'whatsapp',
    'dashboard-org-a',
    '{"version":"1","type":"text","kind":"text","text":"welcome"}',
    '{}',
    now() - interval '30 minutes'
  ),
  (
    '19000000-0000-4000-8000-000000000001',
    '59000000-0000-4000-8000-000000000002',
    'dashboard-message-a-existing-in',
    'incoming',
    null,
    'dashboard-contact-existing',
    'whatsapp',
    'dashboard-org-a',
    '{"version":"1","type":"text","kind":"text","text":"older"}',
    '{}',
    now() - interval '3 days'
  ),
  (
    '19000000-0000-4000-8000-000000000002',
    '59000000-0000-4000-8000-000000000004',
    'dashboard-message-b-today-in',
    'incoming',
    null,
    'dashboard-contact-other',
    'whatsapp',
    'dashboard-org-b',
    '{"version":"1","type":"text","kind":"text","text":"private"}',
    '{}',
    now() - interval '1 hour'
  );

select set_config(
  'request.jwt.claim.sub',
  '29000000-0000-4000-8000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth;

select results_eq(
  $$
    select
      total_contacts,
      active_today,
      active_last_7_days,
      active_last_30_days,
      new_contacts
    from public.get_dashboard_metrics(
      '19000000-0000-4000-8000-000000000001',
      7
    )
  $$,
  $$ values (2::bigint, 1::bigint, 2::bigint, 2::bigint, 1::bigint) $$,
  'dashboard returns organization contact activity totals'
);

select results_eq(
  $$
    select open_conversations, unassigned_conversations, closed_conversations
    from public.get_dashboard_metrics(
      '19000000-0000-4000-8000-000000000001',
      7
    )
  $$,
  $$ values (2::bigint, 1::bigint, 1::bigint) $$,
  'dashboard returns conversation workload totals'
);

select is(
  (
    select jsonb_array_length(contact_activity)
    from public.get_dashboard_metrics(
      '19000000-0000-4000-8000-000000000001',
      7
    )
  ),
  7,
  'dashboard returns one contact activity point per requested day'
);

select is(
  (
    select sum((point->>'active_contacts')::integer)::integer
    from public.get_dashboard_metrics(
      '19000000-0000-4000-8000-000000000001',
      7
    ) metrics
    cross join jsonb_array_elements(metrics.contact_activity) point
  ),
  2,
  'contact activity counts unique active contacts per day'
);

select is(
  (
    select jsonb_array_length(message_activity)
    from public.get_dashboard_metrics(
      '19000000-0000-4000-8000-000000000001',
      30
    )
  ),
  30,
  'dashboard supports the 30-day chart period'
);

select results_eq(
  $$
    select
      sum((point->>'sent')::integer)::integer,
      sum((point->>'received')::integer)::integer
    from public.get_dashboard_metrics(
      '19000000-0000-4000-8000-000000000001',
      7
    ) metrics
    cross join jsonb_array_elements(metrics.message_activity) point
  $$,
  $$ values (1, 2) $$,
  'message activity separates outgoing and incoming messages'
);

select results_eq(
  $$
    select
      member->>'name',
      (member->>'assigned')::integer,
      (member->>'open')::integer,
      (member->>'closed')::integer
    from public.get_dashboard_metrics(
      '19000000-0000-4000-8000-000000000001',
      7
    ) metrics
    cross join jsonb_array_elements(metrics.team_snapshot) member
  $$,
  $$ values ('Dashboard Agent A'::text, 2, 1, 1) $$,
  'team snapshot includes active human members and excludes pending invitations'
);

select is(
  (
    select period_end - period_start
    from public.get_dashboard_metrics(
      '19000000-0000-4000-8000-000000000001',
      7
    )
  ),
  6,
  'seven-day dashboard period includes today and six previous UTC dates'
);

select throws_ok(
  $$
    select *
    from public.get_dashboard_metrics(
      '19000000-0000-4000-8000-000000000001',
      14
    )
  $$,
  '22023',
  'dashboard period must be 7 or 30 days',
  'dashboard rejects unsupported periods'
);

select throws_ok(
  $$
    select *
    from public.get_dashboard_metrics(
      '19000000-0000-4000-8000-000000000002',
      7
    )
  $$,
  '42501',
  'organization is not accessible to the authenticated user',
  'dashboard enforces organization isolation'
);

select is(
  (
    select total_contacts
    from public.get_dashboard_metrics(
      '19000000-0000-4000-8000-000000000001',
      7
    )
  ),
  2::bigint,
  'other-organization contacts do not leak into dashboard totals'
);

select is(
  (
    select (team_snapshot->0->>'name')
    from public.get_dashboard_metrics(
      '19000000-0000-4000-8000-000000000001',
      7
    )
  ),
  'Dashboard Agent A',
  'team snapshot ordering is deterministic'
);

select * from finish();

rollback;
