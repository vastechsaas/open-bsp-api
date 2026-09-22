begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, billing;
select no_plan();

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at, created_at,
  updated_at, confirmation_token, recovery_token, email_change_token_new,
  email_change
) values
  ('00000000-0000-0000-0000-000000000000', 'f1100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'platform-onboarding@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'f1100000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'existing-owner@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'f1100000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'ordinary-user@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', '');

insert into public.platform_admins (user_id, active)
values ('f1100000-0000-4000-8000-000000000001', true);

select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', 'f1100000-0000-4000-8000-000000000001', true);
set local role authenticated;

select lives_ok(
  $$
    select public.provision_platform_organization(
      'f1400000-0000-4000-8000-000000000001',
      ' New Tenant ',
      ' Existing Owner ',
      ' EXISTING-OWNER@EXAMPLE.TEST ',
      '[{"name":"Supervisor One","email":"supervisor-one@example.test","role":"supervisor"},{"name":"Agent One","email":"agent-one@example.test","role":"agent"}]'::jsonb,
      2,
      50,
      true
    )
  $$,
  'Super Admin provisions an organization and its initial team'
);

reset role;

select is(
  (
    select count(*)
    from public.organizations organization
    where organization.name = 'New Tenant'
  ),
  1::bigint,
  'organization is created once with a normalized name'
);

select results_eq(
  $$
    select agent.name, agent.user_id, agent.extra->>'role'
    from public.agents agent
    join public.organizations organization on organization.id = agent.organization_id
    where organization.name = 'New Tenant' and agent.extra->>'role' = 'owner'
  $$,
  $$ values ('Existing Owner'::text, 'f1100000-0000-4000-8000-000000000002'::uuid, 'owner'::text) $$,
  'existing auth user is linked as Owner by email'
);

select is(
  (
    select count(*)
    from public.agents agent
    join public.organizations organization on organization.id = agent.organization_id
    where organization.name = 'New Tenant'
      and agent.user_id = 'f1100000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'the provisioning Super Admin is not added to the tenant'
);

select results_eq(
  $$
    select capacity.max_agent_seats, settings.auto_assign_conversations, storage.quota_bytes
    from public.organizations organization
    join public.organization_agent_capacity capacity on capacity.organization_id = organization.id
    join public.organization_automation_settings settings on settings.organization_id = organization.id
    join public.organization_media_storage storage on storage.organization_id = organization.id
    where organization.name = 'New Tenant'
  $$,
  $$ values (2, true, 50000000000::bigint) $$,
  'capacity, auto-assignment and storage quota are configured atomically'
);

select is(
  (
    select (public.provision_platform_organization(
      'f1400000-0000-4000-8000-000000000001',
      'New Tenant',
      'Existing Owner',
      'existing-owner@example.test',
      '[{"name":"Supervisor One","email":"supervisor-one@example.test","role":"supervisor"},{"name":"Agent One","email":"agent-one@example.test","role":"agent"}]'::jsonb,
      2,
      50,
      true
    )).id
  ),
  (select id from public.organization_provisioning where organization_name = 'New Tenant'),
  'repeating the same request is idempotent'
);

select is(
  (select count(*) from public.organization_provisioning_events where event_type = 'started'),
  1::bigint,
  'idempotent replay does not duplicate the started audit event'
);

select lives_ok(
  $$
    select public.finish_platform_organization_provisioning(
      (select id from public.organization_provisioning where organization_name = 'New Tenant'),
      'failed',
      'mail provider unavailable'
    )
  $$,
  'invitation delivery failure is recorded'
);

select is(
  (
    select (public.provision_platform_organization(
      'f1400000-0000-4000-8000-000000000001',
      'New Tenant',
      'Existing Owner',
      'existing-owner@example.test',
      '[{"name":"Supervisor One","email":"supervisor-one@example.test","role":"supervisor"},{"name":"Agent One","email":"agent-one@example.test","role":"agent"}]'::jsonb,
      2,
      50,
      true
    )).status
  ),
  'pending_invitation'::text,
  'a failed request can be retried without recreating tenant records'
);

select results_eq(
  $$
    select event_type, count(*)
    from public.organization_provisioning_events
    group by event_type
    order by event_type
  $$,
  $$ values
    ('failed'::text, 1::bigint),
    ('retried'::text, 1::bigint),
    ('started'::text, 1::bigint)
  $$,
  'provisioning lifecycle is append-only and auditable'
);

select throws_ok(
  $$
    select public.provision_platform_organization(
      'f1400000-0000-4000-8000-000000000001',
      'Different Tenant',
      'Existing Owner',
      'existing-owner@example.test'
    )
  $$,
  '22023',
  'request id was already used with a different onboarding payload',
  'request ID cannot be reused with another payload'
);

select set_config('request.jwt.claim.sub', 'f1100000-0000-4000-8000-000000000003', true);
set local role authenticated;

select throws_ok(
  $$ insert into public.organizations (name) values ('Bypass Tenant') $$,
  '42501',
  'new row violates row-level security policy for table "organizations"',
  'ordinary authenticated users cannot bypass Super Admin onboarding'
);

select throws_ok(
  $$
    select public.provision_platform_organization(
      'f1400000-0000-4000-8000-000000000002',
      'Unauthorized Tenant',
      'Owner',
      'unauthorized-owner@example.test'
    )
  $$,
  '42501',
  'platform administrator access required',
  'non-platform users cannot call the onboarding operation'
);

select * from finish();
rollback;
