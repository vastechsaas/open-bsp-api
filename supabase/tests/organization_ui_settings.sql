begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, storage;
select plan(16);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at, created_at,
  updated_at, confirmation_token, recovery_token, email_change_token_new,
  email_change
) values
  ('00000000-0000-0000-0000-000000000000', 'e1100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'appearance-owner@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'e1100000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'appearance-admin@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'e1100000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'appearance-supervisor@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'e1100000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'appearance-agent@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'e1100000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'appearance-member@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'e1100000-0000-4000-8000-000000000006', 'authenticated', 'authenticated', 'appearance-pending@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'e1100000-0000-4000-8000-000000000007', 'authenticated', 'authenticated', 'appearance-other@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', '');

insert into public.organizations (id, name, extra) values
  ('e1000000-0000-4000-8000-000000000001', 'Appearance Org', '{}'),
  ('e1000000-0000-4000-8000-000000000002', 'Other Appearance Org', '{}');

select is(
  (select chat_bubble_theme from public.organization_ui_settings where organization_id = 'e1000000-0000-4000-8000-000000000001'),
  'orange',
  'new organizations use the existing orange theme by default'
);

insert into public.agents (id, organization_id, user_id, name, ai, extra) values
  ('e1200000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'e1100000-0000-4000-8000-000000000001', 'Owner', false, '{"role":"owner"}'),
  ('e1200000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001', 'e1100000-0000-4000-8000-000000000002', 'Admin', false, '{"role":"admin"}'),
  ('e1200000-0000-4000-8000-000000000003', 'e1000000-0000-4000-8000-000000000001', 'e1100000-0000-4000-8000-000000000003', 'Supervisor', false, '{"role":"supervisor"}'),
  ('e1200000-0000-4000-8000-000000000004', 'e1000000-0000-4000-8000-000000000001', 'e1100000-0000-4000-8000-000000000004', 'Agent', false, '{"role":"agent"}'),
  ('e1200000-0000-4000-8000-000000000005', 'e1000000-0000-4000-8000-000000000001', 'e1100000-0000-4000-8000-000000000005', 'Member', false, '{"role":"member"}'),
  ('e1200000-0000-4000-8000-000000000006', 'e1000000-0000-4000-8000-000000000001', 'e1100000-0000-4000-8000-000000000006', 'Pending', false, '{"role":"admin","invitation":{"status":"pending"}}'),
  ('e1200000-0000-4000-8000-000000000007', 'e1000000-0000-4000-8000-000000000002', 'e1100000-0000-4000-8000-000000000007', 'Other Owner', false, '{"role":"owner"}');

select set_config('request.jwt.claim.role', 'authenticated', true);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'e1100000-0000-4000-8000-000000000001', true);
select is((select chat_bubble_theme from public.update_organization_chat_bubble_theme('e1000000-0000-4000-8000-000000000001', 'green')), 'green', 'Owner can update the theme');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'e1100000-0000-4000-8000-000000000002', true);
select is((select chat_bubble_theme from public.update_organization_chat_bubble_theme('e1000000-0000-4000-8000-000000000001', 'blue')), 'blue', 'Admin can update the theme');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'e1100000-0000-4000-8000-000000000003', true);
select results_eq(
  $$ select chat_bubble_theme, updated_by_scope from public.update_organization_chat_bubble_theme('e1000000-0000-4000-8000-000000000001', 'purple') $$,
  $$ values ('purple'::text, 'organization'::text) $$,
  'Supervisor can update the theme with organization attribution'
);
select throws_ok(
  $$ select public.update_organization_chat_bubble_theme('e1000000-0000-4000-8000-000000000001', 'red') $$,
  '22023',
  'invalid chat bubble theme',
  'arbitrary colors are rejected'
);
select throws_like(
  $$ update public.organization_ui_settings set chat_bubble_theme = 'teal' where organization_id = 'e1000000-0000-4000-8000-000000000001' $$,
  '%permission denied for table organization_ui_settings%',
  'direct writes are blocked'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'e1100000-0000-4000-8000-000000000004', true);
select is((select chat_bubble_theme from public.get_organization_ui_settings('e1000000-0000-4000-8000-000000000001')), 'purple', 'Agent can read the organization theme');
select throws_ok(
  $$ select public.update_organization_chat_bubble_theme('e1000000-0000-4000-8000-000000000001', 'teal') $$,
  '42501',
  'owner, admin, or supervisor role required to manage appearance settings',
  'Agent cannot update the theme'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'e1100000-0000-4000-8000-000000000005', true);
select is((select chat_bubble_theme from public.get_organization_ui_settings('e1000000-0000-4000-8000-000000000001')), 'purple', 'Member can read the organization theme');
select throws_ok(
  $$ select public.update_organization_chat_bubble_theme('e1000000-0000-4000-8000-000000000001', 'teal') $$,
  '42501',
  'owner, admin, or supervisor role required to manage appearance settings',
  'Member cannot update the theme'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'e1100000-0000-4000-8000-000000000006', true);
select throws_ok(
  $$ select public.get_organization_ui_settings('e1000000-0000-4000-8000-000000000001') $$,
  '42501',
  'accepted organization membership required to read appearance settings',
  'pending humans cannot read the theme'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'e1100000-0000-4000-8000-000000000007', true);
select throws_ok(
  $$ select public.get_organization_ui_settings('e1000000-0000-4000-8000-000000000001') $$,
  '42501',
  'accepted organization membership required to read appearance settings',
  'cross-tenant humans cannot read the theme'
);
select throws_ok(
  $$ select public.update_organization_chat_bubble_theme('e1000000-0000-4000-8000-000000000001', 'teal') $$,
  '42501',
  'owner, admin, or supervisor role required to manage appearance settings',
  'cross-tenant humans cannot update the theme'
);
reset role;

select is(
  (
    select count(*)
    from public.organization_ui_settings
    where organization_id in (
      'e1000000-0000-4000-8000-000000000001',
      'e1000000-0000-4000-8000-000000000002'
    )
  ),
  2::bigint,
  'each test organization has one settings row'
);
select is((select updated_by_user_id from public.organization_ui_settings where organization_id = 'e1000000-0000-4000-8000-000000000001'), 'e1100000-0000-4000-8000-000000000003'::uuid, 'the last manager is recorded');
select is((select updated_at is not null from public.organization_ui_settings where organization_id = 'e1000000-0000-4000-8000-000000000001'), true, 'the update time is recorded');

select * from finish();
rollback;
