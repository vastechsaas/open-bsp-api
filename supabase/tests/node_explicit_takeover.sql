begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select no_plan();
insert into public.organizations(id,name,extra) values('12400000-0000-4000-8000-000000000001','Disposable resolution org','{}');
insert into auth.users(id,email,aud,role,raw_app_meta_data,raw_user_meta_data) values
 ('12410000-0000-4000-8000-000000000001','resolution-agent@example.test','authenticated','authenticated','{}','{}'),
 ('12410000-0000-4000-8000-000000000002','resolution-manager@example.test','authenticated','authenticated','{}','{}'),
 ('12410000-0000-4000-8000-000000000003','nonmember-agent@example.test','authenticated','authenticated','{}','{}');
insert into public.agents(id,organization_id,user_id,name,ai,extra) values
 ('12420000-0000-4000-8000-000000000001','12400000-0000-4000-8000-000000000001','12410000-0000-4000-8000-000000000001','Agent',false,'{"role":"agent"}'),
 ('12420000-0000-4000-8000-000000000002','12400000-0000-4000-8000-000000000001','12410000-0000-4000-8000-000000000002','Manager',false,'{"role":"supervisor"}'),
 ('12420000-0000-4000-8000-000000000003','12400000-0000-4000-8000-000000000001','12410000-0000-4000-8000-000000000003','Nonmember',false,'{"role":"agent"}');
insert into public.organizations_addresses(organization_id,service,address,status,extra)
 values('12400000-0000-4000-8000-000000000001','whatsapp','900000124','connected','{}');
insert into public.chatbot_node_bridges(organization_id,organization_address,node_company_id,engine,sync_status)
 values('12400000-0000-4000-8000-000000000001','900000124','124','node','active');
insert into public.conversations(id,organization_id,service,organization_address,contact_address,assigned_agent_id) values
 ('12430000-0000-4000-8000-000000000001','12400000-0000-4000-8000-000000000001','whatsapp','900000124','92300124001','12420000-0000-4000-8000-000000000001'),
 ('12430000-0000-4000-8000-000000000002','12400000-0000-4000-8000-000000000001','whatsapp','900000124','92300124002','12420000-0000-4000-8000-000000000002');
insert into public.messages(organization_id,conversation_id,external_id,direction,contact_address,service,organization_address,content,status,timestamp) values
 ('12400000-0000-4000-8000-000000000001','12430000-0000-4000-8000-000000000001','wamid.resolution.1','incoming','92300124001','whatsapp','900000124','{"version":"1","type":"text","kind":"text","text":"Help"}','{}',now()-interval '1 hour'),
 ('12400000-0000-4000-8000-000000000001','12430000-0000-4000-8000-000000000002','wamid.resolution.2','incoming','92300124002','whatsapp','900000124','{"version":"1","type":"text","kind":"text","text":"Help"}','{}',now()-interval '1 hour');
insert into public.chatbot_node_conversations(organization_id,organization_address,node_conversation_id,conversation_id,lifecycle_enabled,ownership_revision,last_inbound_wamid) values
 ('12400000-0000-4000-8000-000000000001','900000124','1','12430000-0000-4000-8000-000000000001',false,'0','wamid.resolution.1'),
 ('12400000-0000-4000-8000-000000000001','900000124','2','12430000-0000-4000-8000-000000000002',false,'0','wamid.resolution.2');
select set_config('request.jwt.claim.sub','12410000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claim.role','authenticated',true);

-- Source event arrives later than the bot-ready snapshot.
create temporary table support_fixtures(id integer primary key, request jsonb);
insert into support_fixtures values
 (1,jsonb_build_object('id','12440000-0000-4000-8000-000000000011','status','waiting',
 'target',jsonb_build_object('routing_queue_id','12450000-0000-4000-8000-000000000001'),
 'source_wamid','wamid.resolution.1','requested_at','2026-10-04T12:00:00Z','reason','Refund request')),
 (2,jsonb_build_object('id','12440000-0000-4000-8000-000000000012','status','waiting',
 'target',jsonb_build_object('routing_queue_id','12450000-0000-4000-8000-000000000001'),
 'source_wamid','wamid.resolution.2','requested_at','2026-10-04T12:00:00Z','reason','VIP support'));
insert into public.routing_queues(organization_id,id,name) values
 ('12400000-0000-4000-8000-000000000001','12450000-0000-4000-8000-000000000001','DKR mobile test');
insert into public.routing_queue_members(organization_id,routing_queue_id,agent_id) values
 ('12400000-0000-4000-8000-000000000001','12450000-0000-4000-8000-000000000001','12420000-0000-4000-8000-000000000001');
update public.conversations set assigned_agent_id=null;
select lives_ok($$select public.apply_node_conversation_lifecycle('12400000-0000-4000-8000-000000000001','900000124','1','92300124001','2','bot_ready','wamid.resolution.1',null,null,(select request from support_fixtures where id=1))$$,'A waiting snapshot can arrive first');
select lives_ok($$select public.record_node_support_request('12400000-0000-4000-8000-000000000001','900000124','92300124001','1','12440000-0000-4000-8000-000000000021','1',(select request from support_fixtures where id=1))$$,'Delayed support event still routes its original request');
select is((select routing_queue_id from public.conversations where id='12430000-0000-4000-8000-000000000001'),'12450000-0000-4000-8000-000000000001'::uuid,'Waiting support keeps its queue');
select is((select ownership_revision from public.chatbot_node_conversations where node_conversation_id='1'),'2','Routing does not regress ownership');
select is((select human_owned from public.chatbot_node_conversations where node_conversation_id='1'),false,'Request/assignment do not pause bot');
select lives_ok($$select public.record_node_support_request('12400000-0000-4000-8000-000000000001','900000124','92300124001','1','12440000-0000-4000-8000-000000000021','1',(select request from support_fixtures where id=1))$$,'Delivery duplicates do not route twice');
select is((select count(*) from public.chatbot_node_handoff_receipts),1::bigint,'One durable routing receipt');
select throws_ok($$select public.record_node_support_request('12400000-0000-4000-8000-000000000001','900000124','92300124002','2','12440000-0000-4000-8000-000000000022','1',jsonb_set((select request from support_fixtures where id=2),'{source_wamid}','"wamid.missing"'))$$,'40001',null,'Request retries when source message has not arrived');

select set_config('request.jwt.claim.sub','12410000-0000-4000-8000-000000000003',true);
set local role authenticated;
select throws_ok($$select public.begin_node_conversation_operation('12400000-0000-4000-8000-000000000001','12430000-0000-4000-8000-000000000001','12440000-0000-4000-8000-000000000034','takeover','wamid.resolution.1','2')$$,'42501',null,'Agent outside the queue cannot claim waiting support');
reset role;
select set_config('request.jwt.claim.sub','12410000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;
select throws_ok($$select public.begin_node_conversation_operation('12400000-0000-4000-8000-000000000099','12430000-0000-4000-8000-000000000001','12440000-0000-4000-8000-000000000035','takeover','wamid.resolution.1','2')$$,'42501',null,'Takeover cannot cross organization boundaries');
select throws_ok($$select public.begin_node_conversation_operation('12400000-0000-4000-8000-000000000001','12430000-0000-4000-8000-000000000001','12440000-0000-4000-8000-000000000036','takeover','wamid.resolution.1','1')$$,'40001',null,'Stale ownership revision cannot reserve takeover');
select lives_ok($$select public.begin_node_conversation_operation('12400000-0000-4000-8000-000000000001','12430000-0000-4000-8000-000000000001','12440000-0000-4000-8000-000000000031','takeover','wamid.resolution.1','2')$$,'Eligible queue agent claims and takes over');
select lives_ok($$select public.begin_node_conversation_operation('12400000-0000-4000-8000-000000000001','12430000-0000-4000-8000-000000000001','12440000-0000-4000-8000-000000000031','takeover','wamid.resolution.1','2')$$,'Stable takeover request is idempotent');
reset role;
select is((select assigned_agent_id from public.conversations where id='12430000-0000-4000-8000-000000000001'),'12420000-0000-4000-8000-000000000001'::uuid,'Claim reserved before remote call');
select is((select human_owned from public.chatbot_node_conversations where node_conversation_id='1'),false,'Reservation alone does not stop chatbot');
select throws_ok($$update public.conversations set assigned_agent_id=null where id='12430000-0000-4000-8000-000000000001'$$,'40001',null,'Competing assignment cannot bypass pending ownership');
select throws_ok($$insert into public.messages(organization_id,conversation_id,direction,agent_id,service,organization_address,content,status)
 values('12400000-0000-4000-8000-000000000001','12430000-0000-4000-8000-000000000001','outgoing','12420000-0000-4000-8000-000000000001','whatsapp','900000124','{"version":"1","type":"text","kind":"text","text":"Not yet"}',jsonb_build_object('pending',now()))$$,'42501',null,'Human sends blocked until confirmed');
select set_config('request.jwt.claim.sub','12410000-0000-4000-8000-000000000002',true);
set local role authenticated;
select throws_ok($$select public.begin_node_conversation_operation('12400000-0000-4000-8000-000000000001','12430000-0000-4000-8000-000000000001','12440000-0000-4000-8000-000000000032','takeover','wamid.resolution.1','2')$$,'23514',null,'Second claimant cannot reserve pending request');
reset role;
update public.chatbot_node_operations set status='in_flight' where request_id='12440000-0000-4000-8000-000000000031';
select lives_ok($$select public.complete_node_chatbot_operation('12440000-0000-4000-8000-000000000031','takeover',jsonb_build_object('revision','3','state','human_owned','last_inbound_wamid','wamid.resolution.1','support_request',jsonb_set((select request from support_fixtures where id=1),'{status}','"handling"')))$$,'Confirmed takeover atomically enables human ownership');
select is((select human_owned from public.chatbot_node_conversations where node_conversation_id='1'),true,'Ownership only changes on Node confirmation');
select is((select pending_request_id from public.chatbot_node_conversations where node_conversation_id='1'),null::uuid,'Confirmation releases pending guard');
select lives_ok($$select public.record_node_support_request('12400000-0000-4000-8000-000000000001','900000124','92300124001','1','12440000-0000-4000-8000-000000000023','1',(select request from support_fixtures where id=1))$$,'Stale request acknowledged without regaining bot ownership');
select is((select human_owned from public.chatbot_node_conversations where node_conversation_id='1'),true,'Old request cannot undo takeover');

-- Manager overrides use current authorization; they are not queue members.
select lives_ok($$select public.record_node_support_request('12400000-0000-4000-8000-000000000001','900000124','92300124002','2','12440000-0000-4000-8000-000000000022','1',(select request from support_fixtures where id=2))$$,'Second conversation routed independently');
set local role authenticated;
select lives_ok($$select public.begin_node_conversation_operation('12400000-0000-4000-8000-000000000001','12430000-0000-4000-8000-000000000002','12440000-0000-4000-8000-000000000033','takeover','wamid.resolution.2','1')$$,'Manager can take over unassigned queue request');
reset role;
select is((select support_request->'target'->>'routing_queue_id' from public.chatbot_node_conversations where node_conversation_id='2'),'12450000-0000-4000-8000-000000000001','Override retains original request queue');
select ok(not has_function_privilege('authenticated','public.record_node_support_request(uuid,text,text,text,uuid,text,jsonb)','execute'),'Browser cannot forge support events');
select ok(not has_function_privilege('authenticated','public.apply_node_conversation_lifecycle(uuid,text,text,text,text,text,text,text,uuid,jsonb)','execute'),'Browser cannot forge ownership');
select * from finish();
rollback;
