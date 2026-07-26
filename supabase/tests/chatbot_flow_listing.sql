begin;

create extension if not exists pgtap with schema extensions;

set local search_path = extensions, public, auth;

select plan(13);

insert into public.organizations (id, name, extra)
values
  (
    '16000000-0000-4000-8000-000000000001',
    'Chatbot Listing Org A',
    '{}'
  ),
  (
    '16000000-0000-4000-8000-000000000002',
    'Chatbot Listing Org B',
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
  '26000000-0000-4000-8000-000000000001',
  'authenticated',
  'authenticated',
  'chatbot-listing-admin@example.test',
  crypt('password', gen_salt('bf')),
  '{"provider":"email","providers":["email"]}',
  '{"name":"Chatbot Listing Admin"}',
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
  '36000000-0000-4000-8000-000000000001',
  '16000000-0000-4000-8000-000000000001',
  '26000000-0000-4000-8000-000000000001',
  'Chatbot Listing Admin',
  false,
  '{"role":"admin"}'
);

insert into public.chatbot_flows (
  organization_id,
  id,
  created_by,
  name,
  status,
  archived_at,
  created_at,
  updated_at
)
values
  (
    '16000000-0000-4000-8000-000000000001',
    '76000000-0000-4000-8000-000000000001',
    '36000000-0000-4000-8000-000000000001',
    'New Customer Support',
    'active',
    null,
    '2026-07-20 10:00:00+00',
    '2026-07-20 10:00:00+00'
  ),
  (
    '16000000-0000-4000-8000-000000000001',
    '76000000-0000-4000-8000-000000000002',
    '36000000-0000-4000-8000-000000000001',
    'Order Status',
    'active',
    null,
    '2026-07-21 10:00:00+00',
    '2026-07-21 10:00:00+00'
  ),
  (
    '16000000-0000-4000-8000-000000000001',
    '76000000-0000-4000-8000-000000000003',
    '36000000-0000-4000-8000-000000000001',
    'Returns Assistant',
    'active',
    null,
    '2026-07-22 10:00:00+00',
    '2026-07-22 10:00:00+00'
  ),
  (
    '16000000-0000-4000-8000-000000000001',
    '76000000-0000-4000-8000-000000000004',
    '36000000-0000-4000-8000-000000000001',
    'Archived Welcome',
    'archived',
    '2026-07-23 10:00:00+00',
    '2026-07-23 10:00:00+00',
    '2026-07-23 10:00:00+00'
  ),
  (
    '16000000-0000-4000-8000-000000000002',
    '76000000-0000-4000-8000-000000000101',
    null,
    'Other Organization Flow',
    'active',
    null,
    '2026-07-24 10:00:00+00',
    '2026-07-24 10:00:00+00'
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
  published_at,
  created_at,
  updated_at
)
values
  (
    '16000000-0000-4000-8000-000000000001',
    '76000000-0000-4000-8000-000000000001',
    '86000000-0000-4000-8000-000000000001',
    '36000000-0000-4000-8000-000000000001',
    1,
    'draft',
    '{"nodes":[],"edges":[]}',
    null,
    null,
    '2026-07-24 09:00:00+00',
    '2026-07-24 09:00:00+00'
  ),
  (
    '16000000-0000-4000-8000-000000000001',
    '76000000-0000-4000-8000-000000000002',
    '86000000-0000-4000-8000-000000000002',
    '36000000-0000-4000-8000-000000000001',
    1,
    'published',
    '{"nodes":[],"edges":[]}',
    '{"schema_version":1,"start_node_id":"start","nodes":[],"edges":[]}',
    '2026-07-21 11:00:00+00',
    '2026-07-21 11:00:00+00',
    '2026-07-21 11:00:00+00'
  ),
  (
    '16000000-0000-4000-8000-000000000001',
    '76000000-0000-4000-8000-000000000002',
    '86000000-0000-4000-8000-000000000003',
    '36000000-0000-4000-8000-000000000001',
    2,
    'draft',
    '{"nodes":[],"edges":[]}',
    null,
    null,
    '2026-07-21 12:00:00+00',
    '2026-07-21 12:00:00+00'
  ),
  (
    '16000000-0000-4000-8000-000000000001',
    '76000000-0000-4000-8000-000000000003',
    '86000000-0000-4000-8000-000000000004',
    '36000000-0000-4000-8000-000000000001',
    1,
    'published',
    '{"nodes":[],"edges":[]}',
    '{"schema_version":1,"start_node_id":"start","nodes":[],"edges":[]}',
    '2026-07-22 11:00:00+00',
    '2026-07-22 11:00:00+00',
    '2026-07-22 11:00:00+00'
  ),
  (
    '16000000-0000-4000-8000-000000000001',
    '76000000-0000-4000-8000-000000000003',
    '86000000-0000-4000-8000-000000000005',
    '36000000-0000-4000-8000-000000000001',
    2,
    'draft',
    '{"nodes":[{"id":"changed"}],"edges":[]}',
    null,
    null,
    '2026-07-22 12:00:00+00',
    '2026-07-22 12:00:00+00'
  ),
  (
    '16000000-0000-4000-8000-000000000001',
    '76000000-0000-4000-8000-000000000004',
    '86000000-0000-4000-8000-000000000006',
    '36000000-0000-4000-8000-000000000001',
    1,
    'draft',
    '{"nodes":[],"edges":[]}',
    null,
    null,
    '2026-07-23 12:00:00+00',
    '2026-07-23 12:00:00+00'
  ),
  (
    '16000000-0000-4000-8000-000000000002',
    '76000000-0000-4000-8000-000000000101',
    '86000000-0000-4000-8000-000000000101',
    null,
    1,
    'draft',
    '{"nodes":[],"edges":[]}',
    null,
    null,
    '2026-07-24 12:00:00+00',
    '2026-07-24 12:00:00+00'
  );

select set_config(
  'request.jwt.claim.sub',
  '26000000-0000-4000-8000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth;

select results_eq(
  $$
    select count(*)::integer, max(total_count)::integer
    from public.list_chatbot_flows_page(
      '16000000-0000-4000-8000-000000000001',
      1,
      2
    )
  $$,
  $$ values (2, 4) $$,
  'listing returns a page and the pre-pagination total'
);

select results_eq(
  $$
    select name
    from public.list_chatbot_flows_page(
      '16000000-0000-4000-8000-000000000001',
      2,
      2
    )
    order by name
  $$,
  $$ values ('Order Status'::text), ('Returns Assistant'::text) $$,
  'page two contains the remaining rows'
);

select results_eq(
  $$
    select name, total_count
    from public.list_chatbot_flows_page(
      '16000000-0000-4000-8000-000000000001',
      p_search => 'returns'
    )
  $$,
  $$ values ('Returns Assistant'::text, 1::bigint) $$,
  'search is applied before counting and pagination'
);

select results_eq(
  $$
    select name, total_count
    from public.list_chatbot_flows_page(
      '16000000-0000-4000-8000-000000000001',
      p_status => 'archived'
    )
  $$,
  $$ values ('Archived Welcome'::text, 1::bigint) $$,
  'archived filtering is applied before counting'
);

select is(
  (
    select created_by_name
    from public.list_chatbot_flows_page(
      '16000000-0000-4000-8000-000000000001',
      p_search => 'new customer'
    )
  ),
  'Chatbot Listing Admin',
  'listing includes the creator display name'
);

select is(
  (
    select has_unpublished_changes
    from public.list_chatbot_flows_page(
      '16000000-0000-4000-8000-000000000001',
      p_search => 'new customer'
    )
  ),
  true,
  'a never-published draft is reported as unpublished'
);

select is(
  (
    select has_unpublished_changes
    from public.list_chatbot_flows_page(
      '16000000-0000-4000-8000-000000000001',
      p_search => 'order status'
    )
  ),
  false,
  'an unchanged draft cloned from a published graph is not dirty'
);

select results_eq(
  $$
    select
      draft_version,
      published_version,
      has_unpublished_changes
    from public.list_chatbot_flows_page(
      '16000000-0000-4000-8000-000000000001',
      p_search => 'returns'
    )
  $$,
  $$ values (2, 1, true) $$,
  'listing includes latest versions and detects changed draft graphs'
);

select throws_ok(
  $$
    select *
    from public.list_chatbot_flows_page(
      '16000000-0000-4000-8000-000000000001',
      p_status => 'deleted'
    )
  $$,
  '22023',
  'chatbot flow status filter is invalid',
  'invalid status filters are rejected'
);

select throws_ok(
  $$
    select *
    from public.list_chatbot_flows_page(
      '16000000-0000-4000-8000-000000000002'
    )
  $$,
  '42501',
  'organization is not accessible to the authenticated user',
  'listing rejects an organization outside the caller membership'
);

reset role;
set local search_path = extensions, public, auth;

insert into public.chatbot_flows (
  organization_id,
  id,
  name,
  created_at,
  updated_at
)
select
  '16000000-0000-4000-8000-000000000001',
  (
    '77000000-0000-4000-8000-'
    || lpad(series::text, 12, '0')
  )::uuid,
  'Generated Flow ' || lpad(series::text, 2, '0'),
  '2026-07-10 10:00:00+00'::timestamp with time zone,
  (
    '2026-07-10 10:00:00+00'::timestamp with time zone
    + make_interval(secs => series)
  )
from generate_series(1, 52) as series;

select set_config(
  'request.jwt.claim.sub',
  '26000000-0000-4000-8000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth;

select is(
  (
    select count(*)::integer
    from public.list_chatbot_flows_page(
      '16000000-0000-4000-8000-000000000001',
      p_page_size => 100
    )
  ),
  50,
  'page size is capped at fifty rows'
);

select is(
  (
    select max(total_count)::integer
    from public.list_chatbot_flows_page(
      '16000000-0000-4000-8000-000000000001',
      p_page_size => 50
    )
  ),
  56,
  'total count includes all matching rows when the page is capped'
);

select results_eq(
  $$
    select name
    from public.list_chatbot_flows_page(
      '16000000-0000-4000-8000-000000000001',
      1,
      2,
      'generated flow'
    )
  $$,
  $$ values ('Generated Flow 52'::text), ('Generated Flow 51'::text) $$,
  'ordering is deterministic by update timestamp and ID'
);

select * from finish();

rollback;
