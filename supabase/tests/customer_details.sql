begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, storage;

select no_plan();

insert into public.organizations (id, name, extra) values
  ('a1000000-0000-4000-8000-000000000001', 'Customer Details Org', '{}'),
  ('a1000000-0000-4000-8000-000000000002', 'Other Customer Org', '{}');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at, created_at,
  updated_at, confirmation_token, recovery_token, email_change_token_new,
  email_change
) values
  ('00000000-0000-0000-0000-000000000000', 'a1100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'customer-agent@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'a1100000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'other-customer-agent@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', '');

insert into public.agents (
  id, organization_id, user_id, name, ai, extra
) values
  ('a1200000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', 'a1100000-0000-4000-8000-000000000001', 'Customer Agent', false, '{"role":"agent"}'),
  ('a1200000-0000-4000-8000-000000000002', 'a1000000-0000-4000-8000-000000000002', 'a1100000-0000-4000-8000-000000000002', 'Other Customer Agent', false, '{"role":"agent"}');

insert into public.contacts (
  id, organization_id, name, email, company, job_title, city, country,
  created_at, updated_at
) values
  ('a1300000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', 'New Customer', null, null, null, null, null, '2026-01-01 00:00:00+00', '2026-01-01 00:00:00+00'),
  ('a1300000-0000-4000-8000-000000000002', 'a1000000-0000-4000-8000-000000000002', 'Other Customer', 'secret@example.test', null, null, null, null, '2026-01-01 00:00:00+00', '2026-01-01 00:00:00+00'),
  ('a1300000-0000-4000-8000-000000000003', 'a1000000-0000-4000-8000-000000000001', 'Aisha Noor', 'aisha@example.test', 'Northstar Foods', 'Buyer', 'Karachi', 'Pakistan', '2026-01-03 00:00:00+00', '2026-01-03 00:00:00+00'),
  ('a1300000-0000-4000-8000-000000000004', 'a1000000-0000-4000-8000-000000000001', 'Omar Shah', null, null, null, 'Islamabad', 'Pakistan', '2026-01-02 00:00:00+00', '2026-01-02 00:00:00+00');

insert into public.contacts_addresses (
  organization_id, contact_id, service, address, extra
) values
  ('a1000000-0000-4000-8000-000000000001', 'a1300000-0000-4000-8000-000000000001', 'whatsapp', '923001111111', '{"phone_number":"923001111111","name":"Sara Customer"}'),
  ('a1000000-0000-4000-8000-000000000001', 'a1300000-0000-4000-8000-000000000003', 'instagram', 'aisha-ig-id', '{"username":"aisha.noor"}'),
  ('a1000000-0000-4000-8000-000000000002', 'a1300000-0000-4000-8000-000000000002', 'whatsapp', '923009999999', '{"phone_number":"923009999999"}');

select set_config('request.jwt.claim.sub', 'a1100000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select lives_ok(
  $$
    update public.contacts
    set
      name = 'Sara Customer',
      email = 'sara@example.test',
      company = 'Vista Retail',
      job_title = 'Marketing Manager',
      city = 'Lahore',
      country = 'Pakistan'
    where id = 'a1300000-0000-4000-8000-000000000001'
  $$,
  'Agents can update structured customer details in their organization'
);

select results_eq(
  $$
    select name, total_count
    from public.list_contacts_page(
      'a1000000-0000-4000-8000-000000000001', 1, 1
    )
  $$,
  $$ values ('Sara Customer'::text, 3::bigint) $$,
  'Contact Manager returns a backend-paginated page and authoritative total'
);

select results_eq(
  $$
    select name
    from public.list_contacts_page(
      'a1000000-0000-4000-8000-000000000001', 2, 1
    )
  $$,
  $$ values ('Aisha Noor'::text) $$,
  'Contact Manager ordering is deterministic across pages'
);

select results_eq(
  $$
    select name
    from public.list_contacts_page(
      'a1000000-0000-4000-8000-000000000001',
      p_search => 'NORTHSTAR'
    )
  $$,
  $$ values ('Aisha Noor'::text) $$,
  'Contact Manager searches structured customer fields case-insensitively'
);

select results_eq(
  $$
    select name
    from public.list_contacts_page(
      'a1000000-0000-4000-8000-000000000001',
      p_search => 'aisha.noor'
    )
  $$,
  $$ values ('Aisha Noor'::text) $$,
  'Contact Manager searches linked channel identities'
);

select is(
  (
    select addresses->0->>'service'
    from public.list_contacts_page(
      'a1000000-0000-4000-8000-000000000001',
      p_search => '923001111111'
    )
  ),
  'whatsapp',
  'Contact Manager returns channel data without a follow-up query'
);

select is(
  (
    select count(*)::integer
    from public.list_contacts_page(
      'a1000000-0000-4000-8000-000000000001',
      p_search => 'secret@example.test'
    )
  ),
  0,
  'Contact Manager search never exposes another organization contact'
);

select throws_ok(
  $$
    select *
    from public.list_contacts_page(
      'a1000000-0000-4000-8000-000000000002'
    )
  $$,
  '42501',
  'organization is not accessible to the authenticated user',
  'Contact Manager denies inaccessible organizations'
);

reset role;

insert into public.contacts (organization_id, name)
select
  'a1000000-0000-4000-8000-000000000001',
  'Generated Contact ' || value
from generate_series(1, 52) as value;

set local role authenticated;
set local search_path = extensions, public, auth, storage;

select results_eq(
  $$
    select count(*)::integer, max(total_count)::integer
    from public.list_contacts_page(
      'a1000000-0000-4000-8000-000000000001', 1, 500
    )
  $$,
  $$ values (50, 55) $$,
  'Contact Manager caps page size at 50 while preserving the full total'
);

select results_eq(
  $$
    select name, email, company, job_title, city, country
    from public.contacts
    where id = 'a1300000-0000-4000-8000-000000000001'
  $$,
  $$ values (
    'Sara Customer'::text,
    'sara@example.test'::text,
    'Vista Retail'::text,
    'Marketing Manager'::text,
    'Lahore'::text,
    'Pakistan'::text
  ) $$,
  'Structured customer details are stored on the canonical contact'
);

select lives_ok(
  $$
    update public.contacts
    set company = 'Blocked cross-tenant update'
    where id = 'a1300000-0000-4000-8000-000000000002'
  $$,
  'Cross-tenant contact updates expose no writable row'
);

reset role;

select is(
  (
    select company
    from public.contacts
    where id = 'a1300000-0000-4000-8000-000000000002'
  ),
  null::text,
  'Agents cannot update another organization contact'
);

set local role authenticated;
set local search_path = extensions, public, auth, storage;

select throws_like(
  $$ update public.contacts set email = 'not-an-email' where id = 'a1300000-0000-4000-8000-000000000001' $$,
  '%contacts_email_check%',
  'Invalid email addresses are rejected'
);

select throws_like(
  $$ update public.contacts set company = repeat('x', 201) where id = 'a1300000-0000-4000-8000-000000000001' $$,
  '%contacts_company_check%',
  'Company values longer than 200 characters are rejected'
);

select throws_like(
  $$ update public.contacts set job_title = repeat('x', 121) where id = 'a1300000-0000-4000-8000-000000000001' $$,
  '%contacts_job_title_check%',
  'Job titles longer than 120 characters are rejected'
);

select throws_like(
  $$ update public.contacts set city = repeat('x', 121) where id = 'a1300000-0000-4000-8000-000000000001' $$,
  '%contacts_city_check%',
  'Cities longer than 120 characters are rejected'
);

select throws_like(
  $$ update public.contacts set country = repeat('x', 121) where id = 'a1300000-0000-4000-8000-000000000001' $$,
  '%contacts_country_check%',
  'Countries longer than 120 characters are rejected'
);

select lives_ok(
  $$
    update public.contacts
    set email = null, company = null, job_title = null, city = null, country = null
    where id = 'a1300000-0000-4000-8000-000000000001'
  $$,
  'Optional customer details can be cleared'
);

reset role;

select ok(
  exists (
    select 1
    from pg_publication_tables publication_table
    where publication_table.pubname = 'supabase_realtime'
      and publication_table.schemaname = 'public'
      and publication_table.tablename = 'contacts'
  ),
  'Contacts are published for realtime panel reconciliation'
);

select * from finish();
rollback;
