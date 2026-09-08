begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select no_plan();

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at, created_at,
  updated_at, confirmation_token, recovery_token, email_change_token_new,
  email_change
) values
  ('00000000-0000-0000-0000-000000000000', 'f1100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'lifecycle-owner@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'f1100000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'lifecycle-member@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'f1100000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'lifecycle-platform@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', '');

insert into public.organizations (id, name, extra)
values ('f1000000-0000-4000-8000-000000000001', 'Lifecycle Tenant', '{}');

insert into public.organizations_addresses (
  organization_id, service, address, status, extra
) values (
  'f1000000-0000-4000-8000-000000000001', 'whatsapp', '100200300', 'connected', '{}'
);

insert into public.agents (id, organization_id, user_id, name, ai, extra) values
  ('f1200000-0000-4000-8000-000000000001', 'f1000000-0000-4000-8000-000000000001', 'f1100000-0000-4000-8000-000000000001', 'Owner', false, '{"role":"owner"}'),
  ('f1200000-0000-4000-8000-000000000002', 'f1000000-0000-4000-8000-000000000001', 'f1100000-0000-4000-8000-000000000002', 'Member', false, '{"role":"member"}');

insert into public.platform_admins (user_id, active)
values ('f1100000-0000-4000-8000-000000000003', true);

select is(
  (select status from public.organization_lifecycle where organization_id = 'f1000000-0000-4000-8000-000000000001'),
  'active'::text,
  'new organizations start active'
);

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', 'f1100000-0000-4000-8000-000000000002', true);
select throws_ok(
  $$ select public.archive_organization('f1000000-0000-4000-8000-000000000001', 'Lifecycle Tenant', 'not allowed', 'f1300000-0000-4000-8000-000000000001') $$,
  '42501',
  'owner or platform administrator access required',
  'ordinary members cannot archive'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', 'f1100000-0000-4000-8000-000000000001', true);
select is(
  (select status from public.archive_organization('f1000000-0000-4000-8000-000000000001', 'Lifecycle Tenant', 'customer requested pause', 'f1300000-0000-4000-8000-000000000002')),
  'archived'::text,
  'owner archives with exact-name confirmation'
);
select lives_ok(
  $$ select public.archive_organization('f1000000-0000-4000-8000-000000000001', 'Lifecycle Tenant', 'customer requested pause', 'f1300000-0000-4000-8000-000000000002') $$,
  'archive request is idempotent'
);
select is(
  (select count(*) from public.get_authorized_orgs('member')),
  0::bigint,
  'archived organization is removed from normal authorization'
);
select is(
  (select organization_name from public.list_my_archived_organizations_page(1, 10, null)),
  'Lifecycle Tenant'::text,
  'owner can list the archived organization through the recovery API'
);
reset role;

select is(
  (select status from public.organizations_addresses where organization_id = 'f1000000-0000-4000-8000-000000000001' and address = '100200300'),
  'archived'::text,
  'archive suspends the connected WABA locally'
);
select is(
  (select count(*) from public.organization_lifecycle_events where action_type = 'organization.archive'),
  1::bigint,
  'archive audit is append-only and not duplicated'
);
select throws_ok(
  $$ delete from public.organizations where id = 'f1000000-0000-4000-8000-000000000001' $$,
  '42501',
  'direct organization deletion is disabled; archive the organization instead',
  'direct organization deletion is blocked even for privileged SQL'
);

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', 'f1100000-0000-4000-8000-000000000001', true);
select is(
  (select status from public.restore_organization('f1000000-0000-4000-8000-000000000001', 'returning to service', 'f1300000-0000-4000-8000-000000000003')),
  'active'::text,
  'owner restores during the recovery window'
);
reset role;

select is(
  (select status from public.organizations_addresses where organization_id = 'f1000000-0000-4000-8000-000000000001' and address = '100200300'),
  'connected'::text,
  'restore recovers the previous connected address state'
);

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', 'f1100000-0000-4000-8000-000000000003', true);
select is(
  (select status from public.archive_organization('f1000000-0000-4000-8000-000000000001', 'Lifecycle Tenant', 'platform suspension', 'f1300000-0000-4000-8000-000000000004')),
  'archived'::text,
  'platform administrator can archive'
);
reset role;

update public.organization_lifecycle
set purge_eligible_at = clock_timestamp() - interval '1 minute'
where organization_id = 'f1000000-0000-4000-8000-000000000001';

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', 'f1100000-0000-4000-8000-000000000001', true);
select throws_ok(
  $$ select public.restore_organization('f1000000-0000-4000-8000-000000000001', 'late owner restore', 'f1300000-0000-4000-8000-000000000005') $$,
  '42501',
  'platform administrator access required after the recovery window',
  'owner cannot restore after the recovery window'
);
reset role;

set local role service_role;
select is(
  (public.purge_archived_organization('f1000000-0000-4000-8000-000000000001', 'Lifecycle Tenant', 'retention elapsed', 'f1300000-0000-4000-8000-000000000006', 'f1100000-0000-4000-8000-000000000003')->>'status'),
  'purged'::text,
  'eligible organization can be permanently purged by a platform administrator'
);
reset role;

select is(
  (select count(*) from public.organizations where id = 'f1000000-0000-4000-8000-000000000001'),
  0::bigint,
  'purge cascades the organization data'
);
select is(
  (select count(*) from public.organization_lifecycle_events where action_type = 'organization.purge'),
  1::bigint,
  'purge audit survives organization deletion'
);

select * from finish();
rollback;
