begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select no_plan();

insert into public.organizations(id,name,extra) values ('12600000-0000-4000-8000-000000000001','Permissions A','{}'),('12600000-0000-4000-8000-000000000002','Permissions B','{}');
insert into auth.users(id,email,raw_user_meta_data)
select ('12610000-0000-4000-8000-' || lpad(i::text,12,'0'))::uuid, 'permissions-' || i || '@example.test', '{}' from generate_series(1,7) i;
insert into public.agents(id,organization_id,user_id,name,ai,extra)
select ('12620000-0000-4000-8000-' || lpad(i::text,12,'0'))::uuid,'12600000-0000-4000-8000-000000000001',
  ('12610000-0000-4000-8000-' || lpad(i::text,12,'0'))::uuid,'Role ' || i,false,
  jsonb_build_object('role',(array['owner','admin','supervisor','member','agent','supervisor'])[i]) ||
  case when i=6 then '{"invitation":{"status":"pending"}}'::jsonb else '{}'::jsonb end
from generate_series(1,6) i;
insert into public.platform_admins(user_id) values ('12610000-0000-4000-8000-000000000007');
insert into public.chatbot_flows(id,organization_id,name) values ('12630000-0000-4000-8000-000000000001','12600000-0000-4000-8000-000000000001','Flow A'),('12630000-0000-4000-8000-000000000002','12600000-0000-4000-8000-000000000002','Flow B');
insert into public.api_keys(organization_id,name,key,role) values ('12600000-0000-4000-8000-000000000001','Test admin','permission-test-key','admin');

create temporary table permission_test_matrix(value jsonb);
insert into permission_test_matrix select jsonb_agg(jsonb_build_object('role',r,'can_view',r<>'owner','can_manage',r='agent')) from unnest(array['owner','admin','supervisor','member','agent']) r;
grant select on permission_test_matrix to authenticated;

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"12610000-0000-4000-8000-000000000003","role":"authenticated"}',true);
select ok(public.has_module_permission('12600000-0000-4000-8000-000000000001','chatbot_builder','view'),'Supervisor defaults to View');
select ok(not public.has_module_permission('12600000-0000-4000-8000-000000000001','chatbot_builder','manage'),'Supervisor defaults to no Manage');
select is((select count(*) from public.chatbot_flows),1::bigint,'Supervisor reads only own organization flows');
select throws_ok($$select * from public.list_chatbot_flows_page('12600000-0000-4000-8000-000000000002')$$,'42501',null,'Cross-tenant list is blocked');
select throws_ok($$insert into public.chatbot_flows(organization_id,name) values ('12600000-0000-4000-8000-000000000001','Denied')$$,'42501',null,'View cannot insert directly');
select throws_ok($$select public.get_platform_module_permissions('12600000-0000-4000-8000-000000000001','chatbot_builder')$$,'42501','platform administrator access required','Only Super Admin can read matrix');
select throws_ok($$select public.update_platform_module_permissions('12600000-0000-4000-8000-000000000001','chatbot_builder',(select value from permission_test_matrix),0,'12640000-0000-4000-8000-000000000001')$$,'42501','platform administrator access required','Supervisor cannot save permissions');

select set_config('request.jwt.claims','{"sub":"12610000-0000-4000-8000-000000000001"}',true);
select ok(public.has_module_permission('12600000-0000-4000-8000-000000000001','chatbot_builder','manage'),'Owner defaults to Manage');
select set_config('request.jwt.claims','{"sub":"12610000-0000-4000-8000-000000000002"}',true);
select ok(public.has_module_permission('12600000-0000-4000-8000-000000000001','chatbot_builder','manage'),'Admin defaults to Manage');
select set_config('request.jwt.claims','{"sub":"12610000-0000-4000-8000-000000000004"}',true);
select ok(public.has_module_permission('12600000-0000-4000-8000-000000000001','chatbot_builder','view'),'Member defaults to View');
select ok(not public.has_module_permission('12600000-0000-4000-8000-000000000001','chatbot_builder','manage'),'Member cannot Manage');
select set_config('request.jwt.claims','{"sub":"12610000-0000-4000-8000-000000000005"}',true);
select ok(not public.has_module_permission('12600000-0000-4000-8000-000000000001','chatbot_builder','view'),'Agent defaults to no access');
select is((select count(*) from public.chatbot_flows),0::bigint,'No access also blocks direct reads');
select set_config('request.jwt.claims','{"sub":"12610000-0000-4000-8000-000000000006"}',true);
select ok(not public.has_module_permission('12600000-0000-4000-8000-000000000001','chatbot_builder','view'),'Pending membership gets no access');

select set_config('request.jwt.claims','{"sub":"12610000-0000-4000-8000-000000000007"}',true);
select ok(not public.has_module_permission('12600000-0000-4000-8000-000000000001','chatbot_builder','view'),'Super Admin is not automatically a tenant builder user');
select is(public.get_platform_module_permissions('12600000-0000-4000-8000-000000000001','chatbot_builder')->>'revision','0','Unconfigured organization has revision zero');
select throws_ok($$select public.get_platform_module_permissions('12600000-0000-4000-8000-000000000001','other_module')$$,'22023','Unsupported module','Unknown modules rejected');
select throws_ok($$select public.update_platform_module_permissions('12600000-0000-4000-8000-000000000001','chatbot_builder','[]',0,'12640000-0000-4000-8000-000000000001')$$,'22023',null,'Incomplete matrix rejected');
select throws_ok($$select public.update_platform_module_permissions('12600000-0000-4000-8000-000000000001','chatbot_builder',
  jsonb_set((select value from permission_test_matrix),'{4,can_view}','false'),0,'12640000-0000-4000-8000-000000000001')$$,
  '22023',null,'Manage without View is rejected server-side');
select throws_ok($$select public.update_platform_module_permissions('12600000-0000-4000-8000-000000000001','chatbot_builder',
  jsonb_set((select value from permission_test_matrix),'{1,can_view}','"true"'),0,'12640000-0000-4000-8000-000000000001')$$,
  '22023',null,'Permission flags must be actual booleans');
select is(public.update_platform_module_permissions('12600000-0000-4000-8000-000000000001','chatbot_builder',(select value from permission_test_matrix),0,'12640000-0000-4000-8000-000000000001')->>'revision','1','Matrix saves atomically and increments revision');
select is(public.update_platform_module_permissions('12600000-0000-4000-8000-000000000001','chatbot_builder',(select value from permission_test_matrix),0,'12640000-0000-4000-8000-000000000001')->>'revision','1','Duplicate save returns original result');
select throws_ok($$select public.update_platform_module_permissions('12600000-0000-4000-8000-000000000001','chatbot_builder',(select value from permission_test_matrix),0,'12640000-0000-4000-8000-000000000002')$$,'40001','Permissions changed. Reload before saving.','Stale revision cannot overwrite matrix');
select throws_ok($$select public.update_platform_module_permissions('12600000-0000-4000-8000-000000000002','chatbot_builder',(select value from permission_test_matrix),0,'12640000-0000-4000-8000-000000000001')$$,'22023','Request ID already used for a different action','Request ID cannot be reused for another tenant');
select is(public.get_effective_module_permissions('12600000-0000-4000-8000-000000000001','chatbot_builder')->>'revision',
  '0','Nonmembers cannot discover even a configured tenant revision');

select set_config('request.jwt.claims','{"sub":"12610000-0000-4000-8000-000000000001"}',true);
select ok(not public.has_module_permission('12600000-0000-4000-8000-000000000001','chatbot_builder','view'),'Super Admin can revoke Owner access');
select is((select count(*) from public.chatbot_flows),0::bigint,'Revoked Owner cannot read directly');
select set_config('request.jwt.claims','{"sub":"12610000-0000-4000-8000-000000000002"}',true);
select ok(not public.has_module_permission('12600000-0000-4000-8000-000000000001','chatbot_builder','manage'),'Super Admin can downgrade Admin to View');
select set_config('request.jwt.claims','{"sub":"12610000-0000-4000-8000-000000000005"}',true);
select ok(public.has_module_permission('12600000-0000-4000-8000-000000000001','chatbot_builder','manage'),'Agent can be explicitly granted Manage');
select lives_ok($$insert into public.chatbot_flows(organization_id,name) values ('12600000-0000-4000-8000-000000000001','Granted')$$,'Manage grant works for direct writes');
select ok(not has_table_privilege('authenticated','public.organization_module_permissions','update'),'Tenant clients cannot directly edit permissions');
select ok(not has_table_privilege('authenticated','public.organization_module_permissions','truncate'),'Tenant clients cannot truncate permissions');
select ok(not has_table_privilege('anon','public.organization_module_settings','truncate'),'Anonymous clients cannot truncate permission revisions');
select is(public.get_effective_module_permissions('12600000-0000-4000-8000-000000000002','chatbot_builder'),
  '{"can_view":false,"can_manage":false,"revision":0}'::jsonb,'Outsiders receive no tenant permission metadata');
select ok(not has_function_privilege('authenticated','public.resolve_chatbot_webhook_credential(uuid,uuid)','execute'),
  'Builder users cannot resolve protected credential values directly');
select ok(not has_function_privilege('authenticated','public.publish_chatbot_flow_draft(uuid,uuid,uuid,timestamp with time zone,jsonb,uuid)','execute'),
  'Publishing cannot bypass the management endpoint');
select ok(not public.has_module_permission('12600000-0000-4000-8000-000000000001',null,'view'),'Null module never grants permission');

reset role;
select is((select count(*) from public.platform_admin_action_events where action_type='organization_module_permissions.update'),1::bigint,'Exactly one audit event per saved request');
select ok((select before_state->>'revision'='0' and after_state->'result'->>'revision'='1' from public.platform_admin_action_events where action_type='organization_module_permissions.update'),'Audit preserves old/new matrices');
select set_config('request.jwt.claims','{}',true);
select set_config('request.headers','{"api-key":"permission-test-key"}',true);
set local role anon;
select ok(public.has_module_permission('12600000-0000-4000-8000-000000000001','chatbot_builder','view'),'API key reads configured role permissions');
select ok(not public.has_module_permission('12600000-0000-4000-8000-000000000001','chatbot_builder','manage'),'API key cannot bypass Admin downgrade');
select ok(not public.has_module_permission('12600000-0000-4000-8000-000000000002','chatbot_builder','view'),'API key remains tenant-scoped');
reset role;
select * from finish();
rollback;
