begin;

create extension if not exists pgtap with schema extensions;

set local search_path = extensions, public, auth;

select plan(16);

insert into public.organizations (id, name, extra)
values
  (
    '13000000-0000-4000-8000-000000000001',
    'Campaign Test Org A',
    '{}'
  ),
  (
    '13000000-0000-4000-8000-000000000002',
    'Campaign Test Org B',
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
values
  (
    '00000000-0000-0000-0000-000000000000',
    '23000000-0000-4000-8000-000000000001',
    'authenticated',
    'authenticated',
    'campaign-user-a@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Campaign User A"}',
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
    '23000000-0000-4000-8000-000000000002',
    'authenticated',
    'authenticated',
    'campaign-user-b@example.test',
    crypt('password', gen_salt('bf')),
    '{"provider":"email","providers":["email"]}',
    '{"name":"Campaign User B"}',
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
    '33000000-0000-4000-8000-000000000001',
    '13000000-0000-4000-8000-000000000001',
    '23000000-0000-4000-8000-000000000001',
    'Campaign Agent A',
    false,
    '{"role":"member"}'
  ),
  (
    '33000000-0000-4000-8000-000000000002',
    '13000000-0000-4000-8000-000000000002',
    '23000000-0000-4000-8000-000000000002',
    'Campaign Agent B',
    false,
    '{"role":"member"}'
  );

insert into public.organizations_addresses (
  organization_id,
  service,
  address,
  extra,
  status
)
values
  (
    '13000000-0000-4000-8000-000000000001',
    'whatsapp',
    'campaign-org-a-main',
    '{}',
    'connected'
  ),
  (
    '13000000-0000-4000-8000-000000000001',
    'whatsapp',
    'campaign-org-a-other',
    '{}',
    'connected'
  ),
  (
    '13000000-0000-4000-8000-000000000001',
    'instagram',
    'campaign-org-a-instagram',
    '{}',
    'connected'
  ),
  (
    '13000000-0000-4000-8000-000000000002',
    'whatsapp',
    'campaign-org-b-main',
    '{}',
    'connected'
  );

insert into public.contacts (id, organization_id, name, status)
values
  (
    '43000000-0000-4000-8000-000000000001',
    '13000000-0000-4000-8000-000000000001',
    'Fresh Contact',
    'active'
  ),
  (
    '43000000-0000-4000-8000-000000000002',
    '13000000-0000-4000-8000-000000000001',
    'Old Contact',
    'active'
  ),
  (
    '43000000-0000-4000-8000-000000000003',
    '13000000-0000-4000-8000-000000000001',
    'Inactive Contact',
    'inactive'
  ),
  (
    '43000000-0000-4000-8000-000000000004',
    '13000000-0000-4000-8000-000000000002',
    'Other Org Contact',
    'active'
  );

insert into public.contacts_addresses (
  organization_id,
  contact_id,
  service,
  address,
  extra,
  status
)
values
  (
    '13000000-0000-4000-8000-000000000001',
    '43000000-0000-4000-8000-000000000001',
    'whatsapp',
    '15550000001',
    '{}',
    'active'
  ),
  (
    '13000000-0000-4000-8000-000000000001',
    '43000000-0000-4000-8000-000000000002',
    'whatsapp',
    '15550000002',
    '{}',
    'active'
  ),
  (
    '13000000-0000-4000-8000-000000000001',
    '43000000-0000-4000-8000-000000000003',
    'whatsapp',
    '15550000003',
    '{}',
    'active'
  ),
  (
    '13000000-0000-4000-8000-000000000002',
    '43000000-0000-4000-8000-000000000004',
    'whatsapp',
    '15550000004',
    '{}',
    'active'
  );

insert into public.conversations (
  id,
  organization_id,
  service,
  organization_address,
  contact_address,
  name,
  extra
)
values
  (
    '53000000-0000-4000-8000-000000000001',
    '13000000-0000-4000-8000-000000000001',
    'whatsapp',
    'campaign-org-a-main',
    '15550000001',
    'Fresh Main Conversation',
    '{}'
  ),
  (
    '53000000-0000-4000-8000-000000000002',
    '13000000-0000-4000-8000-000000000001',
    'whatsapp',
    'campaign-org-a-main',
    '15550000002',
    'Old Main Conversation',
    '{}'
  ),
  (
    '53000000-0000-4000-8000-000000000003',
    '13000000-0000-4000-8000-000000000001',
    'whatsapp',
    'campaign-org-a-other',
    '15550000002',
    'Fresh Other Account Conversation',
    '{}'
  );

insert into public.messages (
  organization_id,
  conversation_id,
  external_id,
  direction,
  contact_address,
  service,
  organization_address,
  content,
  status,
  timestamp
)
values
  (
    '13000000-0000-4000-8000-000000000001',
    '53000000-0000-4000-8000-000000000001',
    'campaign-fresh-main-message',
    'incoming',
    '15550000001',
    'whatsapp',
    'campaign-org-a-main',
    '{"version":"1","type":"text","kind":"text","text":"fresh"}',
    '{}',
    now() - interval '1 hour'
  ),
  (
    '13000000-0000-4000-8000-000000000001',
    '53000000-0000-4000-8000-000000000002',
    'campaign-old-main-message',
    'incoming',
    '15550000002',
    'whatsapp',
    'campaign-org-a-main',
    '{"version":"1","type":"text","kind":"text","text":"old"}',
    '{}',
    now() - interval '25 hours'
  ),
  (
    '13000000-0000-4000-8000-000000000001',
    '53000000-0000-4000-8000-000000000003',
    'campaign-fresh-other-message',
    'incoming',
    '15550000002',
    'whatsapp',
    'campaign-org-a-other',
    '{"version":"1","type":"text","kind":"text","text":"other"}',
    '{}',
    now() - interval '1 hour'
  );

insert into public.campaigns (
  organization_id,
  id,
  created_by,
  name,
  organization_address,
  template,
  audience_type
)
values
  (
    '13000000-0000-4000-8000-000000000001',
    '63000000-0000-4000-8000-000000000001',
    '33000000-0000-4000-8000-000000000001',
    'All Contacts Campaign',
    'campaign-org-a-main',
    '{"id":"template-1","name":"campaign_template","language":"en_US","status":"APPROVED","components":[]}',
    'all_contacts'
  ),
  (
    '13000000-0000-4000-8000-000000000001',
    '63000000-0000-4000-8000-000000000002',
    '33000000-0000-4000-8000-000000000001',
    'Active Campaign',
    'campaign-org-a-main',
    '{"id":"template-1","name":"campaign_template","language":"en_US","status":"APPROVED","components":[]}',
    'active_24h'
  ),
  (
    '13000000-0000-4000-8000-000000000001',
    '63000000-0000-4000-8000-000000000003',
    '33000000-0000-4000-8000-000000000001',
    'CSV Campaign',
    'campaign-org-a-main',
    '{"id":"template-1","name":"campaign_template","language":"en_US","status":"APPROVED","components":[]}',
    'csv_upload'
  ),
  (
    '13000000-0000-4000-8000-000000000002',
    '63000000-0000-4000-8000-000000000004',
    '33000000-0000-4000-8000-000000000002',
    'Other Org Campaign',
    'campaign-org-b-main',
    '{"id":"template-1","name":"campaign_template","language":"en_US","status":"APPROVED","components":[]}',
    'all_contacts'
  );

insert into public.campaign_csv_recipients (
  organization_id,
  campaign_id,
  contact_address,
  name,
  variables
)
values
  (
    '13000000-0000-4000-8000-000000000001',
    '63000000-0000-4000-8000-000000000003',
    '15551110001',
    'CSV Alice',
    '{"1":"Alice"}'
  ),
  (
    '13000000-0000-4000-8000-000000000001',
    '63000000-0000-4000-8000-000000000003',
    '15551110002',
    'CSV Bob',
    '{"1":"Bob"}'
  );

select is(
  (
    select audience_type
    from public.campaigns
    where id = '63000000-0000-4000-8000-000000000001'
  ),
  'all_contacts'::public.campaign_audience_type,
  'an approved WhatsApp campaign draft is stored'
);

select throws_like(
  $$
    insert into public.campaigns (
      organization_id,
      name,
      organization_address,
      template,
      audience_type
    ) values (
      '13000000-0000-4000-8000-000000000001',
      'Pending Template Campaign',
      'campaign-org-a-main',
      '{"id":"template-2","name":"pending_template","language":"en_US","status":"PENDING","components":[]}',
      'all_contacts'
    )
  $$,
  '%campaigns_template_check%',
  'campaign drafts reject templates that are not approved'
);

select throws_ok(
  $$
    insert into public.campaigns (
      organization_id,
      name,
      organization_address,
      template,
      audience_type
    ) values (
      '13000000-0000-4000-8000-000000000001',
      'Instagram Campaign',
      'campaign-org-a-instagram',
      '{"id":"template-1","name":"campaign_template","language":"en_US","status":"APPROVED","components":[]}',
      'all_contacts'
    )
  $$,
  '23514',
  'Campaign account must be a WhatsApp address in the same organization',
  'campaign drafts reject non-WhatsApp accounts'
);

select throws_ok(
  $$
    insert into public.campaigns (
      organization_id,
      created_by,
      name,
      organization_address,
      template,
      audience_type
    ) values (
      '13000000-0000-4000-8000-000000000001',
      '33000000-0000-4000-8000-000000000002',
      'Wrong Creator Campaign',
      'campaign-org-a-main',
      '{"id":"template-1","name":"campaign_template","language":"en_US","status":"APPROVED","components":[]}',
      'all_contacts'
    )
  $$,
  '23514',
  'Campaign creator must belong to the campaign organization',
  'campaign drafts reject creators from another organization'
);

select throws_ok(
  $$
    insert into public.campaign_csv_recipients (
      organization_id,
      campaign_id,
      contact_address
    ) values (
      '13000000-0000-4000-8000-000000000001',
      '63000000-0000-4000-8000-000000000001',
      '15552220001'
    )
  $$,
  '23514',
  'CSV recipients require a CSV upload campaign in the same organization',
  'CSV recipients cannot be attached to a non-CSV campaign'
);

select set_config(
  'request.jwt.claim.sub',
  '23000000-0000-4000-8000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth;

select is(
  public.get_campaign_audience_count(
    '13000000-0000-4000-8000-000000000001',
    '63000000-0000-4000-8000-000000000001'
  ),
  2::bigint,
  'all contacts counts active linked WhatsApp contacts'
);

select is(
  public.get_campaign_audience_count(
    '13000000-0000-4000-8000-000000000001',
    '63000000-0000-4000-8000-000000000002'
  ),
  1::bigint,
  'active 24 hours counts recent incoming contacts for the selected account'
);

select is(
  public.get_campaign_audience_count(
    '13000000-0000-4000-8000-000000000001',
    '63000000-0000-4000-8000-000000000003'
  ),
  2::bigint,
  'CSV upload counts campaign-only recipients'
);

select results_eq(
  $$
    select contact_address, name
    from public.get_campaign_audience_preview(
      '13000000-0000-4000-8000-000000000001',
      '63000000-0000-4000-8000-000000000001'
    )
  $$,
  $$
    values
      ('15550000001'::text, 'Fresh Contact'::text),
      ('15550000002'::text, 'Old Contact'::text)
  $$,
  'all contacts preview returns active contacts in name order'
);

select results_eq(
  $$
    select contact_address, name
    from public.get_campaign_audience_preview(
      '13000000-0000-4000-8000-000000000001',
      '63000000-0000-4000-8000-000000000002'
    )
  $$,
  $$ values ('15550000001'::text, 'Fresh Contact'::text) $$,
  'active 24 hours preview is scoped to the selected WhatsApp account'
);

select results_eq(
  $$
    select contact_address, name, variables
    from public.get_campaign_audience_preview(
      '13000000-0000-4000-8000-000000000001',
      '63000000-0000-4000-8000-000000000003'
    )
  $$,
  $$
    values
      ('15551110001'::text, 'CSV Alice'::text, '{"1":"Alice"}'::jsonb),
      ('15551110002'::text, 'CSV Bob'::text, '{"1":"Bob"}'::jsonb)
  $$,
  'CSV preview returns campaign-only recipient variables'
);

select is(
  (
    select count(*)::integer
    from public.get_campaign_audience_preview(
      '13000000-0000-4000-8000-000000000001',
      '63000000-0000-4000-8000-000000000001',
      1
    )
  ),
  1,
  'audience preview respects the requested limit'
);

select is(
  (
    select count(*)::integer
    from public.campaigns
    where organization_id = '13000000-0000-4000-8000-000000000002'
  ),
  0,
  'campaign RLS hides drafts from other organizations'
);

select is(
  (
    select count(*)::integer
    from public.campaign_csv_recipients
    where organization_id = '13000000-0000-4000-8000-000000000002'
  ),
  0,
  'campaign recipient RLS hides rows from other organizations'
);

select throws_ok(
  $$
    select public.get_campaign_audience_count(
      '13000000-0000-4000-8000-000000000002',
      '63000000-0000-4000-8000-000000000004'
    )
  $$,
  '42501',
  'organization is not accessible to the authenticated user',
  'audience count denies organizations outside the authenticated user access'
);

select throws_ok(
  $$
    insert into public.campaigns (
      organization_id,
      name,
      organization_address,
      template,
      audience_type
    ) values (
      '13000000-0000-4000-8000-000000000002',
      'Unauthorized Campaign',
      'campaign-org-b-main',
      '{"id":"template-1","name":"campaign_template","language":"en_US","status":"APPROVED","components":[]}',
      'all_contacts'
    )
  $$,
  '23514',
  'Campaign account must be a WhatsApp address in the same organization',
  'campaign validation rejects writes to another organization before persistence'
);

select * from finish();

rollback;
