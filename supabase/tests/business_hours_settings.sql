begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, storage;
select plan(12);

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change)
select '00000000-0000-0000-0000-000000000000'::uuid,
  ('ca110000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
  'authenticated', 'authenticated', 'hours-' || i || '@example.test',
  crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''
from generate_series(1, 5) as i;

insert into public.organizations (id, name, extra) values
  ('ca100000-0000-4000-8000-000000000001', 'Hours Org', '{"response_delay_seconds":3,"welcome_message":"Existing welcome"}'),
  ('ca100000-0000-4000-8000-000000000002', 'Other Hours Org', '{}');

insert into public.agents (organization_id, user_id, name, ai, extra) values
  ('ca100000-0000-4000-8000-000000000001', 'ca110000-0000-4000-8000-000000000001', 'Owner', false, '{"role":"owner"}'),
  ('ca100000-0000-4000-8000-000000000001', 'ca110000-0000-4000-8000-000000000002', 'Admin', false, '{"role":"admin"}'),
  ('ca100000-0000-4000-8000-000000000001', 'ca110000-0000-4000-8000-000000000003', 'Member', false, '{"role":"member"}'),
  ('ca100000-0000-4000-8000-000000000001', 'ca110000-0000-4000-8000-000000000004', 'Agent', false, '{"role":"agent"}'),
  ('ca100000-0000-4000-8000-000000000002', 'ca110000-0000-4000-8000-000000000005', 'Other Owner', false, '{"role":"owner"}');

create temp table hours_fixture as
select jsonb_build_object(
  'mode', 'all_days', 'timezone', 'Asia/Karachi',
  'all_days', jsonb_build_object('start_time', '09:00', 'end_time', '17:00'),
  'per_day', (select jsonb_object_agg(day, jsonb_build_object(
    'enabled', true, 'start_time', '09:00', 'end_time', '17:00'))
    from unnest(array['monday','tuesday','wednesday','thursday','friday','saturday','sunday']) as day)
) as schedule;
grant select on hours_fixture to authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'ca110000-0000-4000-8000-000000000001', true);
select lives_ok($$ update public.organizations set extra = jsonb_build_object('business_hours', (select schedule from hours_fixture)) where id = 'ca100000-0000-4000-8000-000000000001' $$, 'owner saves a complete organization-scoped schedule');
select is((select extra->'business_hours'->>'mode' from public.organizations where id = 'ca100000-0000-4000-8000-000000000001'), 'all_days', 'All Days persists');
select is((select extra->>'response_delay_seconds' from public.organizations where id = 'ca100000-0000-4000-8000-000000000001'), '3', 'unrelated numeric configuration is preserved');
select is((select extra->>'welcome_message' from public.organizations where id = 'ca100000-0000-4000-8000-000000000001'), 'Existing welcome', 'unrelated welcome message is preserved');
update public.organizations set extra = '{"business_hours":{"mode":"per_day","per_day":{"sunday":{"enabled":false}}}}' where id = 'ca100000-0000-4000-8000-000000000001';
select is((select extra->'business_hours'->>'mode' from public.organizations where id = 'ca100000-0000-4000-8000-000000000001'), 'per_day', 'Per day persists');
select is((select extra#>>'{business_hours,per_day,sunday,enabled}' from public.organizations where id = 'ca100000-0000-4000-8000-000000000001'), 'false', 'unchecked Sunday remains closed');
update public.organizations set extra = '{"business_hours":{"mode":"all_days"}}' where id = 'ca100000-0000-4000-8000-000000000001';
select is((select extra#>>'{business_hours,per_day,monday,start_time}' from public.organizations where id = 'ca100000-0000-4000-8000-000000000001'), '09:00', 'switching mode preserves the weekday schedule');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'ca110000-0000-4000-8000-000000000002', true);
update public.organizations set extra = '{"business_hours":{"all_days":{"end_time":"18:00"}}}' where id = 'ca100000-0000-4000-8000-000000000001';
select is((select extra#>>'{business_hours,all_days,end_time}' from public.organizations where id = 'ca100000-0000-4000-8000-000000000001'), '18:00', 'admin updates settings without changing organization name');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'ca110000-0000-4000-8000-000000000003', true);
with changed as (update public.organizations set extra = '{"business_hours":{"mode":"per_day"}}' where id = 'ca100000-0000-4000-8000-000000000001' returning id)
select is(count(*), 0::bigint, 'member cannot update hours') from changed;
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'ca110000-0000-4000-8000-000000000004', true);
with changed as (update public.organizations set extra = '{"business_hours":{"mode":"per_day"}}' where id = 'ca100000-0000-4000-8000-000000000001' returning id)
select is(count(*), 0::bigint, 'agent cannot update hours') from changed;
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'ca110000-0000-4000-8000-000000000005', true);
with changed as (update public.organizations set extra = '{"business_hours":{"mode":"per_day"}}' where id = 'ca100000-0000-4000-8000-000000000001' returning id)
select is(count(*), 0::bigint, 'other organization owner cannot update hours') from changed;
reset role;
select is((select extra from public.organizations where id = 'ca100000-0000-4000-8000-000000000002'), '{}'::jsonb, 'other organization remains unchanged');
select * from finish();
rollback;
