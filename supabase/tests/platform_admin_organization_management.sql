begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, billing;
select no_plan();

insert into public.organizations (id, name, extra) values
  ('b1000000-0000-4000-8000-000000000001', 'DKR', '{}'),
  ('b1000000-0000-4000-8000-000000000002', 'Other Tenant', '{}');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at, created_at,
  updated_at, confirmation_token, recovery_token, email_change_token_new,
  email_change
) values
  ('00000000-0000-0000-0000-000000000000', 'b1100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'platform-admin@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'b1100000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'dkr-owner@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'b1100000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'ali@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'b1100000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'sara@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'b1100000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'other@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', '');

insert into public.agents (id, organization_id, user_id, name, picture, ai, extra) values
  ('b1200000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001', 'b1100000-0000-4000-8000-000000000002', 'DKR Owner', null, false, '{"role":"owner"}'),
  ('b1200000-0000-4000-8000-000000000002', 'b1000000-0000-4000-8000-000000000001', 'b1100000-0000-4000-8000-000000000003', 'Ali', 'ali.png', false, '{"role":"agent"}'),
  ('b1200000-0000-4000-8000-000000000003', 'b1000000-0000-4000-8000-000000000001', 'b1100000-0000-4000-8000-000000000004', 'Sara', null, false, '{"role":"agent"}'),
  ('b1200000-0000-4000-8000-000000000004', 'b1000000-0000-4000-8000-000000000002', 'b1100000-0000-4000-8000-000000000005', 'Other Agent', null, false, '{"role":"agent"}'),
  ('b1200000-0000-4000-8000-000000000005', 'b1000000-0000-4000-8000-000000000001', null, 'Pending Agent', null, false, '{"role":"agent","invitation":{"status":"pending","email":"pending@example.test"}}');

insert into public.platform_admins (user_id, active)
values ('b1100000-0000-4000-8000-000000000001', true);

select ok(
  not has_table_privilege(
    'authenticated',
    'public.platform_admin_action_events',
    'SELECT'
  ),
  'authenticated callers cannot read Platform Admin action events directly'
);

select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth, billing;

select is(
  (
    select accepted_agent_count
    from public.get_platform_tenant_summary(
      'b1000000-0000-4000-8000-000000000001'
    )
  ),
  2::bigint,
  'tenant summary counts only accepted human Agent roles'
);

select results_eq(
  $$
    select name
    from public.list_platform_organization_agents_page(
      'b1000000-0000-4000-8000-000000000001', 1, 10, null
    )
  $$,
  $$ values ('Ali'::text), ('Pending Agent'::text), ('Sara'::text) $$,
  'Platform Admin lists accepted and pending tenant Agents in deterministic order'
);

select results_eq(
  $$
    select name
    from public.create_platform_routing_queue(
      'b1000000-0000-4000-8000-000000000001',
      ' VIP Support ',
      array[
        'b1200000-0000-4000-8000-000000000002'::uuid,
        'b1200000-0000-4000-8000-000000000003'::uuid
      ],
      'b1300000-0000-4000-8000-000000000001'
    )
  $$,
  $$ values ('VIP Support'::text) $$,
  'Platform Admin creates a normalized queue with accepted Agents'
);

select is(
  (
    select id
    from public.create_platform_routing_queue(
      'b1000000-0000-4000-8000-000000000001',
      'VIP Support',
      array[
        'b1200000-0000-4000-8000-000000000002'::uuid,
        'b1200000-0000-4000-8000-000000000003'::uuid
      ],
      'b1300000-0000-4000-8000-000000000001'
    )
  ),
  (
    select id
    from public.list_platform_routing_queues_page(
      'b1000000-0000-4000-8000-000000000001', 1, 10, 'vip', 'active'
    )
  ),
  'repeating a create request returns the original queue'
);

select results_eq(
  $$
    select name, member_names, member_count, total_count
    from public.list_platform_routing_queues_page(
      'b1000000-0000-4000-8000-000000000001', 1, 10, 'vip', 'active'
    )
  $$,
  $$ values (
    'VIP Support'::text,
    array['Ali', 'Sara']::text[],
    2::bigint,
    1::bigint
  ) $$,
  'Platform queue list searches, filters, and returns members without N+1 reads'
);

select results_eq(
  $$
    select queue_names
    from public.list_platform_organization_agents_page(
      'b1000000-0000-4000-8000-000000000001', 1, 10, 'ali'
    )
  $$,
  $$ values (array['VIP Support']::text[]) $$,
  'Agents list returns queue memberships'
);

select results_eq(
  $$
    select status
    from public.update_platform_routing_queue(
      (
        select id
        from public.list_platform_routing_queues_page(
          'b1000000-0000-4000-8000-000000000001', 1, 10, 'vip', null
        )
      ),
      'VIP Support',
      'archived',
      array['b1200000-0000-4000-8000-000000000003'::uuid],
      'b1300000-0000-4000-8000-000000000002'
    )
  $$,
  $$ values ('archived'::text) $$,
  'Platform Admin atomically archives and changes queue membership'
);

select throws_ok(
  $$
    select public.create_platform_routing_queue(
      'b1000000-0000-4000-8000-000000000001',
      'Cross Tenant',
      array['b1200000-0000-4000-8000-000000000004'::uuid],
      'b1300000-0000-4000-8000-000000000003'
    )
  $$,
  '22023',
  'routing queue members must be accepted human Agents in the same organization',
  'Platform Admin cannot add a cross-tenant Agent'
);

reset role;

select is(
  (
    select count(*)
    from public.platform_admin_action_events
    where organization_id = 'b1000000-0000-4000-8000-000000000001'
  ),
  2::bigint,
  'create retry and update produce exactly two audit events'
);

select results_eq(
  $$
    select
      before_state->>'status',
      after_state->>'status',
      jsonb_array_length(after_state->'agent_ids')
    from public.platform_admin_action_events
    where request_id = 'b1300000-0000-4000-8000-000000000002'
  $$,
  $$ values ('active'::text, 'archived'::text, 1) $$,
  'update audit stores the before and after queue state'
);

select set_config('request.jwt.claim.sub', 'b1100000-0000-4000-8000-000000000002', true);
set local role authenticated;
set local search_path = extensions, public, auth, billing;

select throws_ok(
  $$
    select * from public.list_platform_routing_queues_page(
      'b1000000-0000-4000-8000-000000000001', 1, 10, null, null
    )
  $$,
  '42501',
  'platform administrator access required',
  'ordinary tenant users cannot list queues through Platform APIs'
);

select throws_ok(
  $$
    select public.update_platform_routing_queue(
      (
        select id
        from public.list_platform_routing_queues_page(
          'b1000000-0000-4000-8000-000000000001', 1, 10, 'vip', null
        )
      ),
      'VIP Support',
      'active',
      array[]::uuid[],
      'b1300000-0000-4000-8000-000000000004'
    )
  $$,
  '42501',
  'platform administrator access required',
  'ordinary tenant users cannot mutate queues through Platform APIs'
);

select * from finish();
rollback;
