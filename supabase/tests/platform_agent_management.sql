begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, billing;
select no_plan();

insert into public.organizations (id, name, extra) values
  ('e1000000-0000-4000-8000-000000000001', 'DKR', '{}'),
  ('e1000000-0000-4000-8000-000000000002', 'Other Tenant', '{}');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at, created_at,
  updated_at, confirmation_token, recovery_token, email_change_token_new,
  email_change
) values
  ('00000000-0000-0000-0000-000000000000', 'e1100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'platform@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'e1100000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'owner@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'e1100000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'supervisor@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'e1100000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'agent@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'e1100000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'member@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'e1100000-0000-4000-8000-000000000006', 'authenticated', 'authenticated', 'other-owner@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', '');

insert into public.agents (id, organization_id, user_id, name, ai, extra) values
  ('e1200000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'e1100000-0000-4000-8000-000000000002', 'Owner', false, '{"role":"owner"}'),
  ('e1200000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001', 'e1100000-0000-4000-8000-000000000003', 'Supervisor', false, '{"role":"supervisor"}'),
  ('e1200000-0000-4000-8000-000000000003', 'e1000000-0000-4000-8000-000000000001', 'e1100000-0000-4000-8000-000000000004', 'Ali', false, '{"role":"agent"}'),
  ('e1200000-0000-4000-8000-000000000004', 'e1000000-0000-4000-8000-000000000001', 'e1100000-0000-4000-8000-000000000005', 'Member', false, '{"role":"member"}'),
  ('e1200000-0000-4000-8000-000000000005', 'e1000000-0000-4000-8000-000000000001', null, 'Pending Supervisor', false, '{"role":"supervisor","invitation":{"status":"pending","email":"pending-supervisor@example.test"}}'),
  ('e1200000-0000-4000-8000-000000000006', 'e1000000-0000-4000-8000-000000000001', null, 'AI Agent', true, '{}'),
  ('e1200000-0000-4000-8000-000000000007', 'e1000000-0000-4000-8000-000000000002', 'e1100000-0000-4000-8000-000000000006', 'Other Owner', false, '{"role":"owner"}');

insert into public.platform_admins (user_id, active)
values ('e1100000-0000-4000-8000-000000000001', true);

insert into public.routing_queues (id, organization_id, name) values
  ('e1300000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'VIP Support'),
  ('e1300000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000002', 'Other Queue');

select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', 'e1100000-0000-4000-8000-000000000001', true);
set local role authenticated;

select results_eq(
  $$ select max_agent_seats, used_agent_seats, over_limit from public.get_platform_organization_agent_capacity('e1000000-0000-4000-8000-000000000001') $$,
  $$ values (null::integer, 3::bigint, false) $$,
  'capacity defaults to unlimited and counts accepted/pending Supervisors and Agents only'
);

select results_eq(
  $$ select max_agent_seats, used_agent_seats from public.update_platform_organization_agent_capacity('e1000000-0000-4000-8000-000000000001', 4, 'e1400000-0000-4000-8000-000000000001') $$,
  $$ values (4, 3::bigint) $$,
  'Platform Admin configures a finite capacity'
);

select is(
  (
    select id from public.create_platform_organization_agent_invitation(
      'e1000000-0000-4000-8000-000000000001',
      ' Sara ',
      ' SARA@EXAMPLE.TEST ',
      'e1400000-0000-4000-8000-000000000002'
    )
  ),
  (
    select id from public.create_platform_organization_agent_invitation(
      'e1000000-0000-4000-8000-000000000001',
      'Sara',
      'sara@example.test',
      'e1400000-0000-4000-8000-000000000002'
    )
  ),
  'Platform invitation is pending, normalized, and idempotent'
);

select results_eq(
  $$
    select name, email, invitation_status
    from public.list_platform_organization_agents_page(
      'e1000000-0000-4000-8000-000000000001', 1, 10, null
    )
  $$,
  $$ values
    ('Ali'::text, 'agent@example.test'::text, 'accepted'::text),
    ('Sara'::text, 'sara@example.test'::text, 'pending'::text)
  $$,
  'Agent table includes accepted and pending Agents but excludes Supervisors'
);

select throws_ok(
  $$
    select public.create_platform_organization_agent_invitation(
      'e1000000-0000-4000-8000-000000000001',
      'Capacity Overflow',
      'overflow@example.test',
      'e1400000-0000-4000-8000-000000000003'
    )
  $$,
  '23514',
  'organization Agent capacity has been reached',
  'pending invitations reserve capacity'
);

select throws_ok(
  $$
    select public.create_platform_organization_agent_invitation(
      'e1000000-0000-4000-8000-000000000001',
      'Sara Again',
      'sara@example.test',
      'e1400000-0000-4000-8000-000000000004'
    )
  $$,
  '23505',
  'an active membership or invitation already exists for this email',
  'duplicate pending invitations are rejected'
);

select throws_ok(
  $$
    select public.update_platform_organization_agent(
      (
        select id
        from public.list_platform_organization_agents_page(
          'e1000000-0000-4000-8000-000000000001', 1, 10, 'sara'
        )
      ),
      'Sara Pending',
      array['e1300000-0000-4000-8000-000000000001'::uuid],
      'e1400000-0000-4000-8000-000000000005'
    )
  $$,
  '22023',
  'pending Agents cannot be assigned to routing queues',
  'pending Agent queue membership is rejected'
);

select is(
  (
    select name from public.update_platform_organization_agent(
      'e1200000-0000-4000-8000-000000000003',
      'Ali Khan',
      array['e1300000-0000-4000-8000-000000000001'::uuid],
      'e1400000-0000-4000-8000-000000000006'
    )
  ),
  'Ali Khan'::text,
  'Platform Admin updates accepted Agent name and queue membership'
);

select results_eq(
  $$ select queue_names from public.list_platform_organization_agents_page('e1000000-0000-4000-8000-000000000001', 1, 10, 'ali') $$,
  $$ values (array['VIP Support']::text[]) $$,
  'updated queue membership appears in the Agent list'
);

select throws_ok(
  $$
    select public.update_platform_organization_agent(
      'e1200000-0000-4000-8000-000000000003',
      'Ali Khan',
      array['e1300000-0000-4000-8000-000000000002'::uuid],
      'e1400000-0000-4000-8000-000000000007'
    )
  $$,
  '22023',
  'routing queues must be active and belong to the Agent organization',
  'cross-tenant queue membership is rejected'
);

select results_eq(
  $$ select max_agent_seats, used_agent_seats, over_limit from public.update_platform_organization_agent_capacity('e1000000-0000-4000-8000-000000000001', 2, 'e1400000-0000-4000-8000-000000000008') $$,
  $$ values (2, 4::bigint, true) $$,
  'capacity can be lowered below usage and reports over-limit state'
);

select ok(
  public.remove_platform_organization_agent(
    (
      select id
      from public.list_platform_organization_agents_page(
        'e1000000-0000-4000-8000-000000000001', 1, 10, 'sara'
      )
    ),
    'e1400000-0000-4000-8000-000000000009'
  ),
  'Platform Admin cancels a pending Agent invitation'
);

select is(
  (select used_agent_seats from public.get_platform_organization_agent_capacity('e1000000-0000-4000-8000-000000000001')),
  3::bigint,
  'removing an Agent frees one capacity seat'
);

select throws_ok(
  $$ select public.update_platform_organization_agent('e1200000-0000-4000-8000-000000000002', 'Supervisor Changed', array[]::uuid[], 'e1400000-0000-4000-8000-000000000010') $$,
  '22023',
  'target must be a pending or accepted human Agent',
  'Platform Agent edit cannot mutate a Supervisor'
);

select throws_like(
  $$ update public.organization_agent_capacity set max_agent_seats = 20 where organization_id = 'e1000000-0000-4000-8000-000000000001' $$,
  '%permission denied for table organization_agent_capacity%',
  'direct capacity writes are rejected'
);

reset role;

select is(
  (select count(*) from public.platform_admin_action_events where organization_id = 'e1000000-0000-4000-8000-000000000001'),
  5::bigint,
  'capacity, invitation, update, lower-limit, and removal produce five audit events'
);

select results_eq(
  $$ select before_state->>'max_agent_seats', after_state->>'max_agent_seats' from public.platform_admin_action_events where request_id = 'e1400000-0000-4000-8000-000000000008' $$,
  $$ values ('4'::text, '2'::text) $$,
  'capacity audit records before and after limits'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'e1100000-0000-4000-8000-000000000002', true);

select throws_ok(
  $$ select * from public.get_platform_organization_agent_capacity('e1000000-0000-4000-8000-000000000001') $$,
  '42501',
  'platform administrator access required',
  'ordinary tenant users cannot use Platform Agent APIs'
);

select throws_ok(
  $$
    insert into public.agents (organization_id, name, ai, extra)
    values (
      'e1000000-0000-4000-8000-000000000001',
      'Tenant Overflow',
      false,
      '{"role":"agent","invitation":{"status":"pending","email":"tenant-overflow@example.test"}}'
    )
  $$,
  '23514',
  'organization Agent capacity has been reached',
  'tenant invitation path cannot bypass capacity enforcement'
);

reset role;

select * from finish();
rollback;
