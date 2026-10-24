begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;
select plan(8);

insert into public.organizations (id, name) values
  ('ad100000-0000-4000-8000-000000000001', 'Instagram compatibility A'),
  ('ad100000-0000-4000-8000-000000000002', 'Instagram compatibility B');

insert into public.organizations_addresses
  (organization_id, service, address, extra)
values
  ('ad100000-0000-4000-8000-000000000001', 'instagram', 'ig-business',
    '{"access_token":"old-test-token","username":"test-profile"}'),
  ('ad100000-0000-4000-8000-000000000002', 'instagram', 'ig-business',
    '{"access_token":"other-test-token","username":"other-profile"}'),
  ('ad100000-0000-4000-8000-000000000001', 'whatsapp', 'wa-business',
    '{"access_token":"wa-test-token"}');

-- Same filtered patch as the helper; existing JSON merge keeps other fields.
update public.organizations_addresses
set extra = '{"needs_reauth":"2026-10-24T00:00:00Z"}'
where organization_id = 'ad100000-0000-4000-8000-000000000001'
  and service = 'instagram' and address = 'ig-business'
  and extra->>'access_token' = 'old-test-token';

select is((select extra->>'needs_reauth' from public.organizations_addresses
  where organization_id = 'ad100000-0000-4000-8000-000000000001' and address = 'ig-business'),
  '2026-10-24T00:00:00Z', 'revoked connection is flagged');
select is((select extra->>'access_token' from public.organizations_addresses
  where organization_id = 'ad100000-0000-4000-8000-000000000001' and address = 'ig-business'),
  'old-test-token', 'reconnect flag preserves the stored token');
select is((select extra->>'username' from public.organizations_addresses
  where organization_id = 'ad100000-0000-4000-8000-000000000001' and address = 'ig-business'),
  'test-profile', 'reconnect flag preserves profile metadata');
select is((select extra->>'needs_reauth' from public.organizations_addresses
  where organization_id = 'ad100000-0000-4000-8000-000000000002' and address = 'ig-business'),
  null::text, 'another tenant with the same address is unchanged');
select is((select extra from public.organizations_addresses
  where organization_id = 'ad100000-0000-4000-8000-000000000001' and address = 'wa-business'),
  '{"access_token":"wa-test-token"}'::jsonb, 'WhatsApp account is unchanged');

-- Login reconnects by upsert, not by creating a new account.
insert into public.organizations_addresses (organization_id, service, address, extra)
values ('ad100000-0000-4000-8000-000000000001', 'instagram', 'ig-business',
  '{"access_token":"new-test-token","needs_reauth":null}')
on conflict (organization_id, address) do update set extra = excluded.extra;

select is((select extra->>'needs_reauth' from public.organizations_addresses
  where organization_id = 'ad100000-0000-4000-8000-000000000001' and address = 'ig-business'),
  null::text, 'successful reconnection clears the warning through the existing trigger');

update public.organizations_addresses
set extra = '{"needs_reauth":"stale-failure"}'
where organization_id = 'ad100000-0000-4000-8000-000000000001'
  and service = 'instagram' and address = 'ig-business'
  and extra->>'access_token' = 'old-test-token';

select is((select extra->>'needs_reauth' from public.organizations_addresses
  where organization_id = 'ad100000-0000-4000-8000-000000000001' and address = 'ig-business'),
  null::text, 'late failure from an old token cannot flag the new login');
select is((select extra->>'access_token' from public.organizations_addresses
  where organization_id = 'ad100000-0000-4000-8000-000000000001' and address = 'ig-business'),
  'new-test-token', 'new token survives stale failure reconciliation');

select * from finish();
rollback;
