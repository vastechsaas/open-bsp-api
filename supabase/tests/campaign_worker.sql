begin;

create extension if not exists pgtap with schema extensions;

set local search_path = extensions, public, auth;

select plan(25);

insert into public.organizations (id, name, extra)
values (
  '14000000-0000-4000-8000-000000000001',
  'Campaign Worker Test Org',
  '{}'
);

insert into public.organizations_addresses (
  organization_id,
  service,
  address,
  status,
  extra
)
values (
  '14000000-0000-4000-8000-000000000001',
  'whatsapp',
  'worker-phone-id',
  'connected',
  '{"access_token":"test-token"}'
);

insert into public.campaigns (
  organization_id,
  id,
  name,
  organization_address,
  template,
  template_variable_mapping,
  audience_type,
  status,
  queued_count,
  processing_count,
  accepted_count,
  failed_count,
  created_at
)
values
  (
    '14000000-0000-4000-8000-000000000001',
    '64000000-0000-4000-8000-000000000001',
    'Batch campaign',
    'worker-phone-id',
    '{"id":"template-1","name":"worker_test","language":"en_US","status":"APPROVED","components":[]}',
    '{}',
    'all_contacts',
    'queued',
    30,
    0,
    0,
    0,
    '2026-01-01 00:00:00+00'
  ),
  (
    '14000000-0000-4000-8000-000000000001',
    '64000000-0000-4000-8000-000000000002',
    'Completion campaign',
    'worker-phone-id',
    '{"id":"template-1","name":"worker_test","language":"en_US","status":"APPROVED","components":[]}',
    '{}',
    'all_contacts',
    'running',
    0,
    1,
    0,
    0,
    '2026-01-02 00:00:00+00'
  ),
  (
    '14000000-0000-4000-8000-000000000001',
    '64000000-0000-4000-8000-000000000003',
    'Permanent failure campaign',
    'worker-phone-id',
    '{"id":"template-1","name":"worker_test","language":"en_US","status":"APPROVED","components":[]}',
    '{}',
    'all_contacts',
    'running',
    0,
    1,
    0,
    0,
    '2026-01-03 00:00:00+00'
  );

insert into public.campaign_deliveries (
  organization_id,
  campaign_id,
  id,
  contact_address,
  name,
  status,
  attempts
)
values
  (
    '14000000-0000-4000-8000-000000000001',
    '64000000-0000-4000-8000-000000000001',
    '74000000-0000-4000-8000-000000000001',
    '15551110001',
    'Recipient 1',
    'queued',
    0
  ),
  (
    '14000000-0000-4000-8000-000000000001',
    '64000000-0000-4000-8000-000000000001',
    '74000000-0000-4000-8000-000000000002',
    '15551110002',
    'Recipient 2',
    'queued',
    0
  ),
  (
    '14000000-0000-4000-8000-000000000001',
    '64000000-0000-4000-8000-000000000002',
    '74000000-0000-4000-8000-000000000100',
    '15551110100',
    'Completion recipient',
    'processing',
    1
  ),
  (
    '14000000-0000-4000-8000-000000000001',
    '64000000-0000-4000-8000-000000000003',
    '74000000-0000-4000-8000-000000000200',
    '15551110200',
    'Permanent failure recipient',
    'processing',
    1
  );

insert into public.campaign_deliveries (
  organization_id,
  campaign_id,
  contact_address,
  name,
  status,
  attempts
)
select
  '14000000-0000-4000-8000-000000000001',
  '64000000-0000-4000-8000-000000000001',
  '1555111' || lpad(series::text, 4, '0'),
  'Recipient ' || series,
  'queued',
  0
from generate_series(3, 30) as series;

select ok(
  not has_function_privilege(
    'authenticated',
    'public.claim_campaign_deliveries(integer)',
    'execute'
  ),
  'authenticated users cannot claim campaign deliveries'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.record_campaign_delivery_result(uuid,text,jsonb,boolean)',
    'execute'
  ),
  'authenticated users cannot record campaign delivery results'
);

set local role service_role;

select is(
  (select count(*) from public.claim_campaign_deliveries(25)),
  25::bigint,
  'the worker claims at most 25 recipients in one batch'
);

select results_eq(
  $$
    select status, queued_count, processing_count
    from public.campaigns
    where id = '64000000-0000-4000-8000-000000000001'
  $$,
  $$ values ('running'::text, 5, 25) $$,
  'claiming moves campaign counters from queued to processing'
);

select is(
  (select count(*) from public.claim_campaign_deliveries(25)),
  5::bigint,
  'the next batch claims only the remaining recipients'
);

select is(
  (
    select count(distinct id)
    from public.campaign_deliveries
    where campaign_id = '64000000-0000-4000-8000-000000000001'
      and status = 'processing'
  ),
  30::bigint,
  'each queued recipient is claimed exactly once'
);

select is(
  (
    select min(attempts)
    from public.campaign_deliveries
    where campaign_id = '64000000-0000-4000-8000-000000000001'
  ),
  1,
  'claiming increments the delivery attempt count'
);

select is(
  public.record_campaign_delivery_result(
    '74000000-0000-4000-8000-000000000001',
    'wamid.accepted-1',
    null,
    false
  ),
  'accepted',
  'an accepted Meta response is recorded'
);

select results_eq(
  $$
    select status, external_id
    from public.campaign_deliveries
    where id = '74000000-0000-4000-8000-000000000001'
  $$,
  $$ values ('accepted'::text, 'wamid.accepted-1'::text) $$,
  'accepted deliveries retain their Meta message ID'
);

select results_eq(
  $$
    select queued_count, processing_count, accepted_count, failed_count
    from public.campaigns
    where id = '64000000-0000-4000-8000-000000000001'
  $$,
  $$ values (0, 29, 1, 0) $$,
  'accepted results update campaign counters'
);

select is(
  public.record_campaign_delivery_result(
    '74000000-0000-4000-8000-000000000002',
    null,
    '{"error":{"code":130429}}',
    true
  ),
  'queued',
  'a transient first failure is requeued'
);

select results_eq(
  $$
    select queued_count, processing_count, accepted_count, failed_count
    from public.campaigns
    where id = '64000000-0000-4000-8000-000000000001'
  $$,
  $$ values (1, 28, 1, 0) $$,
  'requeued results update campaign counters'
);

select is(
  (select count(*) from public.claim_campaign_deliveries(1)),
  1::bigint,
  'a requeued delivery can be claimed for its second attempt'
);

select is(
  (
    select attempts
    from public.campaign_deliveries
    where id = '74000000-0000-4000-8000-000000000002'
  ),
  2,
  'the second claim increments attempts to two'
);

select is(
  public.record_campaign_delivery_result(
    '74000000-0000-4000-8000-000000000002',
    null,
    '{"error":{"code":130429}}',
    true
  ),
  'queued',
  'a transient second failure is requeued'
);

select is(
  (select count(*) from public.claim_campaign_deliveries(1)),
  1::bigint,
  'the delivery can be claimed for its final attempt'
);

select is(
  (
    select attempts
    from public.campaign_deliveries
    where id = '74000000-0000-4000-8000-000000000002'
  ),
  3,
  'the final claim increments attempts to three'
);

select is(
  public.record_campaign_delivery_result(
    '74000000-0000-4000-8000-000000000002',
    null,
    '{"error":{"code":130429}}',
    true
  ),
  'failed',
  'a transient failure becomes permanent after three attempts'
);

select results_eq(
  $$
    select status, attempts, error
    from public.campaign_deliveries
    where id = '74000000-0000-4000-8000-000000000002'
  $$,
  $$
    values (
      'failed'::text,
      3,
      '{"error":{"code":130429}}'::jsonb
    )
  $$,
  'the exhausted delivery retains its attempts and final error'
);

select results_eq(
  $$
    select queued_count, processing_count, accepted_count, failed_count
    from public.campaigns
    where id = '64000000-0000-4000-8000-000000000001'
  $$,
  $$ values (0, 28, 1, 1) $$,
  'failed results update campaign counters'
);

select is(
  public.record_campaign_delivery_result(
    '74000000-0000-4000-8000-000000000100',
    'wamid.completion-1',
    null,
    false
  ),
  'accepted',
  'the final processing recipient can be accepted'
);

select results_eq(
  $$
    select status, queued_count, processing_count, accepted_count, failed_count
    from public.campaigns
    where id = '64000000-0000-4000-8000-000000000002'
  $$,
  $$ values ('completed'::text, 0, 0, 1, 0) $$,
  'a campaign completes when queued and processing counts reach zero'
);

select throws_ok(
  $$
    select public.record_campaign_delivery_result(
      '74000000-0000-4000-8000-000000000100',
      'wamid.duplicate',
      null,
      false
    )
  $$,
  '23514',
  'campaign delivery is not processing',
  'a completed delivery cannot be recorded twice'
);

select is(
  public.record_campaign_delivery_result(
    '74000000-0000-4000-8000-000000000200',
    null,
    '{"error":{"code":132000}}',
    false
  ),
  'failed',
  'a permanent Meta error fails immediately without retrying'
);

select results_eq(
  $$
    select status, queued_count, processing_count, accepted_count, failed_count
    from public.campaigns
    where id = '64000000-0000-4000-8000-000000000003'
  $$,
  $$ values ('completed'::text, 0, 0, 0, 1) $$,
  'a permanently failed final recipient completes the campaign'
);

select * from finish();

rollback;
