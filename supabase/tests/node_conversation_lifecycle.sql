begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select no_plan();
insert into public.organizations(id,name,extra) values('12300000-0000-4000-8000-000000000001','Disposable resolution org','{}');
insert into auth.users(id,email,aud,role,raw_app_meta_data,raw_user_meta_data) values
 ('12310000-0000-4000-8000-000000000001','resolution-agent@example.test','authenticated','authenticated','{}','{}'),
 ('12310000-0000-4000-8000-000000000002','resolution-manager@example.test','authenticated','authenticated','{}','{}');
insert into public.agents(id,organization_id,user_id,name,ai,extra) values
 ('12320000-0000-4000-8000-000000000001','12300000-0000-4000-8000-000000000001','12310000-0000-4000-8000-000000000001','Agent',false,'{"role":"agent"}'),
 ('12320000-0000-4000-8000-000000000002','12300000-0000-4000-8000-000000000001','12310000-0000-4000-8000-000000000002','Manager',false,'{"role":"supervisor"}');
insert into public.organizations_addresses(organization_id,service,address,status,extra)
 values('12300000-0000-4000-8000-000000000001','whatsapp','900000123','connected','{}');
insert into public.chatbot_node_bridges(organization_id,organization_address,node_company_id,engine,sync_status)
 values('12300000-0000-4000-8000-000000000001','900000123','123','node','active');
insert into public.conversations(id,organization_id,service,organization_address,contact_address,assigned_agent_id) values
 ('12330000-0000-4000-8000-000000000001','12300000-0000-4000-8000-000000000001','whatsapp','900000123','92300123001','12320000-0000-4000-8000-000000000001'),
 ('12330000-0000-4000-8000-000000000002','12300000-0000-4000-8000-000000000001','whatsapp','900000123','92300123002','12320000-0000-4000-8000-000000000002');
insert into public.messages(organization_id,conversation_id,external_id,direction,contact_address,service,organization_address,content,status,timestamp) values
 ('12300000-0000-4000-8000-000000000001','12330000-0000-4000-8000-000000000001','wamid.resolution.1','incoming','92300123001','whatsapp','900000123','{"version":"1","type":"text","kind":"text","text":"Help"}','{}',now()-interval '1 hour'),
 ('12300000-0000-4000-8000-000000000001','12330000-0000-4000-8000-000000000002','wamid.resolution.2','incoming','92300123002','whatsapp','900000123','{"version":"1","type":"text","kind":"text","text":"Help"}','{}',now()-interval '1 hour');
insert into public.chatbot_node_conversations(organization_id,organization_address,node_conversation_id,conversation_id,lifecycle_enabled,ownership_revision,last_inbound_wamid) values
 ('12300000-0000-4000-8000-000000000001','900000123','1','12330000-0000-4000-8000-000000000001',true,'1','wamid.resolution.1'),
 ('12300000-0000-4000-8000-000000000001','900000123','2','12330000-0000-4000-8000-000000000002',true,'1','wamid.resolution.2');
select set_config('request.jwt.claim.sub','12310000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;
select lives_ok($$select public.begin_node_conversation_operation('12300000-0000-4000-8000-000000000001','12330000-0000-4000-8000-000000000001','12340000-0000-4000-8000-000000000001','resolve-and-close','wamid.resolution.1','1')$$,'Assigned agent can resolve');
select lives_ok($$select public.begin_node_conversation_operation('12300000-0000-4000-8000-000000000001','12330000-0000-4000-8000-000000000001','12340000-0000-4000-8000-000000000001','resolve-and-close','wamid.resolution.1','1')$$,'Duplicate request idempotent');
reset role;
update public.chatbot_node_operations set status='failed' where request_id='12340000-0000-4000-8000-000000000001';
update public.chatbot_node_conversations set pending_request_id=null where conversation_id='12330000-0000-4000-8000-000000000001';
set local role authenticated;
select lives_ok($$select public.begin_node_conversation_operation('12300000-0000-4000-8000-000000000001','12330000-0000-4000-8000-000000000001','12340000-0000-4000-8000-000000000001','resolve-and-close','wamid.resolution.1','1')$$,'Failed request retry atomically restores its pending guard');
reset role;
select is((select status from public.chatbot_node_operations where request_id='12340000-0000-4000-8000-000000000001'),'reconciling','Manual retry reconciles the same operation');
set local role authenticated;
select throws_ok($$select public.begin_node_conversation_operation('12300000-0000-4000-8000-000000000001','12330000-0000-4000-8000-000000000001','12340000-0000-4000-8000-000000000099','resume','wamid.resolution.1','1')$$,'42501',null,'Agent cannot manually resume');
select throws_ok($$select public.begin_node_conversation_operation('12300000-0000-4000-8000-000000000001','12330000-0000-4000-8000-000000000002','12340000-0000-4000-8000-000000000098','resolve-and-close','wamid.resolution.2','1')$$,'42501',null,'Another agent conversation is protected');
select is((select status from public.conversations where id='12330000-0000-4000-8000-000000000001'),'active','Pending close remains active');
select throws_ok($$update public.conversations set status='closed' where id='12330000-0000-4000-8000-000000000001'$$,
 '42501',null,'Generic REST status changes cannot bypass Node confirmation');
select throws_ok($$insert into public.messages(organization_id,conversation_id,direction,agent_id,service,organization_address,content,status)
 values('12300000-0000-4000-8000-000000000001','12330000-0000-4000-8000-000000000001','outgoing','12320000-0000-4000-8000-000000000001','whatsapp','900000123','{"version":"1","type":"text","kind":"text","text":"Late reply"}',jsonb_build_object('pending',now()))$$,'42501',null,'Pending closure blocks human sends at database boundary');
reset role;
select is((select engine from public.chatbot_node_bridges where node_company_id='123'),'node','Conversation operation does not change number engine');
select is((select count(*) from public.chatbot_node_operations where conversation_id='12330000-0000-4000-8000-000000000001'),1::bigint,'Duplicate creates one operation');
select set_config('request.jwt.claim.sub','12310000-0000-4000-8000-000000000002',true);
set local role authenticated;
select lives_ok($$select public.begin_node_conversation_operation('12300000-0000-4000-8000-000000000001','12330000-0000-4000-8000-000000000002','12340000-0000-4000-8000-000000000002','resume','wamid.resolution.2','1')$$,'Managers may return another conversation without number-wide blocking');
reset role;
insert into public.messages(organization_id,conversation_id,external_id,direction,contact_address,service,organization_address,content,status,timestamp)
 values('12300000-0000-4000-8000-000000000001','12330000-0000-4000-8000-000000000002','wamid.resolution.race','incoming','92300123002','whatsapp','900000123','{"version":"1","type":"text","kind":"text","text":"Wait"}','{}',now()-interval '1 hour');
select throws_ok($$select public.apply_node_conversation_lifecycle('12300000-0000-4000-8000-000000000001','900000123','2','92300123002','2','closed','wamid.resolution.2')$$,
 '40001',null,'Close ACK cannot hide a new raw webhook while its reopen event is delayed');
select is((select status from public.conversations where id='12330000-0000-4000-8000-000000000002'),'active','Racing new message remains visible');
update public.chatbot_node_operations set status='in_flight' where request_id='12340000-0000-4000-8000-000000000001';
select lives_ok($$select public.complete_node_chatbot_operation('12340000-0000-4000-8000-000000000001','resolve-and-close','{"revision":"2","state":"closed","last_inbound_wamid":"wamid.resolution.1"}')$$,'Node confirmation closes atomically');
select is((select status from public.conversations where id='12330000-0000-4000-8000-000000000001'),'closed','Acknowledged close is visible');
select is((select assigned_agent_id from public.conversations where id='12330000-0000-4000-8000-000000000001'),'12320000-0000-4000-8000-000000000001'::uuid,'Resolving agent retains closed history access');
insert into public.messages(organization_id,external_id,direction,contact_address,service,organization_address,content,status,timestamp)
 values('12300000-0000-4000-8000-000000000001','wamid.resolution.new','incoming','92300123001','whatsapp','900000123','{"version":"1","type":"text","kind":"text","text":"Thanks"}','{}',now()-interval '1 hour');
select is((select conversation_id from public.messages where external_id='wamid.resolution.new'),'12330000-0000-4000-8000-000000000001'::uuid,'New inbound reuses the original closed thread');
select is((select status from public.conversations where id='12330000-0000-4000-8000-000000000001'),'active','Even Thanks reopens; no acknowledgment filtering');
select is((select assigned_agent_id from public.conversations where id='12330000-0000-4000-8000-000000000001'),null::uuid,'Old assignment is released on reopening');
select lives_ok($$select public.apply_node_conversation_lifecycle('12300000-0000-4000-8000-000000000001','900000123','1','92300123001','3','bot_active','wamid.resolution.new','wamid.resolution.new')$$,'Reopen event advances revision');
select lives_ok($$select public.apply_node_conversation_lifecycle('12300000-0000-4000-8000-000000000001','900000123','1','92300123001','2','closed','wamid.resolution.1')$$,'Delayed close event is ignored');
select is((select status from public.conversations where id='12330000-0000-4000-8000-000000000001'),'active','Old close cannot hide new messages');
select lives_ok($$select public.record_node_chatbot_handoff('12300000-0000-4000-8000-000000000001','900000123','92300123001','wamid.resolution.1','1','12340000-0000-4000-8000-000000000003','12320000-0000-4000-8000-000000000001',null,'1')$$,'Stale handoff is acknowledged without assignment');
select is((select assigned_agent_id from public.conversations where id='12330000-0000-4000-8000-000000000001'),null::uuid,'Stale handoff cannot regain ownership');
select throws_ok($$select public.apply_node_conversation_lifecycle('12300000-0000-4000-8000-000000000001','900000123','1','92300123001','4','human_owned','wamid.not-arrived','wamid.not-arrived')$$,'40001',null,'Lifecycle waits for exact customer message arrival');
select ok(not has_function_privilege('authenticated','public.apply_node_conversation_lifecycle(uuid,text,text,text,text,text,text,text,uuid,jsonb)','execute'),'Client cannot forge Node ownership state');
select * from finish();
rollback;
