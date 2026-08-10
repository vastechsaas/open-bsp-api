begin;

create extension if not exists pgtap with schema extensions;

set local search_path = extensions, public, auth, billing;

select plan(35);

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
    '21000000-0000-4000-8000-000000000001',
    'authenticated',
    'authenticated',
    'platform-active@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Active Platform Admin"}',
    now(), now(), now(), '', '', '', ''
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '21000000-0000-4000-8000-000000000002',
    'authenticated',
    'authenticated',
    'platform-revoked@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Revoked Platform Admin"}',
    now(), now(), now(), '', '', '', ''
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '21000000-0000-4000-8000-000000000003',
    'authenticated',
    'authenticated',
    'tenant-owner@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Tenant Owner"}',
    now(), now(), now(), '', '', '', ''
  ),
  (
    '00000000-0000-0000-8000-000000000000',
    '21000000-0000-4000-8000-000000000004',
    'authenticated',
    'authenticated',
    'tenant-b-owner@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Tenant B Owner"}',
    now(), now(), now(), '', '', '', ''
  );

insert into public.organizations (id, name, extra, created_at, updated_at)
values
  (
    '11000000-0000-4000-8000-000000000001',
    'Alpha Tenant',
    '{}',
    '2026-01-01 00:00:00+00',
    '2026-02-01 00:00:00+00'
  ),
  (
    '11000000-0000-4000-8000-000000000002',
    'Beta Tenant',
    '{}',
    '2026-01-02 00:00:00+00',
    '2026-02-02 00:00:00+00'
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
    '31000000-0000-4000-8000-000000000001',
    '11000000-0000-4000-8000-000000000001',
    '21000000-0000-4000-8000-000000000003',
    'Tenant Owner',
    false,
    '{"role":"owner"}'
  ),
  (
    '31000000-0000-4000-8000-000000000002',
    '11000000-0000-4000-8000-000000000001',
    null,
    'Pending Member',
    false,
    '{"role":"member","invitation":{"email":"pending@example.test","status":"pending"}}'
  ),
  (
    '31000000-0000-4000-8000-000000000003',
    '11000000-0000-4000-8000-000000000001',
    null,
    'Tenant AI',
    true,
    '{}'
  ),
  (
    '31000000-0000-4000-8000-000000000004',
    '11000000-0000-4000-8000-000000000002',
    '21000000-0000-4000-8000-000000000004',
    'Tenant B Owner',
    false,
    '{"role":"owner","invitation":{"status":"accepted"}}'
  );

insert into public.platform_admins (user_id, active)
values
  ('21000000-0000-4000-8000-000000000001', true),
  ('21000000-0000-4000-8000-000000000002', false);

insert into public.organizations_addresses (
  organization_id,
  service,
  address,
  extra,
  status
)
values
  (
    '11000000-0000-4000-8000-000000000001',
    'whatsapp',
    'platform-alpha-whatsapp',
    '{}',
    'connected'
  ),
  (
    '11000000-0000-4000-8000-000000000001',
    'instagram',
    'platform-alpha-instagram',
    '{}',
    'connected'
  ),
  (
    '11000000-0000-4000-8000-000000000002',
    'whatsapp',
    'platform-beta-whatsapp',
    '{}',
    'connected'
  ),
  (
    '11000000-0000-4000-8000-000000000002',
    'instagram',
    'platform-beta-instagram-disconnected',
    '{}',
    'disconnected'
  );

insert into public.contacts (id, organization_id, name, status)
values
  (
    '41000000-0000-4000-8000-000000000001',
    '11000000-0000-4000-8000-000000000001',
    'Alpha Active Contact',
    'active'
  ),
  (
    '41000000-0000-4000-8000-000000000002',
    '11000000-0000-4000-8000-000000000001',
    'Alpha Inactive Contact',
    'inactive'
  ),
  (
    '41000000-0000-4000-8000-000000000003',
    '11000000-0000-4000-8000-000000000002',
    'Beta Active Contact',
    'active'
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
    '11000000-0000-4000-8000-000000000001',
    '41000000-0000-4000-8000-000000000001',
    'whatsapp',
    'platform-alpha-contact',
    'active'
  ),
  (
    '11000000-0000-4000-8000-000000000001',
    '41000000-0000-4000-8000-000000000002',
    'whatsapp',
    'platform-alpha-contact-inactive',
    'inactive'
  ),
  (
    '11000000-0000-4000-8000-000000000002',
    '41000000-0000-4000-8000-000000000003',
    'whatsapp',
    'platform-beta-contact',
    'active'
  );

insert into public.conversations (
  id,
  organization_id,
  service,
  organization_address,
  contact_address,
  name,
  status,
  extra
)
values
  (
    '51000000-0000-4000-8000-000000000001',
    '11000000-0000-4000-8000-000000000001',
    'whatsapp',
    'platform-alpha-whatsapp',
    'platform-alpha-contact',
    'Alpha Active Conversation',
    'active',
    '{}'
  ),
  (
    '51000000-0000-4000-8000-000000000002',
    '11000000-0000-4000-8000-000000000001',
    'whatsapp',
    'platform-alpha-whatsapp',
    'platform-alpha-contact',
    'Alpha Closed Conversation',
    'closed',
    '{}'
  ),
  (
    '51000000-0000-4000-8000-000000000003',
    '11000000-0000-4000-8000-000000000002',
    'whatsapp',
    'platform-beta-whatsapp',
    'platform-beta-contact',
    'Beta Active Conversation',
    'active',
    '{}'
  );

insert into billing.tiers (id, name, level, active)
values ('platform-test-tier', 'Platform Test Tier', 99, true);

insert into billing.plans (id, min_tier, price, billing_cycle, active)
values ('platform-test-plan', 99, 25, 'month', true);

update billing.subscriptions
set
  tier_id = 'platform-test-tier',
  plan_id = 'platform-test-plan'
where organization_id = '11000000-0000-4000-8000-000000000001';

select ok(
  not has_table_privilege(
    'authenticated',
    'public.platform_admins',
    'SELECT'
  ),
  'authenticated users cannot select the platform allowlist directly'
);

select ok(
  not has_table_privilege(
    'authenticated',
    'public.platform_admins',
    'INSERT'
  ),
  'authenticated users cannot insert platform administrators directly'
);

select ok(
  not has_table_privilege(
    'authenticated',
    'public.platform_admins',
    'UPDATE'
  ),
  'authenticated users cannot update platform administrators directly'
);

select ok(
  not has_table_privilege(
    'authenticated',
    'public.platform_admins',
    'DELETE'
  ),
  'authenticated users cannot delete platform administrators directly'
);

select set_config(
  'request.jwt.claim.sub',
  '21000000-0000-4000-8000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth, billing;

select is(
  public.is_platform_admin(),
  true,
  'active allowlisted users are platform administrators'
);

reset role;

select results_eq(
  $$
    select
      organization_count,
      human_member_count,
      active_contact_count,
      active_conversation_count,
      connected_whatsapp_account_count,
      connected_instagram_account_count
    from public.get_platform_overview()
  $$,
  $$
    select
      (select count(*) from public.organizations),
      (
        select count(*)
        from public.agents as agent
        where agent.ai = false
          and agent.user_id is not null
          and (
            agent.extra->'invitation' is null
            or agent.extra->'invitation'->>'status' = 'accepted'
          )
      ),
      (
        select count(*)
        from public.contacts as contact
        where contact.status = 'active'
      ),
      (
        select count(*)
        from public.conversations as conversation
        where conversation.status = 'active'
      ),
      (
        select count(*)
        from public.organizations_addresses as account
        where account.service = 'whatsapp'::public.service
          and account.status = 'connected'
      ),
      (
        select count(*)
        from public.organizations_addresses as account
        where account.service = 'instagram'::public.service
          and account.status = 'connected'
      )
  $$,
  'global overview returns operational totals and excludes inactive records'
);

set local role authenticated;

select results_eq(
  $$
    select organization_name, total_count
    from public.list_platform_organizations_page(1, 10, 'tenant')
  $$,
  $$ values ('Beta Tenant'::text, 2::bigint), ('Alpha Tenant'::text, 2::bigint) $$,
  'organization list uses deterministic updated-at and id ordering'
);

select results_eq(
  $$
    select organization_name
    from public.list_platform_organizations_page(1, 10, 'alpha')
  $$,
  $$ values ('Alpha Tenant'::text) $$,
  'organization list searches names case-insensitively'
);

select results_eq(
  $$
    select organization_name
    from public.list_platform_organizations_page(
      1,
      10,
      '11000000-0000-4000-8000-000000000002'
    )
  $$,
  $$ values ('Beta Tenant'::text) $$,
  'organization list searches organization ids'
);

select results_eq(
  $$
    select organization_name
    from public.list_platform_organizations_page(1, 1, 'tenant')
  $$,
  $$ values ('Beta Tenant'::text) $$,
  'organization pagination returns the first requested page'
);

select results_eq(
  $$
    select organization_name
    from public.list_platform_organizations_page(2, 1, 'tenant')
  $$,
  $$ values ('Alpha Tenant'::text) $$,
  'organization pagination returns the second requested page'
);

select results_eq(
  $$
    select
      organization_name,
      tier_id,
      tier_name,
      plan_id,
      human_member_count,
      active_contact_count,
      active_conversation_count,
      connected_whatsapp_account_count,
      connected_instagram_account_count
    from public.get_platform_tenant_summary(
      '11000000-0000-4000-8000-000000000001'
    )
  $$,
  $$
    values (
      'Alpha Tenant'::text,
      'platform-test-tier'::text,
      'Platform Test Tier'::text,
      'platform-test-plan'::text,
      1::bigint,
      1::bigint,
      1::bigint,
      1::bigint,
      1::bigint
    )
  $$,
  'tenant summary returns identity, billing, people, workload, and channels'
);

select throws_ok(
  $$
    select *
    from public.get_platform_tenant_summary(
      '11000000-0000-4000-8000-000000000099'
    )
  $$,
  'P0002',
  'organization not found',
  'tenant summary rejects an unknown organization'
);

select throws_ok(
  $$ select * from public.get_platform_tenant_summary(null) $$,
  '22023',
  'organization id is required',
  'tenant summary requires an organization id'
);

select ok(
  public.record_platform_access(
    null,
    'global',
    '61000000-0000-4000-8000-000000000001'
  ) is not null,
  'global access recording returns an event id'
);

select is(
  public.record_platform_access(
    null,
    'global',
    '61000000-0000-4000-8000-000000000001'
  ),
  public.record_platform_access(
    null,
    'global',
    '61000000-0000-4000-8000-000000000001'
  ),
  'repeating the same access request returns the existing event'
);

reset role;

select is(
  (
    select count(*)
    from public.platform_admin_access_events
    where request_id = '61000000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'repeating an access request does not create a duplicate event'
);

set local role authenticated;

select ok(
  public.record_platform_access(
    '11000000-0000-4000-8000-000000000001',
    'tenant',
    '61000000-0000-4000-8000-000000000002'
  ) is not null,
  'tenant access recording returns an event id'
);

reset role;

select results_eq(
  $$
    select scope, organization_id
    from public.platform_admin_access_events
    where request_id = '61000000-0000-4000-8000-000000000002'
  $$,
  $$ values ('tenant'::text, '11000000-0000-4000-8000-000000000001'::uuid) $$,
  'tenant access records the selected organization'
);

select is(
  (
    select count(*)
    from pg_constraint
    where conname = 'platform_admin_access_events_organization_fkey'
  ),
  0::bigint,
  'audit events preserve the selected tenant id without blocking tenant deletion'
);

set local role authenticated;

select throws_ok(
  $$
    select public.record_platform_access(
      null,
      'invalid',
      '61000000-0000-4000-8000-000000000003'
    )
  $$,
  '22023',
  'platform access scope must be global or tenant',
  'access recording rejects an unknown scope'
);

select throws_ok(
  $$
    select public.record_platform_access(
      null,
      'tenant',
      '61000000-0000-4000-8000-000000000004'
    )
  $$,
  '22023',
  'tenant platform access requires an organization',
  'tenant access requires an organization'
);

select throws_ok(
  $$
    select public.record_platform_access(
      '11000000-0000-4000-8000-000000000001',
      'global',
      '61000000-0000-4000-8000-000000000005'
    )
  $$,
  '22023',
  'global platform access cannot specify an organization',
  'global access rejects an organization'
);

select throws_ok(
  $$
    select public.record_platform_access(
      '11000000-0000-4000-8000-000000000001',
      'tenant',
      '61000000-0000-4000-8000-000000000001'
    )
  $$,
  '22023',
  'request id was already used for a different platform access',
  'an idempotency key cannot be reused for different access data'
);

select throws_ok(
  $$
    select public.record_platform_access(
      '11000000-0000-4000-8000-000000000099',
      'tenant',
      '61000000-0000-4000-8000-000000000006'
    )
  $$,
  'P0002',
  'organization not found',
  'tenant access rejects an unknown organization'
);

select set_config(
  'request.jwt.claim.sub',
  '21000000-0000-4000-8000-000000000002',
  true
);

select is(
  public.is_platform_admin(),
  false,
  'revoked allowlist entries are not platform administrators'
);

select throws_ok(
  $$ select * from public.get_platform_overview() $$,
  '42501',
  'platform administrator access required',
  'revoked platform administrators cannot read the overview'
);

select set_config(
  'request.jwt.claim.sub',
  '21000000-0000-4000-8000-000000000003',
  true
);

select is(
  public.is_platform_admin(),
  false,
  'ordinary tenant users are not platform administrators'
);

select throws_ok(
  $$ select * from public.get_platform_overview() $$,
  '42501',
  'platform administrator access required',
  'ordinary tenant users cannot read the platform overview'
);

select throws_ok(
  $$ select * from public.list_platform_organizations_page(1, 10, null) $$,
  '42501',
  'platform administrator access required',
  'ordinary tenant users cannot list platform organizations'
);

select is(
  (
    select count(*)
    from public.organizations
    where id = '11000000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'existing tenant RLS still lets an owner read their organization'
);

select is(
  (
    select count(*)
    from public.organizations
    where id = '11000000-0000-4000-8000-000000000002'
  ),
  0::bigint,
  'existing tenant RLS still hides other organizations from an owner'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.is_platform_admin()',
    'EXECUTE'
  ),
  'anonymous callers cannot execute the platform authorization function'
);

reset role;

insert into public.organizations (id, name, extra, created_at, updated_at)
select
  md5('platform-page-cap-' || generated.id::text)::uuid,
  'Generated Tenant ' || lpad(generated.id::text, 2, '0'),
  '{}',
  '2025-01-01 00:00:00+00',
  '2025-01-01 00:00:00+00'
from generate_series(1, 55) as generated(id);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '21000000-0000-4000-8000-000000000001',
  true
);

reset role;

select is(
  (
    select count(*)
    from public.list_platform_organizations_page(1, 500, null)
  ),
  50::bigint,
  'organization page size is capped at fifty rows'
);

select is(
  (
    select max(total_count)
    from public.list_platform_organizations_page(1, 500, null)
  ),
  (select count(*) from public.organizations),
  'organization rows expose the full filtered total'
);

select * from finish();

rollback;
