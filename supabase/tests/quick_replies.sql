begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, storage;

select no_plan();

insert into public.organizations (id, name, extra) values
  ('98000000-0000-4000-8000-000000000001', 'Quick Replies Org', '{}'),
  ('99000000-0000-4000-8000-000000000001', 'Other Org', '{}');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at, created_at,
  updated_at, confirmation_token, recovery_token, email_change_token_new,
  email_change
) values
  ('00000000-0000-0000-0000-000000000000', '98100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'owner-quick-replies@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '98100000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'admin-quick-replies@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '98100000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'supervisor-quick-replies@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '98100000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'member-quick-replies@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '98100000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'agent-quick-replies@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '98100000-0000-4000-8000-000000000006', 'authenticated', 'authenticated', 'pending-quick-replies@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '98100000-0000-4000-8000-000000000007', 'authenticated', 'authenticated', 'ai-quick-replies@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '99100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'other-quick-replies@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', '');

insert into public.agents (
  id, organization_id, user_id, name, ai, extra
) values
  ('98200000-0000-4000-8000-000000000001', '98000000-0000-4000-8000-000000000001', '98100000-0000-4000-8000-000000000001', 'Owner', false, '{"role":"owner"}'),
  ('98200000-0000-4000-8000-000000000002', '98000000-0000-4000-8000-000000000001', '98100000-0000-4000-8000-000000000002', 'Admin', false, '{"role":"admin"}'),
  ('98200000-0000-4000-8000-000000000003', '98000000-0000-4000-8000-000000000001', '98100000-0000-4000-8000-000000000003', 'Supervisor', false, '{"role":"supervisor"}'),
  ('98200000-0000-4000-8000-000000000004', '98000000-0000-4000-8000-000000000001', '98100000-0000-4000-8000-000000000004', 'Member', false, '{"role":"member"}'),
  ('98200000-0000-4000-8000-000000000005', '98000000-0000-4000-8000-000000000001', '98100000-0000-4000-8000-000000000005', 'Agent', false, '{"role":"agent"}'),
  ('98200000-0000-4000-8000-000000000006', '98000000-0000-4000-8000-000000000001', '98100000-0000-4000-8000-000000000006', 'Pending', false, '{"role":"agent","invitation":{"email":"pending-quick-replies@example.test","status":"pending"}}'),
  ('98200000-0000-4000-8000-000000000007', '98000000-0000-4000-8000-000000000001', '98100000-0000-4000-8000-000000000007', 'AI', true, '{"role":"agent"}'),
  ('99200000-0000-4000-8000-000000000001', '99000000-0000-4000-8000-000000000001', '99100000-0000-4000-8000-000000000001', 'Other Owner', false, '{"role":"owner"}');

insert into public.quick_replies (
  id, organization_id, shortcut, content, created_at, updated_at
) values
  ('98300000-0000-4000-8000-000000000001', '98000000-0000-4000-8000-000000000001', '/alpha', 'Alpha response', '2026-01-01 00:00:00+00', '2026-01-01 00:00:00+00'),
  ('98300000-0000-4000-8000-000000000002', '98000000-0000-4000-8000-000000000001', '/hours', 'Our office is open all day', '2026-01-02 00:00:00+00', '2026-01-02 00:00:00+00'),
  ('99300000-0000-4000-8000-000000000001', '99000000-0000-4000-8000-000000000001', '/other', 'Other response', '2026-01-03 00:00:00+00', '2026-01-03 00:00:00+00');

select set_config('request.jwt.claim.sub', '98100000-0000-4000-8000-000000000005', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select results_eq(
  $$
    select shortcut, total_count
    from public.list_quick_replies_page(
      '98000000-0000-4000-8000-000000000001', 1, 10, null
    )
  $$,
  $$ values
    ('/alpha'::text, 2::bigint),
    ('/hours'::text, 2::bigint)
  $$,
  'Agents can read their organization quick reply library'
);

select throws_like(
  $$ insert into public.quick_replies (organization_id, shortcut, content)
    values ('98000000-0000-4000-8000-000000000001', '/blocked', 'Blocked') $$,
  '%permission denied for table quick_replies%',
  'Agents cannot bypass the RPC with a direct insert'
);

select throws_ok(
  $$ select public.create_quick_reply(
    '98000000-0000-4000-8000-000000000001', '/blocked', 'Blocked'
  ) $$,
  '42501',
  'owner, admin, or supervisor role required to manage quick replies',
  'Agents cannot create quick replies'
);

reset role;
select set_config('request.jwt.claim.sub', '98100000-0000-4000-8000-000000000004', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select is(
  (
    select count(*)
    from public.list_quick_replies_page(
      '98000000-0000-4000-8000-000000000001', 1, 10, null
    )
  ),
  2::bigint,
  'Members can read quick replies'
);

select throws_ok(
  $$ select public.create_quick_reply(
    '98000000-0000-4000-8000-000000000001', '/blocked', 'Blocked'
  ) $$,
  '42501',
  'owner, admin, or supervisor role required to manage quick replies',
  'Members cannot create quick replies'
);

reset role;
select set_config('request.jwt.claim.sub', '98100000-0000-4000-8000-000000000006', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select throws_ok(
  $$ select * from public.list_quick_replies_page(
    '98000000-0000-4000-8000-000000000001', 1, 10, null
  ) $$,
  '42501',
  'organization is not accessible to the authenticated user',
  'Pending invitations cannot read quick replies'
);

reset role;
select set_config('request.jwt.claim.sub', '98100000-0000-4000-8000-000000000007', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select throws_ok(
  $$ select * from public.list_quick_replies_page(
    '98000000-0000-4000-8000-000000000001', 1, 10, null
  ) $$,
  '42501',
  'organization is not accessible to the authenticated user',
  'AI identities cannot read human quick replies'
);

reset role;
select set_config('request.jwt.claim.sub', '98100000-0000-4000-8000-000000000001', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select results_eq(
  $$
    select shortcut, content
    from public.create_quick_reply(
      '98000000-0000-4000-8000-000000000001',
      '  Welcome  ',
      '  Welcome to support  '
    )
  $$,
  $$ values ('/welcome'::text, 'Welcome to support'::text) $$,
  'Owners create normalized, trimmed quick replies'
);

select throws_ok(
  $$ select public.create_quick_reply(
    '98000000-0000-4000-8000-000000000001', '/WELCOME', 'Duplicate'
  ) $$,
  '23505',
  'quick reply shortcut already exists in this organization',
  'Shortcut uniqueness is case insensitive through canonical normalization'
);

select throws_ok(
  $$ select public.create_quick_reply(
    '98000000-0000-4000-8000-000000000001', '/not valid', 'Invalid shortcut'
  ) $$,
  '22023',
  'shortcut must start with /, use lowercase letters, numbers, dashes, or underscores, and contain at most 30 characters',
  'Invalid shortcut characters are rejected'
);

select throws_ok(
  $$ select public.create_quick_reply(
    '98000000-0000-4000-8000-000000000001', '/empty', '   '
  ) $$,
  '22023',
  'quick reply content must contain between 1 and 1000 characters',
  'Blank content is rejected'
);

select throws_ok(
  $$ select public.create_quick_reply(
    '98000000-0000-4000-8000-000000000001', '/long', repeat('a', 1001)
  ) $$,
  '22023',
  'quick reply content must contain between 1 and 1000 characters',
  'Content over 1000 characters is rejected'
);

select throws_ok(
  $$ select public.create_quick_reply(
    '99000000-0000-4000-8000-000000000001', '/cross_org', 'Blocked'
  ) $$,
  '42501',
  'owner, admin, or supervisor role required to manage quick replies',
  'Manager writes enforce organization isolation'
);

select results_eq(
  $$
    select shortcut, total_count
    from public.list_quick_replies_page(
      '98000000-0000-4000-8000-000000000001', 1, 1, 'office'
    )
  $$,
  $$ values ('/hours'::text, 1::bigint) $$,
  'Search matches response content before pagination and counting'
);

select results_eq(
  $$
    select shortcut, total_count
    from public.list_quick_replies_page(
      '98000000-0000-4000-8000-000000000001', 1, 2, null
    )
  $$,
  $$ values
    ('/alpha'::text, 3::bigint),
    ('/hours'::text, 3::bigint)
  $$,
  'Pagination is deterministic and returns the complete total'
);

reset role;
select set_config('request.jwt.claim.sub', '98100000-0000-4000-8000-000000000002', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select lives_ok(
  $$ select public.create_quick_reply(
    '98000000-0000-4000-8000-000000000001', '/admin', 'Created by Admin'
  ) $$,
  'Admins can create quick replies'
);

reset role;
select set_config('request.jwt.claim.sub', '98100000-0000-4000-8000-000000000003', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select lives_ok(
  $$ select public.create_quick_reply(
    '98000000-0000-4000-8000-000000000001', '/supervisor', 'Created by Supervisor'
  ) $$,
  'Supervisors can create quick replies'
);

select results_eq(
  $$
    select content
    from public.update_quick_reply(
      (
        select id from public.quick_replies
        where organization_id = '98000000-0000-4000-8000-000000000001'
          and shortcut = '/supervisor'
      ),
      '/supervisor_updated',
      'Updated by Supervisor'
    )
  $$,
  $$ values ('Updated by Supervisor'::text) $$,
  'Supervisors can update quick replies'
);

select lives_ok(
  $$ select public.delete_quick_reply(
    (
      select id from public.quick_replies
      where organization_id = '98000000-0000-4000-8000-000000000001'
        and shortcut = '/supervisor_updated'
    )
  ) $$,
  'Supervisors can permanently delete quick replies'
);

reset role;

delete from public.quick_replies
where organization_id = '98000000-0000-4000-8000-000000000001';

insert into public.quick_replies (organization_id, shortcut, content)
select
  '98000000-0000-4000-8000-000000000001',
  '/reply_' || lpad(sequence::text, 2, '0'),
  'Response ' || sequence
from generate_series(1, 50) sequence;

select set_config('request.jwt.claim.sub', '98100000-0000-4000-8000-000000000001', true);
set local role authenticated;
set local search_path = extensions, public, auth, storage;

select throws_ok(
  $$ select public.create_quick_reply(
    '98000000-0000-4000-8000-000000000001', '/reply_51', 'One too many'
  ) $$,
  '22023',
  'maximum limit of 50 quick replies reached for this organization',
  'The 51st quick reply is rejected'
);

select results_eq(
  $$
    select count(*)::integer, max(total_count)::integer
    from public.list_quick_replies_page(
      '98000000-0000-4000-8000-000000000001', 1, 500, null
    )
  $$,
  $$ values (50, 50) $$,
  'Page size is capped at 50 without losing the total count'
);

reset role;

select ok(
  exists (
    select 1
    from pg_publication_tables publication_table
    where publication_table.pubname = 'supabase_realtime'
      and publication_table.schemaname = 'public'
      and publication_table.tablename = 'quick_replies'
  ),
  'Quick replies are published to Supabase Realtime'
);

select is(
  (
    select class.relreplident
    from pg_class class
    join pg_namespace namespace on namespace.oid = class.relnamespace
    where namespace.nspname = 'public'
      and class.relname = 'quick_replies'
  ),
  'f'::"char",
  'Quick replies use full replica identity for update and delete reconciliation'
);

select * from finish();

rollback;
