begin;

create extension if not exists pgtap with schema extensions;

set local search_path = extensions, public, auth, billing, storage;

select plan(45);

insert into public.organizations (id, name, extra)
values
  ('10200000-0000-4000-8000-000000000001', 'Supervisor Org A', '{}'),
  ('10200000-0000-4000-8000-000000000002', 'Supervisor Org B', '{}');

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
    '20200000-0000-4000-8000-000000000001',
    'authenticated',
    'authenticated',
    'supervisor-a@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Supervisor A"}',
    now(), now(), now(), '', '', '', ''
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '20200000-0000-4000-8000-000000000002',
    'authenticated',
    'authenticated',
    'member-a@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Member A"}',
    now(), now(), now(), '', '', '', ''
  );

insert into public.agents (id, organization_id, user_id, name, ai, extra)
values
  (
    '30200000-0000-4000-8000-000000000001',
    '10200000-0000-4000-8000-000000000001',
    '20200000-0000-4000-8000-000000000001',
    'Supervisor A',
    false,
    '{"role":"supervisor"}'
  ),
  (
    '30200000-0000-4000-8000-000000000002',
    '10200000-0000-4000-8000-000000000001',
    '20200000-0000-4000-8000-000000000002',
    'Member A',
    false,
    '{"role":"member"}'
  ),
  (
    '30200000-0000-4000-8000-000000000003',
    '10200000-0000-4000-8000-000000000001',
    null,
    'Protected Admin',
    false,
    '{"role":"admin","invitation":{"email":"admin@example.test","status":"pending"}}'
  ),
  (
    '30200000-0000-4000-8000-000000000004',
    '10200000-0000-4000-8000-000000000001',
    null,
    'Protected Supervisor',
    false,
    '{"role":"supervisor","invitation":{"email":"supervisor-b@example.test","status":"pending"}}'
  ),
  (
    '30200000-0000-4000-8000-000000000005',
    '10200000-0000-4000-8000-000000000001',
    null,
    'Protected Owner',
    false,
    '{"role":"owner","invitation":{"email":"owner@example.test","status":"pending"}}'
  );

insert into public.organizations_addresses (
  organization_id,
  service,
  address,
  extra,
  status
)
values
  ('10200000-0000-4000-8000-000000000001', 'whatsapp', 'supervisor-org-a', '{}', 'connected'),
  ('10200000-0000-4000-8000-000000000002', 'whatsapp', 'supervisor-org-b', '{}', 'connected');

insert into public.contacts (id, organization_id, name, status)
values
  ('40200000-0000-4000-8000-000000000001', '10200000-0000-4000-8000-000000000001', 'Contact A', 'active'),
  ('40200000-0000-4000-8000-000000000002', '10200000-0000-4000-8000-000000000002', 'Contact B', 'active');

insert into public.contacts_addresses (
  organization_id,
  contact_id,
  service,
  address,
  extra,
  status
)
values
  ('10200000-0000-4000-8000-000000000001', '40200000-0000-4000-8000-000000000001', 'whatsapp', '15551020001', '{}', 'active'),
  ('10200000-0000-4000-8000-000000000002', '40200000-0000-4000-8000-000000000002', 'whatsapp', '15551020002', '{}', 'active');

insert into public.conversations (
  id,
  organization_id,
  service,
  organization_address,
  contact_address,
  name,
  extra
)
values
  ('50200000-0000-4000-8000-000000000001', '10200000-0000-4000-8000-000000000001', 'whatsapp', 'supervisor-org-a', '15551020001', 'Conversation A', '{}'),
  ('50200000-0000-4000-8000-000000000002', '10200000-0000-4000-8000-000000000002', 'whatsapp', 'supervisor-org-b', '15551020002', 'Conversation B', '{}');

insert into public.messages (
  id,
  organization_id,
  conversation_id,
  direction,
  contact_address,
  service,
  organization_address,
  content,
  timestamp
)
values (
  '60200000-0000-4000-8000-000000000001',
  '10200000-0000-4000-8000-000000000001',
  '50200000-0000-4000-8000-000000000001',
  'incoming',
  '15551020001',
  'whatsapp',
  'supervisor-org-a',
  '{"version":"1","type":"text","kind":"text","text":"Hello"}',
  now() - interval '1 day'
);

insert into public.quick_replies (id, organization_id, name, content)
values
  ('70200000-0000-4000-8000-000000000001', '10200000-0000-4000-8000-000000000001', 'Greeting', 'Hello there'),
  ('70200000-0000-4000-8000-000000000002', '10200000-0000-4000-8000-000000000002', 'Other', 'Other organization');

insert into public.message_templates (
  organization_id,
  id,
  organization_address,
  external_id,
  name,
  language,
  category,
  status,
  components
)
values (
  '10200000-0000-4000-8000-000000000001',
  '80200000-0000-4000-8000-000000000001',
  'supervisor-org-a',
  'supervisor-template-a',
  'approved_greeting',
  'en_US',
  'utility',
  'approved',
  '[{"type":"BODY","text":"Approved greeting"}]'
);

insert into public.campaigns (
  organization_id,
  id,
  created_by,
  name,
  organization_address,
  template,
  audience_type
)
values (
  '10200000-0000-4000-8000-000000000001',
  '90200000-0000-4000-8000-000000000001',
  '30200000-0000-4000-8000-000000000002',
  'Member Campaign',
  'supervisor-org-a',
  '{"id":"template-a","name":"approved_greeting","language":"en_US","status":"APPROVED","components":[]}',
  'all_contacts'
);

insert into public.chatbot_flows (organization_id, id, created_by, name)
values (
  '10200000-0000-4000-8000-000000000001',
  'a0200000-0000-4000-8000-000000000001',
  '30200000-0000-4000-8000-000000000002',
  'Member Chatbot'
);

insert into public.logs (id, organization_id, level, category, message)
values (
  'b0200000-0000-4000-8000-000000000001',
  '10200000-0000-4000-8000-000000000001',
  'info',
  'supervisor-test',
  'Member-visible log'
);

insert into billing.tiers (id, name, level)
values ('scrum-102-supervisor-tier', 'Supervisor Test Tier', 102)
on conflict (id) do nothing;

insert into billing.subscriptions (organization_id, tier_id)
values ('10200000-0000-4000-8000-000000000001', 'scrum-102-supervisor-tier')
on conflict (organization_id) do update
set tier_id = excluded.tier_id;

select lives_ok(
  $$
    insert into public.api_keys (organization_id, role, name, key)
    values (
      '10200000-0000-4000-8000-000000000001',
      'member',
      'Valid member key',
      'scrum-102-member-key'
    )
  $$,
  'existing API-key roles remain valid'
);

select throws_like(
  $$
    insert into public.api_keys (organization_id, role, name, key)
    values (
      '10200000-0000-4000-8000-000000000001',
      'supervisor',
      'Invalid supervisor key',
      'scrum-102-supervisor-key'
    )
  $$,
  '%api_keys_role_check%',
  'Supervisor cannot be assigned to an API key'
);

select set_config('request.jwt.claim.sub', '20200000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth, billing, storage;

select results_eq(
  $$ select public.get_authorized_orgs('supervisor') $$,
  $$ values ('10200000-0000-4000-8000-000000000001'::uuid) $$,
  'Supervisor satisfies the Supervisor role threshold'
);

select is_empty(
  $$ select public.get_authorized_orgs('admin') $$,
  'Supervisor does not satisfy the Admin role threshold'
);

select is_empty(
  $$
    select public.get_authorized_orgs_by_roles(
      array['owner', 'admin', 'member']::public.role[]
    )
  $$,
  'exact-role authorization can exclude Supervisor while retaining Member'
);

select lives_ok(
  $$
    insert into public.agents (id, organization_id, name, ai, extra)
    values (
      '30200000-0000-4000-8000-000000000006',
      '10200000-0000-4000-8000-000000000001',
      'Invited Member',
      false,
      '{"role":"member","invitation":{"email":"invited-member@example.test","status":"pending"}}'
    )
  $$,
  'Supervisor can invite a Member'
);

select is(
  (
    select count(*)
    from public.agents
    where id = '30200000-0000-4000-8000-000000000006'
  ),
  1::bigint,
  'Supervisor Member invitation is created'
);

select throws_like(
  $$
    insert into public.agents (id, organization_id, name, ai, extra)
    values (
      '30200000-0000-4000-8000-000000000007',
      '10200000-0000-4000-8000-000000000001',
      'Escalated Supervisor',
      false,
      '{"role":"supervisor","invitation":{"email":"escalated@example.test","status":"pending"}}'
    )
  $$,
  '%row-level security%',
  'Supervisor cannot invite another Supervisor'
);

select lives_ok(
  $$
    update public.agents
    set name = 'Member Managed by Supervisor'
    where id = '30200000-0000-4000-8000-000000000002'
  $$,
  'Supervisor can update a Member'
);

select throws_like(
  $$
    update public.agents
    set extra = jsonb_set(extra, '{role}', '"supervisor"')
    where id = '30200000-0000-4000-8000-000000000002'
  $$,
  '%row-level security%',
  'Supervisor cannot promote a Member'
);

select results_eq(
  $$
    select name, extra->>'role'
    from public.agents
    where id = '30200000-0000-4000-8000-000000000002'
  $$,
  $$ values ('Member Managed by Supervisor'::text, 'member'::text) $$,
  'Supervisor Member update preserves the role'
);

select lives_ok(
  $$
    delete from public.agents
    where id = '30200000-0000-4000-8000-000000000006'
  $$,
  'Supervisor can remove a Member invitation'
);

select is(
  (
    select count(*)
    from public.agents
    where id = '30200000-0000-4000-8000-000000000006'
  ),
  0::bigint,
  'Supervisor Member invitation is removed'
);

select is_empty(
  $$
    update public.agents
    set name = 'Unauthorized management'
    where id in (
      '30200000-0000-4000-8000-000000000003',
      '30200000-0000-4000-8000-000000000004',
      '30200000-0000-4000-8000-000000000005'
    )
    returning id
  $$,
  'Supervisor cannot update Admin, Supervisor, or Owner records'
);

select is_empty(
  $$
    delete from public.agents
    where id in (
      '30200000-0000-4000-8000-000000000003',
      '30200000-0000-4000-8000-000000000004',
      '30200000-0000-4000-8000-000000000005'
    )
    returning id
  $$,
  'Supervisor cannot remove Admin, Supervisor, or Owner records'
);

select is(
  (select count(*) from public.organizations where id = '10200000-0000-4000-8000-000000000001'),
  1::bigint,
  'Supervisor can read their organization'
);

select is(
  (select count(*) from public.organizations where id = '10200000-0000-4000-8000-000000000002'),
  0::bigint,
  'Supervisor cannot read another organization'
);

select lives_ok(
  $$
    insert into public.contacts (organization_id, name)
    values ('10200000-0000-4000-8000-000000000001', 'Created by Supervisor')
  $$,
  'Supervisor can create contacts'
);

select lives_ok(
  $$
    update public.contacts
    set name = 'Updated by Supervisor'
    where id = '40200000-0000-4000-8000-000000000001'
  $$,
  'Supervisor can update contacts'
);

select is(
  (select count(*) from public.contacts where organization_id = '10200000-0000-4000-8000-000000000001'),
  2::bigint,
  'Supervisor sees contacts only in their organization'
);

select is(
  (select count(*) from public.conversations where id = '50200000-0000-4000-8000-000000000001'),
  1::bigint,
  'Supervisor can read organization conversations'
);

select is(
  (select count(*) from public.conversations where id = '50200000-0000-4000-8000-000000000002'),
  0::bigint,
  'Supervisor cannot read another organization conversation'
);

select is(
  (select count(*) from public.messages where id = '60200000-0000-4000-8000-000000000001'),
  1::bigint,
  'Supervisor can read organization messages'
);

select lives_ok(
  $$
    insert into public.messages (
      organization_id,
      conversation_id,
      direction,
      contact_address,
      service,
      organization_address,
      content,
      timestamp
    ) values (
      '10200000-0000-4000-8000-000000000001',
      '50200000-0000-4000-8000-000000000001',
      'incoming',
      '15551020001',
      'whatsapp',
      'supervisor-org-a',
      '{"version":"1","type":"text","kind":"text","text":"Supervisor reply test"}',
      now() - interval '1 day'
    )
  $$,
  'Supervisor can create organization messages'
);

select lives_ok(
  $$
    insert into storage.objects (bucket_id, name, metadata)
    values (
      'media',
      'organizations/10200000-0000-4000-8000-000000000001/attachments/supervisor.txt',
      '{"size":12}'
    )
  $$,
  'Supervisor can upload organization media'
);

select is(
  (
    select count(*)
    from storage.objects
    where name = 'organizations/10200000-0000-4000-8000-000000000001/attachments/supervisor.txt'
  ),
  1::bigint,
  'Supervisor can read organization media'
);

select lives_ok(
  $$
    insert into public.quick_replies (organization_id, name, content)
    values ('10200000-0000-4000-8000-000000000001', 'Supervisor Reply', 'Created')
  $$,
  'Supervisor can create quick replies'
);

select lives_ok(
  $$
    update public.quick_replies
    set content = 'Updated'
    where id = '70200000-0000-4000-8000-000000000001'
  $$,
  'Supervisor can update quick replies'
);

select lives_ok(
  $$
    delete from public.quick_replies
    where id = '70200000-0000-4000-8000-000000000001'
  $$,
  'Supervisor can delete quick replies'
);

select lives_ok(
  $$
    select *
    from public.get_dashboard_metrics('10200000-0000-4000-8000-000000000001')
  $$,
  'Supervisor can access organization dashboard metrics'
);

select lives_ok(
  $$ select public.assign_conversation_to_me('50200000-0000-4000-8000-000000000001') $$,
  'Supervisor can assign an unassigned conversation to themself'
);

select lives_ok(
  $$ select public.unassign_conversation_from_me('50200000-0000-4000-8000-000000000001') $$,
  'Supervisor can unassign their conversation'
);

select is(
  (select count(*) from public.message_templates where organization_id = '10200000-0000-4000-8000-000000000001'),
  1::bigint,
  'Supervisor can read approved message templates'
);

select throws_like(
  $$
    insert into public.message_templates (
      organization_id,
      organization_address,
      name,
      language,
      category
    ) values (
      '10200000-0000-4000-8000-000000000001',
      'supervisor-org-a',
      'supervisor_draft',
      'en_US',
      'utility'
    )
  $$,
  '%row-level security%',
  'Supervisor cannot create message templates'
);

select is(
  (select count(*) from public.campaigns),
  0::bigint,
  'Supervisor cannot read campaigns'
);

select throws_like(
  $$
    insert into public.campaigns (
      organization_id,
      name,
      organization_address,
      template,
      audience_type
    ) values (
      '10200000-0000-4000-8000-000000000001',
      'Supervisor Campaign',
      'supervisor-org-a',
      '{"id":"template-b","name":"approved_greeting","language":"en_US","status":"APPROVED","components":[]}',
      'all_contacts'
    )
  $$,
  '%row-level security%',
  'Supervisor cannot create campaigns'
);

select is(
  (select count(*) from public.chatbot_flows),
  0::bigint,
  'Supervisor cannot read chatbot flows'
);

select is(
  (select count(*) from public.logs),
  0::bigint,
  'Supervisor cannot read organization logs'
);

select is(
  (select count(*) from billing.subscriptions),
  0::bigint,
  'Supervisor cannot read organization subscription state'
);

select is(
  (select count(*) from public.api_keys),
  0::bigint,
  'Supervisor cannot read organization API keys'
);

select set_config('request.jwt.claim.sub', '20200000-0000-4000-8000-000000000002', true);

select is(
  (select count(*) from public.campaigns),
  1::bigint,
  'existing Member campaign access is unchanged'
);

select is(
  (select count(*) from public.chatbot_flows),
  1::bigint,
  'existing Member chatbot read access is unchanged'
);

select is(
  (select count(*) from public.logs),
  1::bigint,
  'existing Member log read access is unchanged'
);

select is(
  (select count(*) from billing.subscriptions),
  1::bigint,
  'existing Member subscription read access is unchanged'
);

select is(
  (select count(*) from public.message_templates),
  1::bigint,
  'existing Member template read access is unchanged'
);

select * from finish();

rollback;
