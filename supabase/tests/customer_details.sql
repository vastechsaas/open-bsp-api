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
  id, organization_id, name
) values
  ('a1300000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', 'New Customer'),
  ('a1300000-0000-4000-8000-000000000002', 'a1000000-0000-4000-8000-000000000002', 'Other Customer');

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
