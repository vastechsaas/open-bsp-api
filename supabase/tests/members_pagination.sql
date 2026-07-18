begin;

create extension if not exists pgtap with schema extensions;

set local search_path = extensions, public, auth;

select plan(14);

insert into public.organizations (id, name, extra)
values
  ('17000000-0000-4000-8000-000000000001', 'Members Org A', '{}'),
  ('17000000-0000-4000-8000-000000000002', 'Members Org B', '{}');

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
    '27000000-0000-4000-8000-000000000001',
    'authenticated',
    'authenticated',
    'alice@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Alice Owner"}',
    now(), now(), now(), '', '', '', ''
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '27000000-0000-4000-8000-000000000002',
    'authenticated',
    'authenticated',
    'bob@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Bob Admin"}',
    now(), now(), now(), '', '', '', ''
  ),
  (
    '00000000-0000-0000-0000-000000000003',
    '27000000-0000-4000-8000-000000000003',
    'authenticated',
    'authenticated',
    'eve-secret@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Eve Owner"}',
    now(), now(), now(), '', '', '', ''
  );

insert into public.agents (
  id,
  organization_id,
  user_id,
  name,
  ai,
  extra,
  created_at,
  updated_at
)
values
  (
    '37000000-0000-4000-8000-000000000001',
    '17000000-0000-4000-8000-000000000001',
    '27000000-0000-4000-8000-000000000001',
    'Alice Owner',
    false,
    '{"role":"owner"}',
    '2026-01-01 00:00:00+00',
    '2026-01-01 00:00:00+00'
  ),
  (
    '37000000-0000-4000-8000-000000000002',
    '17000000-0000-4000-8000-000000000001',
    '27000000-0000-4000-8000-000000000002',
    'Bob Admin',
    false,
    '{"role":"admin","invitation":{"organization_name":"Members Org A","email":"bob@example.test","status":"accepted"}}',
    '2026-01-02 00:00:00+00',
    '2026-01-04 00:00:00+00'
  ),
  (
    '37000000-0000-4000-8000-000000000003',
    '17000000-0000-4000-8000-000000000001',
    null,
    'Carol Pending',
    false,
    '{"role":"member","invitation":{"organization_name":"Members Org A","email":"carol@example.test","status":"pending"}}',
    '2026-01-03 00:00:00+00',
    '2026-01-03 00:00:00+00'
  ),
  (
    '37000000-0000-4000-8000-000000000004',
    '17000000-0000-4000-8000-000000000001',
    null,
    'Dan Rejected',
    false,
    '{"role":"member","invitation":{"organization_name":"Members Org A","email":"dan@example.test","status":"rejected"}}',
    '2026-01-04 00:00:00+00',
    '2026-01-02 00:00:00+00'
  ),
  (
    '37000000-0000-4000-8000-000000000005',
    '17000000-0000-4000-8000-000000000001',
    null,
    'AI Helper',
    true,
    '{}',
    '2026-01-05 00:00:00+00',
    '2026-01-05 00:00:00+00'
  ),
  (
    '37000000-0000-4000-8000-000000000006',
    '17000000-0000-4000-8000-000000000002',
    '27000000-0000-4000-8000-000000000003',
    'Eve Owner',
    false,
    '{"role":"owner"}',
    '2026-01-01 00:00:00+00',
    '2026-01-01 00:00:00+00'
  );

select set_config(
  'request.jwt.claim.sub',
  '27000000-0000-4000-8000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth;

select results_eq(
  $$
    select count(*)::integer, max(total_count)::integer
    from public.list_members_page(
      '17000000-0000-4000-8000-000000000001',
      1,
      2
    )
  $$,
  $$ values (2, 4) $$,
  'member listing returns the requested page and full human-member total'
);

select results_eq(
  $$
    select name
    from public.list_members_page(
      '17000000-0000-4000-8000-000000000001',
      2,
      2
    )
  $$,
  $$ values ('Dan Rejected'::text), ('Alice Owner'::text) $$,
  'member listing uses deterministic updated ordering across pages'
);

select results_eq(
  $$
    select status, count(*)::bigint
    from public.list_members_page(
      '17000000-0000-4000-8000-000000000001',
      p_page_size => 50
    )
    group by status
    order by status
  $$,
  $$ values ('active'::text, 2::bigint), ('pending'::text, 1::bigint), ('rejected'::text, 1::bigint) $$,
  'member listing maps invitation states to active, pending, and rejected'
);

select is(
  (
    select email
    from public.list_members_page(
      '17000000-0000-4000-8000-000000000001',
      p_search => 'Alice Owner'
    )
  ),
  'alice@example.test',
  'active member email is resolved from auth users'
);

select is(
  (
    select email
    from public.list_members_page(
      '17000000-0000-4000-8000-000000000001',
      p_search => 'Carol Pending'
    )
  ),
  'carol@example.test',
  'pending member email is resolved from the invitation'
);

select results_eq(
  $$
    select name
    from public.list_members_page(
      '17000000-0000-4000-8000-000000000001',
      p_search => 'BOB@EXAMPLE'
    )
  $$,
  $$ values ('Bob Admin'::text) $$,
  'member listing searches email case-insensitively'
);

select results_eq(
  $$
    select name
    from public.list_members_page(
      '17000000-0000-4000-8000-000000000001',
      p_role => 'admin'
    )
  $$,
  $$ values ('Bob Admin'::text) $$,
  'member listing filters by role'
);

select results_eq(
  $$
    select name
    from public.list_members_page(
      '17000000-0000-4000-8000-000000000001',
      p_status => 'pending'
    )
  $$,
  $$ values ('Carol Pending'::text) $$,
  'member listing filters by status'
);

select is(
  (
    select count(*)::integer
    from public.list_members_page(
      '17000000-0000-4000-8000-000000000001',
      p_search => 'eve-secret@example.test'
    )
  ),
  0,
  'member search does not expose another organization email'
);

select throws_ok(
  $$
    select *
    from public.list_members_page(
      '17000000-0000-4000-8000-000000000001',
      p_status => 'disabled'
    )
  $$,
  '22023',
  'member status filter is invalid',
  'member listing rejects unknown statuses'
);

select throws_ok(
  $$
    select *
    from public.list_members_page(
      '17000000-0000-4000-8000-000000000002'
    )
  $$,
  '42501',
  'organization is not accessible to the authenticated user',
  'member listing denies inaccessible organizations'
);

select throws_ok(
  $$
    insert into public.agents (organization_id, name, ai, extra)
    values (
      '17000000-0000-4000-8000-000000000001',
      'Duplicate Carol',
      false,
      '{"role":"member","invitation":{"organization_name":"Members Org A","email":"CAROL@example.test","status":"pending"}}'
    )
  $$,
  'P0001',
  'An invitation for this email already exists in this organization',
  'duplicate invitations remain blocked case-insensitively'
);

select throws_ok(
  $$
    update public.agents
    set extra = '{"role":"admin"}'
    where id = '37000000-0000-4000-8000-000000000001'
  $$,
  'P0001',
  'Cannot delete the last owner of an organization',
  'the final owner cannot be downgraded'
);

select throws_ok(
  $$
    delete from public.agents
    where id = '37000000-0000-4000-8000-000000000001'
  $$,
  'P0001',
  'Cannot delete the last owner of an organization',
  'the final owner cannot leave or be removed'
);

select * from finish();

rollback;
