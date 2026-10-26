begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select no_plan();

insert into public.organizations(id,name,extra) values
 ('13100000-0000-4000-8000-000000000001','Availability A','{}'),
 ('13100000-0000-4000-8000-000000000002','Availability B','{}');
insert into auth.users(id,email,raw_user_meta_data)
select ('13110000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'availability-'||i||'@example.test','{}' from generate_series(1,7) i;
insert into public.agents(id,organization_id,user_id,name,ai,extra)
select ('13120000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'13100000-0000-4000-8000-000000000001',
 ('13110000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'Role '||i,false,
 jsonb_build_object('role',(array['owner','admin','supervisor','member','agent'])[i]) from generate_series(1,5) i;
insert into public.agents(organization_id,user_id,name,ai,extra) values
 ('13100000-0000-4000-8000-000000000002','13110000-0000-4000-8000-000000000001','Owner B',false,'{"role":"owner"}');
insert into public.platform_admins(user_id) values ('13110000-0000-4000-8000-000000000006');
insert into public.api_keys(organization_id,name,key,role) values
 ('13100000-0000-4000-8000-000000000001','Availability admin','availability-test-key','admin');
insert into public.chatbot_flows(id,organization_id,name) values
 ('13130000-0000-4000-8000-000000000001','13100000-0000-4000-8000-000000000001','Availability flow');
insert into public.chatbot_flow_versions(id,organization_id,flow_id,version,status,definition,published_at) values
 ('13140000-0000-4000-8000-000000000001','13100000-0000-4000-8000-000000000001','13130000-0000-4000-8000-000000000001',1,'published','{"schema_version":1,"start_node_id":"start","nodes":[],"edges":[]}',now()),
 ('13140000-0000-4000-8000-000000000002','13100000-0000-4000-8000-000000000001','13130000-0000-4000-8000-000000000001',2,'draft',null,null);
insert into public.organizations_addresses(organization_id,service,address,status,extra) values
 ('13100000-0000-4000-8000-000000000001','whatsapp','131-test-number','connected','{}');
insert into public.chatbot_flow_deployments(organization_id,organization_address,flow_id,flow_version_id,agent_id)
values ('13100000-0000-4000-8000-000000000001','131-test-number','13130000-0000-4000-8000-000000000001','13140000-0000-4000-8000-000000000001',public.ensure_chatbot_runtime_agent('13100000-0000-4000-8000-000000000001'));
create temporary table availability_matrix(value jsonb);
insert into availability_matrix select jsonb_agg(jsonb_build_object('role',r,'can_view',true,'can_manage',true))
 from unnest(array['owner','admin','supervisor','member','agent']) r;
grant select on availability_matrix to authenticated;
create temporary table availability_before as select
 (select jsonb_agg(to_jsonb(v)) from public.chatbot_flow_versions v where v.organization_id='13100000-0000-4000-8000-000000000001') versions,
 (select to_jsonb(d) from public.chatbot_flow_deployments d where d.organization_id='13100000-0000-4000-8000-000000000001') deployment;

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"13110000-0000-4000-8000-000000000001"}',true);
select is(public.get_effective_module_permissions('13100000-0000-4000-8000-000000000001','chatbot_builder')->>'enabled','true','Missing setting preserves availability');
select throws_ok($$select public.update_platform_module_permissions('13100000-0000-4000-8000-000000000001','chatbot_builder',(select value from availability_matrix),0,'13150000-0000-4000-8000-000000000001',false)$$,'42501','platform administrator access required','Owner cannot change availability');
select set_config('request.jwt.claims','{"sub":"13110000-0000-4000-8000-000000000006"}',true);
select is(public.update_platform_module_permissions('13100000-0000-4000-8000-000000000001','chatbot_builder',(select value from availability_matrix),0,'13150000-0000-4000-8000-000000000001',false)->>'enabled','false','Super Admin atomically disables and saves raw grants');
select is(public.update_platform_module_permissions('13100000-0000-4000-8000-000000000001','chatbot_builder',(select value from availability_matrix),0,'13150000-0000-4000-8000-000000000001',false)->>'revision','1','Duplicate disable returns original receipt');
select throws_ok($$select public.update_platform_module_permissions('13100000-0000-4000-8000-000000000001','chatbot_builder',(select value from availability_matrix),0,'13150000-0000-4000-8000-000000000001',true)$$,'22023','Request ID already used for a different action','Request ID binds availability as well as role grants');
select throws_ok($$select public.update_platform_module_permissions('13100000-0000-4000-8000-000000000001','chatbot_builder',(select value from availability_matrix),0,'13150000-0000-4000-8000-000000000002',true)$$,'40001','Permissions changed. Reload before saving.','Concurrent stale enable cannot overwrite disable');
select is(public.get_platform_module_permissions('13100000-0000-4000-8000-000000000001','chatbot_builder')->'permissions',(select value from availability_matrix),'Disabled matrix retains every raw View/Manage flag');
select is(public.update_platform_module_permissions('13100000-0000-4000-8000-000000000001','chatbot_builder',(select value from availability_matrix),1,'13150000-0000-4000-8000-000000000002')->>'enabled','false','Legacy five-argument save leaves availability unchanged');
select is(public.update_platform_module_permissions('13100000-0000-4000-8000-000000000001','chatbot_builder',(select value from availability_matrix),1,'13150000-0000-4000-8000-000000000002')->>'revision','2','Legacy duplicate is idempotent');

-- Every role is deliberately granted Manage: availability must still win.
select set_config('request.jwt.claims','{"sub":"13110000-0000-4000-8000-000000000001"}',true);
select ok(not public.has_module_permission('13100000-0000-4000-8000-000000000001','chatbot_builder','view') and not public.has_module_permission('13100000-0000-4000-8000-000000000001','chatbot_builder','manage'),'Disabled overrides role 1');
select set_config('request.jwt.claims','{"sub":"13110000-0000-4000-8000-000000000002"}',true);
select ok(not public.has_module_permission('13100000-0000-4000-8000-000000000001','chatbot_builder','view') and not public.has_module_permission('13100000-0000-4000-8000-000000000001','chatbot_builder','manage'),'Disabled overrides role 2');
select set_config('request.jwt.claims','{"sub":"13110000-0000-4000-8000-000000000003"}',true);
select ok(not public.has_module_permission('13100000-0000-4000-8000-000000000001','chatbot_builder','view') and not public.has_module_permission('13100000-0000-4000-8000-000000000001','chatbot_builder','manage'),'Disabled overrides role 3');
select set_config('request.jwt.claims','{"sub":"13110000-0000-4000-8000-000000000004"}',true);
select ok(not public.has_module_permission('13100000-0000-4000-8000-000000000001','chatbot_builder','view') and not public.has_module_permission('13100000-0000-4000-8000-000000000001','chatbot_builder','manage'),'Disabled overrides role 4');
select set_config('request.jwt.claims','{"sub":"13110000-0000-4000-8000-000000000005"}',true);
select ok(not public.has_module_permission('13100000-0000-4000-8000-000000000001','chatbot_builder','view') and not public.has_module_permission('13100000-0000-4000-8000-000000000001','chatbot_builder','manage'),'Disabled overrides role 5');
select is((select count(*) from public.chatbot_flows where organization_id='13100000-0000-4000-8000-000000000001'),0::bigint,'Disabled blocks direct REST flow reads');
select is((select count(*) from public.chatbot_flow_versions where organization_id='13100000-0000-4000-8000-000000000001'),0::bigint,'Disabled blocks draft and published inspection');
select is((select count(*) from public.chatbot_flow_deployments where organization_id='13100000-0000-4000-8000-000000000001'),0::bigint,'Disabled blocks activation inspection');
select throws_ok($$select * from public.list_chatbot_flows_page('13100000-0000-4000-8000-000000000001')$$,'42501',null,'Disabled blocks listing RPC');
select throws_ok($$insert into public.chatbot_flows(organization_id,name) values ('13100000-0000-4000-8000-000000000001','Denied')$$,'42501',null,'Disabled blocks direct mutation');
select lives_ok($$select public.get_effective_module_permissions('13100000-0000-4000-8000-000000000001','chatbot_builder')$$,'Effective query remains available to explain unavailability');
select set_config('request.jwt.claims','{"sub":"13110000-0000-4000-8000-000000000001"}',true);
select ok(public.has_module_permission('13100000-0000-4000-8000-000000000002','chatbot_builder','manage'),'Other organization stays enabled independently');
select set_config('request.jwt.claims','{"sub":"13110000-0000-4000-8000-000000000007"}',true);
select is(public.get_effective_module_permissions('13100000-0000-4000-8000-000000000001','chatbot_builder'),'{"enabled":false,"can_view":false,"can_manage":false,"revision":0}'::jsonb,'Outsider cannot read configuration');
reset role;
select set_config('request.jwt.claims','{}',true);
select set_config('request.headers','{"api-key":"availability-test-key"}',true);
set local role anon;
select ok(not public.has_module_permission('13100000-0000-4000-8000-000000000001','chatbot_builder','view') and not public.has_module_permission('13100000-0000-4000-8000-000000000001','chatbot_builder','manage'),'API-key role cannot bypass disabled builder');
reset role;
select is((select jsonb_agg(to_jsonb(v)) from public.chatbot_flow_versions v where v.organization_id='13100000-0000-4000-8000-000000000001'),(select versions from availability_before),'Draft and immutable published definitions unchanged');
select is((select to_jsonb(d) from public.chatbot_flow_deployments d where d.organization_id='13100000-0000-4000-8000-000000000001'),(select deployment from availability_before),'Activation selection unchanged');
set local role service_role;
select is((select count(*) from public.chatbot_flow_versions where id='13140000-0000-4000-8000-000000000001' and definition is not null),1::bigint,'Execution worker still reads the selected published definition');
select lives_ok($$select public.ensure_chatbot_runtime_agent('13100000-0000-4000-8000-000000000001')$$,'Internal execution identity is unaffected');
reset role;
select ok((select before_state->>'enabled'='true' and after_state->'result'->>'enabled'='false' from public.platform_admin_action_events where request_id='13150000-0000-4000-8000-000000000001'),'Audit records previous and new availability');
select is((select count(*) from public.platform_admin_action_events where organization_id='13100000-0000-4000-8000-000000000001'),2::bigint,'Only successful unique operations create audit records');
select set_config('request.headers','{}',true);
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"13110000-0000-4000-8000-000000000006"}',true);
select is(public.update_platform_module_permissions('13100000-0000-4000-8000-000000000001','chatbot_builder',(select value from availability_matrix),2,'13150000-0000-4000-8000-000000000003',true)->>'enabled','true','Re-enable restores stored matrix');
select set_config('request.jwt.claims','{"sub":"13110000-0000-4000-8000-000000000005"}',true);
select ok(public.has_module_permission('13100000-0000-4000-8000-000000000001','chatbot_builder','manage'),'Explicit Agent grant restored after re-enable');
select is((select count(*) from public.chatbot_flows where organization_id='13100000-0000-4000-8000-000000000001'),1::bigint,'Existing flow visible again without recreation');
reset role;
select * from finish();
rollback;
