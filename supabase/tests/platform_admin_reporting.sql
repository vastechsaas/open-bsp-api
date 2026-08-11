begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;

select plan(20);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at,
  created_at, updated_at, confirmation_token, recovery_token,
  email_change_token_new, email_change
) values
  (
    '00000000-0000-0000-0000-000000000000',
    '22000000-0000-4000-8000-000000000001',
    'authenticated', 'authenticated', 'report-admin@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}', '{}',
    now(), now(), now(), '', '', '', ''
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '22000000-0000-4000-8000-000000000002',
    'authenticated', 'authenticated', 'report-user@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}', '{}',
    now(), now(), now(), '', '', '', ''
  );

insert into public.organizations (id, name, extra)
values
  ('12000000-0000-4000-8000-000000000001', 'Report Alpha', '{}'),
  ('12000000-0000-4000-8000-000000000002', 'Report Beta', '{}');

insert into public.platform_admins (user_id, active)
values ('22000000-0000-4000-8000-000000000001', true);

insert into public.agents (
  id, organization_id, user_id, name, ai, extra
) values
  (
    '32000000-0000-4000-8000-000000000001',
    '12000000-0000-4000-8000-000000000001',
    '22000000-0000-4000-8000-000000000002',
    'Assigned Agent', false, '{"role":"agent"}'
  );

insert into public.organizations_addresses (
  organization_id, service, address, status, extra
) values
  (
    '12000000-0000-4000-8000-000000000001',
    'whatsapp', 'report-alpha-wa', 'connected', '{}'
  ),
  (
    '12000000-0000-4000-8000-000000000002',
    'whatsapp', 'report-beta-wa', 'connected', '{}'
  );

insert into public.contacts (id, organization_id, name)
values
  (
    '42000000-0000-4000-8000-000000000001',
    '12000000-0000-4000-8000-000000000001',
    'Alpha Customer'
  ),
  (
    '42000000-0000-4000-8000-000000000002',
    '12000000-0000-4000-8000-000000000002',
    'Beta Customer'
  );

insert into public.contacts_addresses (
  organization_id, contact_id, service, address, status
) values
  (
    '12000000-0000-4000-8000-000000000001',
    '42000000-0000-4000-8000-000000000001',
    'whatsapp', '923001111111', 'active'
  ),
  (
    '12000000-0000-4000-8000-000000000002',
    '42000000-0000-4000-8000-000000000002',
    'whatsapp', '923002222222', 'active'
  );

insert into public.conversations (
  id, organization_id, service, organization_address, contact_address,
  assigned_agent_id, status, created_at
) values
  (
    '52000000-0000-4000-8000-000000000001',
    '12000000-0000-4000-8000-000000000001',
    'whatsapp', 'report-alpha-wa', '923001111111',
    '32000000-0000-4000-8000-000000000001', 'closed',
    '2026-06-01 00:00:00+00'
  ),
  (
    '52000000-0000-4000-8000-000000000002',
    '12000000-0000-4000-8000-000000000001',
    'whatsapp', 'report-alpha-wa', '923001111111', null, 'active',
    '2026-07-01 00:00:00+00'
  ),
  (
    '52000000-0000-4000-8000-000000000003',
    '12000000-0000-4000-8000-000000000002',
    'whatsapp', 'report-beta-wa', '923002222222', null, 'active',
    '2026-07-01 00:00:00+00'
  );

insert into public.messages (
  organization_id, conversation_id, id, direction, agent_id,
  contact_address, service, organization_address, content, status, timestamp
) values
  (
    '12000000-0000-4000-8000-000000000001',
    '52000000-0000-4000-8000-000000000001',
    '62000000-0000-4000-8000-000000000001',
    'incoming', null, '923001111111', 'whatsapp', 'report-alpha-wa',
    '{"version":"1","type":"text","kind":"message","text":"first"}',
    '{}', '2026-07-01 00:00:00+00'
  ),
  (
    '12000000-0000-4000-8000-000000000001',
    '52000000-0000-4000-8000-000000000001',
    '62000000-0000-4000-8000-000000000002',
    'outgoing', '32000000-0000-4000-8000-000000000001', null,
    'whatsapp', 'report-alpha-wa',
    '{"version":"1","type":"text","kind":"message","text":"last"}',
    '{}', '2026-07-31 23:59:59+00'
  ),
  (
    '12000000-0000-4000-8000-000000000001',
    '52000000-0000-4000-8000-000000000001',
    '62000000-0000-4000-8000-000000000003',
    'incoming', null, '923001111111', 'whatsapp', 'report-alpha-wa',
    '{"version":"1","type":"text","kind":"message","text":"august"}',
    '{}', '2026-08-01 00:00:00+00'
  ),
  (
    '12000000-0000-4000-8000-000000000001',
    '52000000-0000-4000-8000-000000000002',
    '62000000-0000-4000-8000-000000000004',
    'internal', '32000000-0000-4000-8000-000000000001', null,
    'whatsapp', 'report-alpha-wa',
    '{"version":"1","type":"text","kind":"private_note","text":"note"}',
    '{}', '2026-07-15 00:00:00+00'
  ),
  (
    '12000000-0000-4000-8000-000000000002',
    '52000000-0000-4000-8000-000000000003',
    '62000000-0000-4000-8000-000000000005',
    'incoming', null, '923002222222', 'whatsapp', 'report-beta-wa',
    '{"version":"1","type":"text","kind":"message","text":"beta"}',
    '{}', '2026-07-10 00:00:00+00'
  );

insert into public.campaigns (
  id, organization_id, created_by, name, organization_address, template,
  audience_type, status
) values
  (
    '72000000-0000-4000-8000-000000000001',
    '12000000-0000-4000-8000-000000000001',
    '32000000-0000-4000-8000-000000000001',
    'July Campaign', 'report-alpha-wa',
    '{"id":"tpl-1","name":"welcome","language":"en","status":"APPROVED"}',
    'all_contacts', 'completed'
  ),
  (
    '72000000-0000-4000-8000-000000000002',
    '12000000-0000-4000-8000-000000000001',
    '32000000-0000-4000-8000-000000000001',
    'Draft Campaign', 'report-alpha-wa',
    '{"id":"tpl-2","name":"draft","language":"en","status":"APPROVED"}',
    'all_contacts', 'draft'
  ),
  (
    '72000000-0000-4000-8000-000000000003',
    '12000000-0000-4000-8000-000000000001',
    '32000000-0000-4000-8000-000000000001',
    'August Campaign', 'report-alpha-wa',
    '{"id":"tpl-3","name":"later","language":"en","status":"APPROVED"}',
    'all_contacts', 'completed'
  );

insert into public.campaign_deliveries (
  organization_id, campaign_id, contact_address, status, attempts, created_at
) values
  (
    '12000000-0000-4000-8000-000000000001',
    '72000000-0000-4000-8000-000000000001',
    '923001111111', 'accepted', 1, '2026-07-05 10:00:00+00'
  ),
  (
    '12000000-0000-4000-8000-000000000001',
    '72000000-0000-4000-8000-000000000001',
    '923001111112', 'failed', 3, '2026-07-05 10:00:01+00'
  ),
  (
    '12000000-0000-4000-8000-000000000001',
    '72000000-0000-4000-8000-000000000003',
    '923001111113', 'accepted', 1, '2026-08-01 00:00:00+00'
  );

select ok(
  not has_table_privilege(
    'authenticated', 'public.platform_report_export_events', 'SELECT'
  ),
  'authenticated users cannot read report audit storage directly'
);

select ok(
  not has_table_privilege(
    'authenticated', 'public.platform_report_export_events', 'INSERT'
  ),
  'authenticated users cannot write report audit storage directly'
);

select set_config(
  'request.jwt.claim.sub',
  '22000000-0000-4000-8000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth;

select is(
  (
    select count(*)
    from public.list_platform_conversation_report_rows(
      '12000000-0000-4000-8000-000000000001', '2026-07-01', 1, 10
    )
  ),
  1::bigint,
  'conversation report includes one externally active conversation'
);

select results_eq(
  $$
    select
      organization_name, customer_name, contact_address,
      conversation_status, assigned_agent_name,
      incoming_message_count, outgoing_message_count, total_message_count
    from public.list_platform_conversation_report_rows(
      '12000000-0000-4000-8000-000000000001', '2026-07-01', 1, 10
    )
  $$,
  $$
    values (
      'Report Alpha'::text, 'Alpha Customer'::text, '923001111111'::text,
      'closed'::text, 'Assigned Agent'::text,
      1::bigint, 1::bigint, 2::bigint
    )
  $$,
  'conversation report returns identity, live state, assignment, and counts'
);

select results_eq(
  $$
    select first_activity_at_utc, last_activity_at_utc
    from public.list_platform_conversation_report_rows(
      '12000000-0000-4000-8000-000000000001', '2026-07-01', 1, 10
    )
  $$,
  $$
    values (
      '2026-07-01 00:00:00+00'::timestamptz,
      '2026-07-31 23:59:59+00'::timestamptz
    )
  $$,
  'conversation report uses exact inclusive-start exclusive-end UTC boundaries'
);

select is(
  (
    select count(*)
    from public.list_platform_conversation_report_rows(
      '12000000-0000-4000-8000-000000000001', '2026-06-01', 1, 10
    )
  ),
  0::bigint,
  'conversation report excludes activity outside the selected month'
);

select is(
  (
    select count(*)
    from public.list_platform_conversation_report_rows(
      '12000000-0000-4000-8000-000000000001', '2026-07-01', 2, 1
    )
  ),
  0::bigint,
  'conversation report pagination is deterministic'
);

select results_eq(
  $$
    select
      campaign_name, template_name, created_by_agent_name,
      queued_count, processing_count, accepted_count, failed_count,
      total_recipient_count
    from public.list_platform_campaign_report_rows(
      '12000000-0000-4000-8000-000000000001', '2026-07-01', 1, 10
    )
  $$,
  $$
    values (
      'July Campaign'::text, 'welcome'::text, 'Assigned Agent'::text,
      0::bigint, 0::bigint, 1::bigint, 1::bigint, 2::bigint
    )
  $$,
  'campaign report uses launched delivery rows and current delivery counts'
);

select is(
  (
    select count(*)
    from public.list_platform_campaign_report_rows(
      '12000000-0000-4000-8000-000000000001', '2026-07-01', 1, 10
    )
    where campaign_name = 'Draft Campaign'
  ),
  0::bigint,
  'campaign report excludes drafts without a delivery snapshot'
);

select is(
  (
    select count(*)
    from public.list_platform_campaign_report_rows(
      '12000000-0000-4000-8000-000000000001', '2026-08-01', 1, 10
    )
  ),
  1::bigint,
  'campaign report isolates the selected month'
);

select throws_ok(
  $$
    select * from public.list_platform_conversation_report_rows(
      '12000000-0000-4000-8000-000000000001', '2026-07-02', 1, 10
    )
  $$,
  '22023',
  'report month must be the first day of a calendar month',
  'report RPC rejects a non-month-start date'
);

select ok(
  public.record_platform_report_export(
    '12000000-0000-4000-8000-000000000001',
    'conversations', '2026-07-01',
    '82000000-0000-4000-8000-000000000001', 1
  ) is not null,
  'successful exports create an audit event'
);

select is(
  public.record_platform_report_export(
    '12000000-0000-4000-8000-000000000001',
    'conversations', '2026-07-01',
    '82000000-0000-4000-8000-000000000001', 1
  ),
  public.record_platform_report_export(
    '12000000-0000-4000-8000-000000000001',
    'conversations', '2026-07-01',
    '82000000-0000-4000-8000-000000000001', 1
  ),
  'report export auditing is idempotent'
);

select throws_ok(
  $$
    select public.record_platform_report_export(
      '12000000-0000-4000-8000-000000000001',
      'campaigns', '2026-07-01',
      '82000000-0000-4000-8000-000000000001', 1
    )
  $$,
  '22023',
  'request id was already used for a different report export',
  'an audit request id cannot be reused for another report'
);

reset role;

select is(
  (
    select count(*)
    from public.platform_report_export_events
    where request_id = '82000000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'idempotent audit requests store one row'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '22000000-0000-4000-8000-000000000002',
  true
);

select throws_ok(
  $$
    select * from public.list_platform_conversation_report_rows(
      '12000000-0000-4000-8000-000000000001', '2026-07-01', 1, 10
    )
  $$,
  '42501',
  'platform administrator access required',
  'ordinary tenant users cannot export conversation reports'
);

select throws_ok(
  $$
    select * from public.list_platform_campaign_report_rows(
      '12000000-0000-4000-8000-000000000001', '2026-07-01', 1, 10
    )
  $$,
  '42501',
  'platform administrator access required',
  'ordinary tenant users cannot export campaign reports'
);

select throws_ok(
  $$
    select public.record_platform_report_export(
      '12000000-0000-4000-8000-000000000001',
      'conversations', '2026-07-01',
      '82000000-0000-4000-8000-000000000002', 1
    )
  $$,
  '42501',
  'platform administrator access required',
  'ordinary tenant users cannot record report exports'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.list_platform_conversation_report_rows(uuid,date,integer,integer)',
    'EXECUTE'
  ),
  'anonymous callers cannot execute conversation report RPCs'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.list_platform_campaign_report_rows(uuid,date,integer,integer)',
    'EXECUTE'
  ),
  'anonymous callers cannot execute campaign report RPCs'
);

select * from finish();
rollback;
