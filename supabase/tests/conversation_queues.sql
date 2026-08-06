begin;

create extension if not exists pgtap with schema extensions;

set local search_path = extensions, public, auth;

select plan(6);

insert into public.organizations (id, name, extra)
values
  (
    '11000000-0000-4000-8000-000000000001',
    'Queue Test Org A',
    '{}'
  ),
  (
    '11000000-0000-4000-8000-000000000002',
    'Queue Test Org B',
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
  '21000000-0000-4000-8000-000000000001',
  'authenticated',
  'authenticated',
  'queue-user-a@example.test',
  crypt('password', gen_salt('bf')),
  '{"provider":"email","providers":["email"]}',
  '{"name":"Queue User A"}',
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
  '31000000-0000-4000-8000-000000000001',
  '11000000-0000-4000-8000-000000000001',
  '21000000-0000-4000-8000-000000000001',
  'Queue Agent A',
  false,
  '{"role":"member"}'
);

select is(
  (
    select count(*)::integer
    from public.get_conversation_queues()
  ),
  7,
  'default conversation queue config exposes the Mentioned queue'
);

select results_eq(
  $$
    select key
    from public.get_conversation_queues()
    order by "order"
  $$,
  $$
    values
      ('all_active'::text),
      ('assigned'::text),
      ('pending'::text),
      ('mentioned'::text),
      ('spam'::text),
      ('closed'::text),
      ('expired'::text)
  $$,
  'conversation queue keys are returned in the base order'
);

select results_eq(
  $$
    select label
    from public.get_conversation_queues()
    order by "order"
  $$,
  $$
    values
      ('All (active)'::text),
      ('Assigned'::text),
      ('Pending'::text),
      ('Mentioned'::text),
      ('Spam'::text),
      ('Closed'::text),
      ('Expired'::text)
  $$,
  'conversation queue labels match the base Digital Connect wording'
);

select ok(
  bool_and(enabled),
  'all base queues are enabled by default'
)
from public.get_conversation_queues();

select set_config(
  'request.jwt.claim.sub',
  '21000000-0000-4000-8000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth;

select is(
  (
    select count(*)::integer
    from public.get_conversation_queues(
      '11000000-0000-4000-8000-000000000001'
    )
  ),
  7,
  'an organization member can read queue config including Mentioned'
);

select throws_ok(
  $$
    select *
    from public.get_conversation_queues(
      '11000000-0000-4000-8000-000000000002'
    )
  $$,
  '42501',
  'organization is not accessible to the authenticated user',
  'queue config denies organizations outside the authenticated user access'
);

select * from finish();

rollback;
