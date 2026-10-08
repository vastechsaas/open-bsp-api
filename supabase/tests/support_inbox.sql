begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select no_plan();

insert into public.organizations(id,name,extra) values
 ('12500000-0000-4000-8000-000000000001','Support inbox A','{}'),
 ('12500000-0000-4000-8000-000000000002','Support inbox B','{}');
insert into auth.users(id,email,aud,role,raw_app_meta_data,raw_user_meta_data)
 values('12510000-0000-4000-8000-000000000001','inbox@example.test','authenticated','authenticated','{}','{}');
insert into public.agents(id,organization_id,user_id,name,ai,extra)
 values('12520000-0000-4000-8000-000000000001','12500000-0000-4000-8000-000000000001','12510000-0000-4000-8000-000000000001','Inbox agent',false,'{"role":"owner"}');
-- Retain an independent owner while exercising every role on the test agent.
insert into auth.users(id,email,aud,role,raw_app_meta_data,raw_user_meta_data)
 values('12510000-0000-4000-8000-000000000002','inbox-owner@example.test','authenticated','authenticated','{}','{}');
insert into public.agents(id,organization_id,user_id,name,ai,extra)
 values('12520000-0000-4000-8000-000000000002','12500000-0000-4000-8000-000000000001','12510000-0000-4000-8000-000000000002','Retained owner',false,'{"role":"owner"}');
insert into public.organizations_addresses(organization_id,service,address,status,extra)
 select '12500000-0000-4000-8000-000000000001','whatsapp',address,'connected','{}'
 from unnest(array['node-inbox','native-inbox','passthrough-inbox']) address;
insert into public.chatbot_node_bridges(organization_id,organization_address,node_company_id,engine,sync_status) values
 ('12500000-0000-4000-8000-000000000001','node-inbox','125','node','active'),
 ('12500000-0000-4000-8000-000000000001','native-inbox','126','native','disabled');
insert into public.conversations(id,organization_id,service,organization_address,contact_address,assigned_agent_id)
 select ('12530000-0000-4000-8000-' || lpad(i::text,12,'0'))::uuid,
 '12500000-0000-4000-8000-000000000001','whatsapp',
 case i when 7 then 'native-inbox' when 8 then 'passthrough-inbox' else 'node-inbox' end,
 '92300125' || i, '12520000-0000-4000-8000-000000000001'
 from generate_series(1,8) i;
insert into public.messages(id,organization_id,conversation_id,direction,external_id,service,organization_address,contact_address,content,status,timestamp)
 select ('12540000-0000-4000-8000-' || lpad(i::text,12,'0'))::uuid,
 '12500000-0000-4000-8000-000000000001',('12530000-0000-4000-8000-' || lpad(i::text,12,'0'))::uuid,
 'incoming','wamid.inbox.' || i,'whatsapp',case i when 7 then 'native-inbox' when 8 then 'passthrough-inbox' else 'node-inbox' end,
 '92300125' || i,'{"version":"1","type":"text","kind":"text","text":"Stored history"}','{}',now()
 from generate_series(1,8) i;
insert into public.chatbot_node_conversations(organization_id,organization_address,node_conversation_id,conversation_id,human_owned,lifecycle_enabled,state,support_request,closed_at)
 select '12500000-0000-4000-8000-000000000001','node-inbox',i::text,
 ('12530000-0000-4000-8000-' || lpad(i::text,12,'0'))::uuid,i=3,true,
 case when i=3 then 'human_owned' when i=5 then 'closed' else 'bot_ready' end,
 jsonb_build_object('status',case i when 2 then 'waiting' when 3 then 'handling' when 4 then 'released' else 'resolved' end),
 case when i=5 then now() end
 from generate_series(2,5) i;
update public.conversations set status='closed' where id in ('12530000-0000-4000-8000-000000000005','12530000-0000-4000-8000-000000000006');
insert into public.message_mentions(organization_id,message_id,mentioned_agent_id)
 select organization_id,id,'12520000-0000-4000-8000-000000000001' from public.messages
 where id in ('12540000-0000-4000-8000-000000000001','12540000-0000-4000-8000-000000000002');
select set_config('request.jwt.claim.sub','12510000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;
select is((select count(*) from public.get_support_inbox_visibility('12500000-0000-4000-8000-000000000001',array(select id from public.conversations)) where visible),5::bigint,'Waiting, human, resolved Closed, native and passthrough visible');
select is((select count(*) from public.conversations),8::bigint,'Inbox filtering does not restrict conversation access');
select is((select count(*) from public.messages),8::bigint,'Hidden bot history remains readable');
select is(public.is_support_inbox_visible('12500000-0000-4000-8000-000000000001','12530000-0000-4000-8000-000000000001'),false,'Assignment and mention cannot expose unmapped bot chat');
select is(public.is_support_inbox_visible('12500000-0000-4000-8000-000000000001','12530000-0000-4000-8000-000000000004'),false,'Released support is hidden despite assignment');
select is((select count(*) from public.get_conversation_queue_conversations('12500000-0000-4000-8000-000000000001','all_active')),4::bigint,'Queue filtering happens server-side');
select is((select max(total_count) from public.list_mentioned_conversations_page('12500000-0000-4000-8000-000000000001',1,10)),1::bigint,'Mentioned counts only eligible support before pagination');
select is((select count(*) from public.list_mentioned_conversations_page('12500000-0000-4000-8000-000000000001',1,10,'not found')),0::bigint,'Search cannot bypass predicate');
select throws_ok($$select * from public.get_support_inbox_visibility('12500000-0000-4000-8000-000000000002','{}')$$,'42501',null,'Other organization denied');
select throws_ok($$select * from public.get_support_inbox_visibility('12500000-0000-4000-8000-000000000001',array_fill('12530000-0000-4000-8000-000000000001'::uuid,array[501]))$$,'22023',null,'Batch capped at 500');
select is((select count(*) from public.get_support_inbox_visibility('12500000-0000-4000-8000-000000000001','{}')),0::bigint,'Empty batch valid');
reset role;

-- All conversation roles use the same presentation rule; existing RLS stays intact.
update public.agents set extra='{"role":"member"}' where id='12520000-0000-4000-8000-000000000001';
set local role authenticated;
select is((select count(*) from public.get_support_inbox_visibility('12500000-0000-4000-8000-000000000001',array(select id from public.conversations)) where visible),5::bigint,'Member eligibility');
reset role;
update public.agents set extra='{"role":"supervisor"}' where id='12520000-0000-4000-8000-000000000001';
set local role authenticated;
select is((select count(*) from public.get_support_inbox_visibility('12500000-0000-4000-8000-000000000001',array(select id from public.conversations)) where visible),5::bigint,'Supervisor eligibility');
reset role;
update public.agents set extra='{"role":"admin"}' where id='12520000-0000-4000-8000-000000000001';
set local role authenticated;
select is((select count(*) from public.get_support_inbox_visibility('12500000-0000-4000-8000-000000000001',array(select id from public.conversations)) where visible),5::bigint,'Admin eligibility');
reset role;
update public.agents set extra='{"role":"agent"}' where id='12520000-0000-4000-8000-000000000001';
set local role authenticated;
select is((select count(*) from public.get_support_inbox_visibility('12500000-0000-4000-8000-000000000001',array(select id from public.conversations)) where visible),5::bigint,'Assigned Agent eligibility and closed history');
select is((select count(*) from public.get_conversation_queue_conversations('12500000-0000-4000-8000-000000000001','assigned')),4::bigint,'Agent assigned queue excludes bot-only');
reset role;
update public.agents set extra='{"role":"owner"}' where id='12520000-0000-4000-8000-000000000001';
insert into public.platform_admins(user_id,active) values('12510000-0000-4000-8000-000000000001',true);
set local role authenticated;
select is((select count(*) from public.get_support_inbox_visibility('12500000-0000-4000-8000-000000000001',array(select id from public.conversations)) where visible),5::bigint,'Authorized platform admin follows same inbox rule');
reset role;
select set_config('request.jwt.claim.role','service_role',true);
update public.chatbot_node_conversations set state='bot_active',support_request='{"status":"resolved"}' where node_conversation_id='5';
update public.conversations set status='active' where id='12530000-0000-4000-8000-000000000005';
select is(public.is_support_inbox_visible('12500000-0000-4000-8000-000000000001','12530000-0000-4000-8000-000000000005'),false,'Fresh restart hides resolved support despite retained closed_at');
update public.chatbot_node_conversations set pending_request_id='12550000-0000-4000-8000-000000000001' where node_conversation_id='4';
select is(public.is_support_inbox_visible('12500000-0000-4000-8000-000000000001','12530000-0000-4000-8000-000000000004'),true,'Pending human lifecycle stays visible until confirmation');
update public.chatbot_node_conversations set pending_request_id=null,support_request='{"status":"waiting"}' where node_conversation_id='4';
select is(public.is_support_inbox_visible('12500000-0000-4000-8000-000000000001','12530000-0000-4000-8000-000000000004'),true,'Subsequent escalation reappears');
select ok(exists(select 1 from pg_trigger where tgname='broadcast_node_conversation_inbox_change'),'Mapping transitions emit invalidation');
select ok(exists(select 1 from pg_trigger where tgname='broadcast_node_binding_inbox_change'),'Binding transitions emit invalidation');
select ok(not has_function_privilege('anon','public.get_support_inbox_visibility(uuid,uuid[])','execute'),'Anonymous cannot query eligibility');
select * from finish();
rollback;
