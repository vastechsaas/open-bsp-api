begin;

create extension if not exists pgtap with schema extensions;

set local search_path = extensions, public, auth;

select plan(9);

insert into public.organizations (id, name, extra)
values
  (
    '12000000-0000-4000-8000-000000000001',
    'Queue Filter Org A',
    '{}'
  ),
  (
    '12000000-0000-4000-8000-000000000002',
    'Queue Filter Org B',
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
  '22000000-0000-4000-8000-000000000001',
  'authenticated',
  'authenticated',
  'queue-filter-user-a@example.test',
  crypt('password', gen_salt('bf')),
  '{"provider":"email","providers":["email"]}',
  '{"name":"Queue Filter User A"}',
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
  '32000000-0000-4000-8000-000000000001',
  '12000000-0000-4000-8000-000000000001',
  '22000000-0000-4000-8000-000000000001',
  'Queue Filter Agent A',
  false,
  '{"role":"member"}'
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
    '12000000-0000-4000-8000-000000000001',
    'whatsapp',
    'queue-filter-org-a-address',
    '{}',
    'connected'
  ),
  (
    '12000000-0000-4000-8000-000000000002',
    'whatsapp',
    'queue-filter-org-b-address',
    '{}',
    'connected'
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
  extra,
  updated_at
)
values
  (
    '42000000-0000-4000-8000-000000000001',
    '12000000-0000-4000-8000-000000000001',
    'whatsapp',
    'queue-filter-org-a-address',
    'queue-filter-contact-active-unassigned',
    'Active Unassigned',
    null,
    'active',
    '{}',
    now() - interval '1 minute'
  ),
  (
    '42000000-0000-4000-8000-000000000002',
    '12000000-0000-4000-8000-000000000001',
    'whatsapp',
    'queue-filter-org-a-address',
    'queue-filter-contact-active-assigned',
    'Active Assigned',
    '32000000-0000-4000-8000-000000000001',
    'active',
    '{}',
    now() - interval '2 minutes'
  ),
  (
    '42000000-0000-4000-8000-000000000003',
    '12000000-0000-4000-8000-000000000001',
    'whatsapp',
    'queue-filter-org-a-address',
    'queue-filter-contact-spam',
    'Spam Conversation',
    null,
    'spam',
    '{}',
    now() - interval '3 minutes'
  ),
  (
    '42000000-0000-4000-8000-000000000004',
    '12000000-0000-4000-8000-000000000001',
    'whatsapp',
    'queue-filter-org-a-address',
    'queue-filter-contact-closed',
    'Closed Conversation',
    null,
    'closed',
    '{}',
    now() - interval '4 minutes'
  ),
  (
    '42000000-0000-4000-8000-000000000005',
    '12000000-0000-4000-8000-000000000001',
    'whatsapp',
    'queue-filter-org-a-address',
    'queue-filter-contact-expired',
    'Expired Active',
    null,
    'active',
    '{}',
    now() - interval '5 minutes'
  ),
  (
    '42000000-0000-4000-8000-000000000006',
    '12000000-0000-4000-8000-000000000001',
    'whatsapp',
    'queue-filter-org-a-address',
    'queue-filter-contact-fresh',
    'Fresh Active',
    null,
    'active',
    '{}',
    now() - interval '6 minutes'
  ),
  (
    '42000000-0000-4000-8000-000000000007',
    '12000000-0000-4000-8000-000000000001',
    'whatsapp',
    'queue-filter-org-a-address',
    'queue-filter-contact-no-incoming',
    'No Incoming Active',
    null,
    'active',
    '{}',
    now() - interval '7 minutes'
  ),
  (
    '42000000-0000-4000-8000-000000000008',
    '12000000-0000-4000-8000-000000000002',
    'whatsapp',
    'queue-filter-org-b-address',
    'queue-filter-contact-org-b',
    'Org B Active',
    null,
    'active',
    '{}',
    now() - interval '8 minutes'
  );

insert into public.messages (
  organization_id,
  conversation_id,
  external_id,
  direction,
  contact_address,
  service,
  organization_address,
  content,
  status,
  timestamp
)
values
  (
    '12000000-0000-4000-8000-000000000001',
    '42000000-0000-4000-8000-000000000005',
    'queue-filter-expired-message',
    'incoming',
    'queue-filter-contact-expired',
    'whatsapp',
    'queue-filter-org-a-address',
    '{"version":"1","type":"text","kind":"text","text":"old"}',
    '{}',
    now() - interval '25 hours'
  ),
  (
    '12000000-0000-4000-8000-000000000001',
    '42000000-0000-4000-8000-000000000006',
    'queue-filter-fresh-message',
    'incoming',
    'queue-filter-contact-fresh',
    'whatsapp',
    'queue-filter-org-a-address',
    '{"version":"1","type":"text","kind":"text","text":"fresh"}',
    '{}',
    now() - interval '1 hour'
  );

select set_config(
  'request.jwt.claim.sub',
  '22000000-0000-4000-8000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth;

select results_eq(
  $$
    select name
    from public.get_conversation_queue_conversations(
      '12000000-0000-4000-8000-000000000001',
      'all_active'
    )
    order by name
  $$,
  $$
    values
      ('Active Assigned'::text),
      ('Active Unassigned'::text),
      ('Expired Active'::text),
      ('Fresh Active'::text),
      ('No Incoming Active'::text)
  $$,
  'all_active returns every active conversation for the organization'
);

select results_eq(
  $$
    select name
    from public.get_conversation_queue_conversations(
      '12000000-0000-4000-8000-000000000001',
      'assigned'
    )
  $$,
  $$ values ('Active Assigned'::text) $$,
  'assigned returns active conversations with an assignee'
);

select results_eq(
  $$
    select name
    from public.get_conversation_queue_conversations(
      '12000000-0000-4000-8000-000000000001',
      'pending'
    )
    order by name
  $$,
  $$
    values
      ('Active Unassigned'::text),
      ('Expired Active'::text),
      ('Fresh Active'::text),
      ('No Incoming Active'::text)
  $$,
  'pending returns active conversations without an assignee'
);

select results_eq(
  $$
    select name
    from public.get_conversation_queue_conversations(
      '12000000-0000-4000-8000-000000000001',
      'spam'
    )
  $$,
  $$ values ('Spam Conversation'::text) $$,
  'spam returns conversations with spam lifecycle status'
);

select results_eq(
  $$
    select name
    from public.get_conversation_queue_conversations(
      '12000000-0000-4000-8000-000000000001',
      'closed'
    )
  $$,
  $$ values ('Closed Conversation'::text) $$,
  'closed returns conversations with closed lifecycle status'
);

select results_eq(
  $$
    select name
    from public.get_conversation_queue_conversations(
      '12000000-0000-4000-8000-000000000001',
      'expired'
    )
  $$,
  $$ values ('Expired Active'::text) $$,
  'expired returns active conversations whose latest incoming message is 24h+ old'
);

select results_eq(
  $$
    select name
    from public.get_conversation_queue_conversations(
      '12000000-0000-4000-8000-000000000001',
      'all_active',
      2,
      1
    )
  $$,
  $$
    values
      ('Active Assigned'::text),
      ('Expired Active'::text)
  $$,
  'queue filtering supports deterministic limit and offset pagination'
);

select throws_ok(
  $$
    select *
    from public.get_conversation_queue_conversations(
      '12000000-0000-4000-8000-000000000001',
      'not-a-queue'
    )
  $$,
  '22023',
  'invalid conversation queue key',
  'unknown queue keys are rejected'
);

select throws_ok(
  $$
    select *
    from public.get_conversation_queue_conversations(
      '12000000-0000-4000-8000-000000000002',
      'all_active'
    )
  $$,
  '42501',
  'organization is not accessible to the authenticated user',
  'queue filtering denies organizations outside the authenticated user access'
);

select * from finish();

rollback;
