begin;

create extension if not exists pgtap with schema extensions;

set local search_path = extensions, public, auth;

select plan(10);

insert into public.organizations (id, name, extra)
values
  (
    '10000000-0000-4000-8000-000000000001',
    'Assignment Test Org A',
    '{}'
  ),
  (
    '10000000-0000-4000-8000-000000000002',
    'Assignment Test Org B',
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
    '20000000-0000-4000-8000-000000000001',
    'authenticated',
    'authenticated',
    'assignment-user-a@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Assignment User A"}',
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
    '20000000-0000-4000-8000-000000000002',
    'authenticated',
    'authenticated',
    'assignment-user-b@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Assignment User B"}',
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
    '30000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000001',
    'Assignment Agent A',
    false,
    '{"role":"member"}'
  ),
  (
    '30000000-0000-4000-8000-000000000002',
    '10000000-0000-4000-8000-000000000002',
    '20000000-0000-4000-8000-000000000002',
    'Assignment Agent B',
    false,
    '{"role":"member"}'
  ),
  (
    '30000000-0000-4000-8000-000000000003',
    '10000000-0000-4000-8000-000000000001',
    null,
    'Assignment AI Agent',
    true,
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
    '10000000-0000-4000-8000-000000000001',
    'whatsapp',
    'assignment-org-a-address',
    '{}',
    'connected'
  ),
  (
    '10000000-0000-4000-8000-000000000002',
    'whatsapp',
    'assignment-org-b-address',
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
  extra
)
values
  (
    '40000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000001',
    'whatsapp',
    'assignment-org-a-address',
    'assignment-contact-a',
    'Assignment Conversation A',
    '{}'
  ),
  (
    '40000000-0000-4000-8000-000000000002',
    '10000000-0000-4000-8000-000000000002',
    'whatsapp',
    'assignment-org-b-address',
    'assignment-contact-b',
    'Assignment Conversation B',
    '{}'
  );

select is(
  (
    select assigned_agent_id
    from public.conversations
    where id = '40000000-0000-4000-8000-000000000001'
  ),
  null,
  'new conversations are unassigned by default'
);

select set_config(
  'request.jwt.claim.sub',
  '20000000-0000-4000-8000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth;

select lives_ok(
  $$ select public.assign_conversation_to_me(
    '40000000-0000-4000-8000-000000000001'
  ) $$,
  'an org member can assign an unassigned conversation to themself'
);

select is(
  (
    select assigned_agent_id
    from public.conversations
    where id = '40000000-0000-4000-8000-000000000001'
  ),
  '30000000-0000-4000-8000-000000000001'::uuid,
  'assign-to-me stores the current human agent id'
);

select throws_ok(
  $$ select public.assign_conversation_to_me(
    '40000000-0000-4000-8000-000000000001'
  ) $$,
  '23505',
  'conversation is already assigned',
  'assign-to-me does not take over an already-assigned conversation'
);

select lives_ok(
  $$ select public.unassign_conversation_from_me(
    '40000000-0000-4000-8000-000000000001'
  ) $$,
  'the current assignee can unassign their conversation'
);

select is(
  (
    select assigned_agent_id
    from public.conversations
    where id = '40000000-0000-4000-8000-000000000001'
  ),
  null,
  'unassign clears the conversation assignee'
);

select throws_ok(
  $$ select public.assign_conversation_to_me(
    '40000000-0000-4000-8000-000000000002'
  ) $$,
  '42501',
  'conversation is not accessible to the authenticated user',
  'assign-to-me denies conversations outside the user organization'
);

select throws_ok(
  $$ update public.conversations
    set assigned_agent_id = '30000000-0000-4000-8000-000000000002'
    where id = '40000000-0000-4000-8000-000000000001' $$,
  '23514',
  'Conversation assignee must be a human agent in the same organization',
  'organization validation rejects an assignee from another organization'
);

select throws_ok(
  $$ update public.conversations
    set assigned_agent_id = '30000000-0000-4000-8000-000000000003'
    where id = '40000000-0000-4000-8000-000000000001' $$,
  '23514',
  'Conversation assignee must be a human agent in the same organization',
  'organization validation rejects AI agents'
);

select is(
  (
    select assigned_agent_id
    from public.conversations
    where id = '40000000-0000-4000-8000-000000000001'
  ),
  null,
  'failed assignment updates leave the conversation unassigned'
);

select * from finish();

rollback;
