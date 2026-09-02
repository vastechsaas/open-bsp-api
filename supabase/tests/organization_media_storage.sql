begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, billing, storage;
select no_plan();

insert into public.organizations (id, name, extra) values
  ('f1000000-0000-4000-8000-000000000001', 'Storage Tenant A', '{}'),
  ('f1000000-0000-4000-8000-000000000002', 'Storage Tenant B', '{}'),
  ('f1000000-0000-4000-8000-000000000003', 'Archive Tenant', '{}');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at, created_at,
  updated_at, confirmation_token, recovery_token, email_change_token_new,
  email_change
) values
  ('00000000-0000-0000-0000-000000000000', 'f1100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'storage-platform@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'f1100000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'storage-owner@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'f1100000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'storage-agent@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'f1100000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'storage-member@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'f1100000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'storage-other@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'f1100000-0000-4000-8000-000000000006', 'authenticated', 'authenticated', 'storage-revoked@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', '');

insert into public.agents (id, organization_id, user_id, name, ai, extra) values
  ('f1200000-0000-4000-8000-000000000001', 'f1000000-0000-4000-8000-000000000001', 'f1100000-0000-4000-8000-000000000002', 'Owner', false, '{"role":"owner"}'),
  ('f1200000-0000-4000-8000-000000000002', 'f1000000-0000-4000-8000-000000000001', 'f1100000-0000-4000-8000-000000000003', 'Agent', false, '{"role":"agent"}'),
  ('f1200000-0000-4000-8000-000000000003', 'f1000000-0000-4000-8000-000000000001', 'f1100000-0000-4000-8000-000000000004', 'Member', false, '{"role":"member"}'),
  ('f1200000-0000-4000-8000-000000000004', 'f1000000-0000-4000-8000-000000000002', 'f1100000-0000-4000-8000-000000000005', 'Other Owner', false, '{"role":"owner"}');

insert into public.platform_admins (user_id, active) values
  ('f1100000-0000-4000-8000-000000000001', true),
  ('f1100000-0000-4000-8000-000000000006', false);

select results_eq(
  $$
    select quota_bytes, used_bytes, object_count
    from public.organization_media_storage
    where organization_id = 'f1000000-0000-4000-8000-000000000001'
  $$,
  $$ values (25000000000::bigint, 0::bigint, 0::bigint) $$,
  'new organizations initialize with a 25 GB quota and empty usage'
);

select is(
  (
    select count(*)
    from public.organization_media_storage
    where organization_id in (
      'f1000000-0000-4000-8000-000000000001',
      'f1000000-0000-4000-8000-000000000002',
      'f1000000-0000-4000-8000-000000000003'
    )
  ),
  3::bigint,
  'every new organization receives one storage state row'
);

select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', 'f1100000-0000-4000-8000-000000000002', true);
select results_eq(
  $$
    select quota_bytes, storage_status
    from public.get_organization_media_storage('f1000000-0000-4000-8000-000000000001')
  $$,
  $$ values (25000000000::bigint, 'safe'::text) $$,
  'an accepted Owner can read organization storage'
);
select throws_like(
  $$
    update public.organization_media_storage
    set quota_bytes = 50000000000
    where organization_id = 'f1000000-0000-4000-8000-000000000001'
  $$,
  '%permission denied for table organization_media_storage%',
  'tenant users cannot write storage state directly'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'f1100000-0000-4000-8000-000000000003', true);
select is(
  (
    select quota_bytes
    from public.get_organization_media_storage('f1000000-0000-4000-8000-000000000001')
  ),
  25000000000::bigint,
  'an accepted Agent can read organization storage'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'f1100000-0000-4000-8000-000000000004', true);
select is(
  (
    select quota_bytes
    from public.get_organization_media_storage('f1000000-0000-4000-8000-000000000001')
  ),
  25000000000::bigint,
  'an accepted Member can read organization storage'
);
select throws_ok(
  $$
    select public.get_organization_media_storage(
      'f1000000-0000-4000-8000-000000000002'
    )
  $$,
  '42501',
  'organization access required',
  'tenant storage reads are isolated by organization'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'f1100000-0000-4000-8000-000000000002', true);
select throws_ok(
  $$ select public.list_platform_media_storage_page(1, 10, null, null) $$,
  '42501',
  'platform administrator access required',
  'ordinary tenant users cannot call Platform storage APIs'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'f1100000-0000-4000-8000-000000000001', true);
select results_eq(
  $$
    select organization_name, quota_bytes, storage_status, total_count
    from public.list_platform_media_storage_page(1, 2, 'storage tenant', 'safe')
  $$,
  $$ values
    ('Storage Tenant A'::text, 25000000000::bigint, 'safe'::text, 2::bigint),
    ('Storage Tenant B'::text, 25000000000::bigint, 'safe'::text, 2::bigint)
  $$,
  'Platform list applies search, status, deterministic ordering and total count before pagination'
);
select throws_ok(
  $$ select public.list_platform_media_storage_page(1, 10, null, 'unknown') $$,
  '22023',
  'invalid storage status',
  'unsupported storage status filters are rejected'
);
select throws_ok(
  $$
    select public.update_platform_organization_media_storage_quota(
      'f1000000-0000-4000-8000-000000000001',
      30,
      'f1400000-0000-4000-8000-000000000001'
    )
  $$,
  '22023',
  'invalid media storage quota',
  'only the supported quota sizes are accepted'
);
select results_eq(
  $$
    select quota_bytes, used_bytes
    from public.update_platform_organization_media_storage_quota(
      'f1000000-0000-4000-8000-000000000001',
      25,
      'f1400000-0000-4000-8000-000000000002'
    )
  $$,
  $$ values (25000000000::bigint, 0::bigint) $$,
  'Platform Admin can configure a supported tenant quota'
);
select lives_ok(
  $$
    select public.update_platform_organization_media_storage_quota(
      'f1000000-0000-4000-8000-000000000001',
      25,
      'f1400000-0000-4000-8000-000000000002'
    )
  $$,
  'retrying a quota update with the same request ID succeeds'
);
reset role;

select is(
  (
    select count(*)
    from public.platform_admin_action_events
    where request_id = 'f1400000-0000-4000-8000-000000000002'
  ),
  1::bigint,
  'idempotent quota updates create one audit event'
);
select results_eq(
  $$
    select action_type, before_state->>'quota_bytes', after_state->>'quota_bytes'
    from public.platform_admin_action_events
    where request_id = 'f1400000-0000-4000-8000-000000000002'
  $$,
  $$ values (
    'organization_media_storage.quota_update'::text,
    '25000000000'::text,
    '25000000000'::text
  ) $$,
  'quota audit records the previous and resulting state'
);

insert into storage.objects (bucket_id, name, metadata) values (
  'media',
  'organizations/f1000000-0000-4000-8000-000000000001/attachments/first',
  '{"size":18750000000}'
);

select results_eq(
  $$
    select
      used_bytes,
      object_count,
      round(used_bytes * 100.0 / quota_bytes, 2),
      public.media_storage_status(used_bytes, quota_bytes)
    from public.organization_media_storage
    where organization_id = 'f1000000-0000-4000-8000-000000000001'
  $$,
  $$ values (18750000000::bigint, 1::bigint, 75.00::numeric, 'approaching'::text) $$,
  'a media insert updates usage and reaches Approaching at 75 percent'
);

insert into storage.objects (bucket_id, name, metadata) values (
  'media',
  'organizations/f1000000-0000-4000-8000-000000000001/attachments/second',
  '{"size":3750000000}'
);

select is(
  public.media_storage_status(22500000000, 25000000000),
  'critical'::text,
  'storage becomes Critical at 90 percent'
);

select throws_ok(
  $$
    insert into storage.objects (bucket_id, name, metadata) values (
      'media',
      'organizations/f1000000-0000-4000-8000-000000000001/attachments/overflow',
      '{"size":2500000001}'
    )
  $$,
  '23514',
  'media storage quota exceeded',
  'an object that would exceed the hard quota is rejected'
);

select is(
  (
    select used_bytes
    from public.organization_media_storage
    where organization_id = 'f1000000-0000-4000-8000-000000000001'
  ),
  22500000000::bigint,
  'a rejected upload does not change usage'
);

update storage.objects
set metadata = '{"size":1000000000}'
where bucket_id = 'media'
  and name = 'organizations/f1000000-0000-4000-8000-000000000001/attachments/second';

select results_eq(
  $$
    select used_bytes, object_count
    from public.organization_media_storage
    where organization_id = 'f1000000-0000-4000-8000-000000000001'
  $$,
  $$ values (19750000000::bigint, 2::bigint) $$,
  'a size-changing object replacement applies only the byte delta'
);

select set_config('storage.allow_delete_query', 'true', true);

delete from storage.objects
where bucket_id = 'media'
  and name = 'organizations/f1000000-0000-4000-8000-000000000001/attachments/second';

select set_config('storage.allow_delete_query', 'false', true);

select results_eq(
  $$
    select used_bytes, object_count
    from public.organization_media_storage
    where organization_id = 'f1000000-0000-4000-8000-000000000001'
  $$,
  $$ values (18750000000::bigint, 1::bigint) $$,
  'deleting a media object releases its bytes and object count'
);

insert into storage.buckets (id, name, public)
values ('unmanaged-test', 'unmanaged-test', false)
on conflict (id) do nothing;

select lives_ok(
  $$
    insert into storage.objects (bucket_id, name, metadata) values
      ('unmanaged-test', 'not/a/tenant/object', '{"size":99999999999}'),
      ('media', 'invalid/path', '{"size":99999999999}')
  $$,
  'other buckets and invalid media paths are outside tenant quota enforcement'
);

select is(
  (
    select used_bytes
    from public.organization_media_storage
    where organization_id = 'f1000000-0000-4000-8000-000000000001'
  ),
  18750000000::bigint,
  'unmanaged objects do not affect tenant usage'
);

update public.organization_media_storage
set used_bytes = 1, object_count = 99
where organization_id = 'f1000000-0000-4000-8000-000000000001';

set local role authenticated;
select set_config('request.jwt.claim.sub', 'f1100000-0000-4000-8000-000000000001', true);
select results_eq(
  $$
    select used_bytes, object_count
    from public.reconcile_platform_organization_media_storage(
      'f1000000-0000-4000-8000-000000000001',
      'f1400000-0000-4000-8000-000000000003'
    )
  $$,
  $$ values (18750000000::bigint, 1::bigint) $$,
  'manual reconciliation repairs drift from authoritative storage metadata'
);
reset role;

select ok(
  (
    select last_reconciled_at is not null
    from public.organization_media_storage
    where organization_id = 'f1000000-0000-4000-8000-000000000001'
  ),
  'reconciliation records its completion time'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'f1100000-0000-4000-8000-000000000001', true);
select lives_ok(
  $$
    select public.update_platform_organization_media_storage_quota(
      'f1000000-0000-4000-8000-000000000002',
      100,
      'f1400000-0000-4000-8000-000000000004'
    )
  $$,
  'Platform Admin raises a tenant quota before a large upload'
);
reset role;

insert into storage.objects (bucket_id, name, metadata) values (
  'media',
  'organizations/f1000000-0000-4000-8000-000000000002/attachments/large',
  '{"size":60000000000}'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'f1100000-0000-4000-8000-000000000001', true);
select results_eq(
  $$
    select quota_bytes, used_bytes, storage_status
    from public.update_platform_organization_media_storage_quota(
      'f1000000-0000-4000-8000-000000000002',
      25,
      'f1400000-0000-4000-8000-000000000005'
    )
  $$,
  $$ values (25000000000::bigint, 60000000000::bigint, 'critical'::text) $$,
  'quota may be lowered below current usage and reports Critical'
);
reset role;

select throws_ok(
  $$
    insert into storage.objects (bucket_id, name, metadata) values (
      'media',
      'organizations/f1000000-0000-4000-8000-000000000002/attachments/blocked',
      '{"size":1}'
    )
  $$,
  '23514',
  'media storage quota exceeded',
  'an over-quota tenant cannot add more media'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'f1100000-0000-4000-8000-000000000006', true);
select throws_ok(
  $$
    select public.get_platform_organization_media_storage(
      'f1000000-0000-4000-8000-000000000001'
    )
  $$,
  '42501',
  'platform administrator access required',
  'revoked Platform Admin cannot inspect tenant storage'
);
select throws_like(
  $$ select public.reconcile_organization_media_storage_batch(1) $$,
  '%permission denied for function reconcile_organization_media_storage_batch%',
  'authenticated users cannot run the scheduled reconciliation function'
);
reset role;

select * from finish();
rollback;
