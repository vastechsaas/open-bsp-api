begin;

create extension if not exists pgtap with schema extensions;

set local search_path = extensions, public, auth;

select plan(20);

insert into public.organizations (id, name, extra)
values
  ('15000000-0000-4000-8000-000000000001', 'Template Org A', '{}'),
  ('15000000-0000-4000-8000-000000000002', 'Template Org B', '{}');

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
    '25000000-0000-4000-8000-000000000001',
    'authenticated',
    'authenticated',
    'template-admin-a@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Template Admin A"}',
    now(),
    now(),
    now(),
    '',
    '',
    '',
    ''
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '25000000-0000-4000-8000-000000000002',
    'authenticated',
    'authenticated',
    'template-admin-b@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Template Admin B"}',
    now(),
    now(),
    now(),
    '',
    '',
    '',
    ''
  );

insert into public.agents (id, organization_id, user_id, name, ai, extra)
values
  (
    '35000000-0000-4000-8000-000000000001',
    '15000000-0000-4000-8000-000000000001',
    '25000000-0000-4000-8000-000000000001',
    'Template Admin A',
    false,
    '{"role":"admin"}'
  ),
  (
    '35000000-0000-4000-8000-000000000002',
    '15000000-0000-4000-8000-000000000002',
    '25000000-0000-4000-8000-000000000002',
    'Template Admin B',
    false,
    '{"role":"admin"}'
  );

insert into public.organizations_addresses (
  organization_id,
  service,
  address,
  status,
  extra
)
values
  (
    '15000000-0000-4000-8000-000000000001',
    'whatsapp',
    'template-org-a-main',
    'connected',
    '{}'
  ),
  (
    '15000000-0000-4000-8000-000000000001',
    'whatsapp',
    'template-org-a-other',
    'connected',
    '{}'
  ),
  (
    '15000000-0000-4000-8000-000000000001',
    'instagram',
    'template-org-a-instagram',
    'connected',
    '{}'
  ),
  (
    '15000000-0000-4000-8000-000000000002',
    'whatsapp',
    'template-org-b-main',
    'connected',
    '{}'
  );

insert into public.message_templates (
  organization_id,
  id,
  organization_address,
  created_by,
  external_id,
  name,
  language,
  category,
  status,
  components,
  updated_at
)
values
  (
    '15000000-0000-4000-8000-000000000001',
    '65000000-0000-4000-8000-000000000001',
    'template-org-a-main',
    '35000000-0000-4000-8000-000000000001',
    null,
    'alpha_draft',
    'en_US',
    'utility',
    'draft',
    '[]',
    '2026-01-01 00:00:00+00'
  ),
  (
    '15000000-0000-4000-8000-000000000001',
    '65000000-0000-4000-8000-000000000002',
    'template-org-a-main',
    '35000000-0000-4000-8000-000000000001',
    'meta-template-2',
    'order_update',
    'en_US',
    'utility',
    'approved',
    '[{"type":"BODY","text":"Order {{1}} is ready","example":{"body_text":[["123"]]}}]',
    '2026-01-04 00:00:00+00'
  ),
  (
    '15000000-0000-4000-8000-000000000001',
    '65000000-0000-4000-8000-000000000003',
    'template-org-a-other',
    null,
    'meta-template-3',
    'summer_offer',
    'en_US',
    'marketing',
    'pending',
    '[{"type":"BODY","text":"Summer offer"}]',
    '2026-01-03 00:00:00+00'
  ),
  (
    '15000000-0000-4000-8000-000000000001',
    '65000000-0000-4000-8000-000000000004',
    'template-org-a-main',
    null,
    'meta-template-4',
    'login_code',
    'en_US',
    'authentication',
    'rejected',
    '[{"type":"BODY","text":"Your login code is {{1}}"}]',
    '2026-01-02 00:00:00+00'
  ),
  (
    '15000000-0000-4000-8000-000000000002',
    '65000000-0000-4000-8000-000000000005',
    'template-org-b-main',
    '35000000-0000-4000-8000-000000000002',
    'meta-template-5',
    'other_org_template',
    'en_US',
    'utility',
    'approved',
    '[{"type":"BODY","text":"Other organization"}]',
    '2026-01-05 00:00:00+00'
  );

select throws_ok(
  $$
    insert into public.message_templates (
      organization_id,
      organization_address,
      name,
      language,
      category
    ) values (
      '15000000-0000-4000-8000-000000000001',
      'template-org-a-instagram',
      'wrong_service',
      'en_US',
      'utility'
    )
  $$,
  '23514',
  'Template account must be a WhatsApp address in the same organization',
  'templates require a WhatsApp account in the same organization'
);

select throws_ok(
  $$
    insert into public.message_templates (
      organization_id,
      organization_address,
      created_by,
      name,
      language,
      category
    ) values (
      '15000000-0000-4000-8000-000000000001',
      'template-org-a-main',
      '35000000-0000-4000-8000-000000000002',
      'wrong_creator',
      'en_US',
      'utility'
    )
  $$,
  '23514',
  'Template creator must belong to the template organization',
  'template creators cannot cross organization boundaries'
);

select throws_ok(
  $$
    insert into public.message_templates (
      organization_id,
      organization_address,
      external_id,
      name,
      language,
      category,
      status
    ) values (
      '15000000-0000-4000-8000-000000000001',
      'template-org-a-main',
      null,
      'invalid_remote_state',
      'en_US',
      'utility',
      'approved'
    )
  $$,
  '23514',
  'new row for relation "message_templates" violates check constraint "message_templates_external_state_check"',
  'submitted template states require a Meta template ID'
);

select set_config(
  'request.jwt.claim.sub',
  '25000000-0000-4000-8000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth;

select is(
  (select count(*)::integer from public.message_templates),
  4,
  'RLS exposes only templates from the authenticated organization'
);

select results_eq(
  $$
    select count(*)::integer, max(total_count)::integer
    from public.list_message_templates_page(
      '15000000-0000-4000-8000-000000000001',
      1,
      2
    )
  $$,
  $$ values (2, 4) $$,
  'template listing returns one requested page and the full total'
);

select results_eq(
  $$
    select name
    from public.list_message_templates_page(
      '15000000-0000-4000-8000-000000000001',
      p_search => 'ORDER_UPDATE'
    )
  $$,
  $$ values ('order_update'::text) $$,
  'template listing searches template names case-insensitively'
);

select results_eq(
  $$
    select count(*)::integer, max(total_count)::integer
    from public.list_message_templates_page(
      '15000000-0000-4000-8000-000000000001',
      p_organization_address => 'template-org-a-main'
    )
  $$,
  $$ values (3, 3) $$,
  'template listing filters by WhatsApp account before pagination'
);

select results_eq(
  $$
    select name, status
    from public.list_message_templates_page(
      '15000000-0000-4000-8000-000000000001',
      p_category => 'marketing'
    )
  $$,
  $$ values ('summer_offer'::text, 'pending'::text) $$,
  'template listing filters by category'
);

select results_eq(
  $$
    select name
    from public.list_message_templates_page(
      '15000000-0000-4000-8000-000000000001',
      p_status => 'draft'
    )
  $$,
  $$ values ('alpha_draft'::text) $$,
  'template listing filters by status'
);

select results_eq(
  $$
    select name
    from public.list_message_templates_page(
      '15000000-0000-4000-8000-000000000001',
      p_page_size => 10
    )
  $$,
  $$
    values
      ('order_update'::text),
      ('summer_offer'::text),
      ('login_code'::text),
      ('alpha_draft'::text)
  $$,
  'template listing uses deterministic updated ordering'
);

select throws_ok(
  $$
    select *
    from public.list_message_templates_page(
      '15000000-0000-4000-8000-000000000001',
      p_category => 'service'
    )
  $$,
  '22023',
  'template category filter is invalid',
  'template listing rejects unknown categories'
);

select throws_ok(
  $$
    select *
    from public.list_message_templates_page(
      '15000000-0000-4000-8000-000000000001',
      p_status => 'quality_pending'
    )
  $$,
  '22023',
  'template status filter is invalid',
  'template listing rejects unknown statuses'
);

select throws_ok(
  $$
    select *
    from public.list_message_templates_page(
      '15000000-0000-4000-8000-000000000002'
    )
  $$,
  '42501',
  'organization is not accessible to the authenticated user',
  'template listing denies inaccessible organizations'
);

update public.message_templates
set status = 'deleted'
where name = 'login_code';

select is(
  (
    select count(*)::integer
    from public.list_message_templates_page(
      '15000000-0000-4000-8000-000000000001'
    )
  ),
  3,
  'deleted templates are hidden from the default listing'
);

select results_eq(
  $$
    select name
    from public.list_message_templates_page(
      '15000000-0000-4000-8000-000000000001',
      p_status => 'deleted'
    )
  $$,
  $$ values ('login_code'::text) $$,
  'deleted templates remain queryable for audit'
);

select lives_ok(
  $$
    insert into public.message_templates (
      organization_id,
      organization_address,
      created_by,
      name,
      language,
      category,
      components
    ) values (
      '15000000-0000-4000-8000-000000000001',
      'template-org-a-main',
      '35000000-0000-4000-8000-000000000001',
      'admin_draft',
      'en_US',
      'utility',
      '[]'
    )
  $$,
  'organization admins can create template drafts'
);

select is(
  (
    select count(*)::integer
    from public.message_templates
    where name = 'admin_draft'
  ),
  1,
  'the authenticated admin can read the created draft'
);

select throws_ok(
  $$
    insert into public.message_templates (
      organization_id,
      organization_address,
      name,
      language,
      category,
      components
    ) values (
      '15000000-0000-4000-8000-000000000002',
      'template-org-b-main',
      'unauthorized_draft',
      'en_US',
      'utility',
      '[]'
    )
  $$,
  '23514',
  'Template account must be a WhatsApp address in the same organization',
  'RLS prevents admins from creating drafts in another organization'
);

select lives_ok(
  $$
    update public.message_templates
    set components = '[{"type":"BODY","text":"Saved body"}]'
    where name = 'admin_draft'
  $$,
  'organization admins can update their template drafts'
);

select lives_ok(
  $$
    delete from public.message_templates
    where name = 'admin_draft'
  $$,
  'organization admins can delete their template drafts'
);

select * from finish();

rollback;
