begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select no_plan();

insert into public.organizations(id,name,extra)
select '13000000-0000-4000-8000-000000000001','Shared handoff fixture',
  jsonb_build_object('business_hours',jsonb_build_object(
    'enabled',false,'mode','all_days','timezone','UTC',
    'all_days',jsonb_build_object('start_time','00:00','end_time','24:00'),
    'per_day',(select jsonb_object_agg(d,jsonb_build_object('enabled',true,'start_time','00:00','end_time','24:00'))
      from unnest(array['monday','tuesday','wednesday','thursday','friday','saturday','sunday']) d),
    'handoff_message','Shared acknowledgment.','outside_hours_message','Outside hours.','no_agents_message','No agents.'));
insert into auth.users(id,email,aud,role,raw_app_meta_data,raw_user_meta_data)
values('13010000-0000-4000-8000-000000000001','handoff-fixture@example.invalid','authenticated','authenticated','{}','{}');
insert into public.agents(id,organization_id,user_id,name,ai,extra)
values('13020000-0000-4000-8000-000000000001','13000000-0000-4000-8000-000000000001',
  '13010000-0000-4000-8000-000000000001','Agent',false,'{"role":"agent"}');
insert into public.organizations_addresses(organization_id,service,address,status,extra)
values('13000000-0000-4000-8000-000000000001','whatsapp','900000130','connected','{}');
insert into public.chatbot_node_bridges(organization_id,organization_address,node_company_id,engine,sync_status)
values('13000000-0000-4000-8000-000000000001','900000130','130','node','active');
insert into public.routing_queues(organization_id,id,name)
values('13000000-0000-4000-8000-000000000001','13050000-0000-4000-8000-000000000001','Support');
insert into public.routing_queue_members(organization_id,routing_queue_id,agent_id)
values('13000000-0000-4000-8000-000000000001','13050000-0000-4000-8000-000000000001','13020000-0000-4000-8000-000000000001');
insert into public.conversations(id,organization_id,service,organization_address,contact_address)
values('13030000-0000-4000-8000-000000000001','13000000-0000-4000-8000-000000000001','whatsapp','900000130','92300130001');
insert into public.messages(organization_id,conversation_id,external_id,direction,contact_address,service,organization_address,content,timestamp)
values('13000000-0000-4000-8000-000000000001','13030000-0000-4000-8000-000000000001','wamid.shared-handoff','incoming',
  '92300130001','whatsapp','900000130','{"version":"1","type":"text","kind":"text","text":"Help"}',now());
create temporary table handoff_fixture as select jsonb_build_object(
  'id','13040000-0000-4000-8000-000000000001','status','waiting',
  'target',jsonb_build_object('routing_queue_id','13050000-0000-4000-8000-000000000001'),
  'source_wamid','wamid.shared-handoff','requested_at',now(),'reason','Support') as request;

select lives_ok($$select public.record_node_support_request('13000000-0000-4000-8000-000000000001','900000130','92300130001','130',
  '13060000-0000-4000-8000-000000000001','1',(select request from handoff_fixture),'{"text":"Existing custom wording."}')$$,
  'Managed support request routes and sends one durable acknowledgment');
select is((select count(*) from public.messages where direction='outgoing'),1::bigint,'Exactly one outgoing message');
select is((select content->>'text' from public.messages where direction='outgoing'),'Existing custom wording.','Custom branch wording is preserved');
select is((select human_owned from public.chatbot_node_conversations where node_conversation_id='130'),false,'Acknowledgment does not pause the bot');
select public.record_node_support_request('13000000-0000-4000-8000-000000000001','900000130','92300130001','130',
  '13060000-0000-4000-8000-000000000001','1',(select request from handoff_fixture),'{"text":"Changed on retry."}');
select is((select count(*) from public.messages where direction='outgoing'),1::bigint,'Duplicate delivery neither reroutes nor sends again');

update public.organizations set extra='{"business_hours":{"handoff_message":"Updated shared wording."}}' where id='13000000-0000-4000-8000-000000000001';
select public.record_node_support_request('13000000-0000-4000-8000-000000000001','900000130','92300130001','130',
  '13060000-0000-4000-8000-000000000002','1',(select request from handoff_fixture),'{"original_event_id":"13060000-0000-4000-8000-000000000001"}');
select ok(exists(select 1 from public.messages where content->>'text'='Updated shared wording.'),'Empty override uses latest Settings without republishing');
select is((select count(*) from public.conversation_routing_events where conversation_id='13030000-0000-4000-8000-000000000001'),1::bigint,'Repeat request never reroutes');
select throws_ok($$select public.record_node_support_request('13000000-0000-4000-8000-000000000001','900000130','92300130001','130',
  '13060000-0000-4000-8000-000000000099','1',(select request from handoff_fixture),'{"original_event_id":"13060000-0000-4000-8000-000000000098"}')$$,
  '40001',null,'Out-of-order acknowledgment retries until initial routing exists');
select throws_ok($$select public.record_node_support_request('13000000-0000-4000-8000-000000000002','900000130','92300130001','130',
  '13060000-0000-4000-8000-000000000001','1',(select request from handoff_fixture),'{}')$$,'42501',null,'Receipts are tenant scoped');
select throws_ok($$update public.organizations set extra='{"business_hours":{"handoff_message":""}}' where id='13000000-0000-4000-8000-000000000001'$$,
  '22023',null,'Blank default cannot silently erase acknowledgments');
select throws_ok($$update public.organizations set extra=jsonb_build_object('business_hours',jsonb_build_object('handoff_message',repeat('x',4097))) where id='13000000-0000-4000-8000-000000000001'$$,
  '22023',null,'Shared message respects WhatsApp text limit');

update public.organizations set extra=jsonb_build_object('business_hours',jsonb_build_object('enabled',true,'holidays',
  jsonb_build_array(jsonb_build_object('date',to_char(now() at time zone 'UTC','YYYY-MM-DD'),'closed',true))))
where id='13000000-0000-4000-8000-000000000001';
select public.record_node_support_request('13000000-0000-4000-8000-000000000001','900000130','92300130001','130',
  '13060000-0000-4000-8000-000000000003','1',(select request from handoff_fixture),
  '{"original_event_id":"13060000-0000-4000-8000-000000000001","text":"Do not send this."}');
select is((select count(*) from public.messages where content->>'text'='Outside hours.'),1::bigint,'Outside-hours message replaces the override, not supplements it');
select is((select count(*) from public.messages where direction='outgoing'),3::bigint,'Outside hours sends one additional acknowledgment only');
update public.organizations set extra='{"business_hours":{"holidays":[]}}' where id='13000000-0000-4000-8000-000000000001';
select public.record_node_support_request('13000000-0000-4000-8000-000000000001','900000130','92300130001','130',
  '13060000-0000-4000-8000-000000000004','1',(select request from handoff_fixture),
  '{"original_event_id":"13060000-0000-4000-8000-000000000001","text":"Do not send this."}');
select is((select count(*) from public.messages where content->>'text'='No agents.'),1::bigint,'Open hours without fresh presence uses the no-agents message');
insert into public.agent_assignment_presence(organization_id,agent_id,available,last_heartbeat_at)
values('13000000-0000-4000-8000-000000000001','13020000-0000-4000-8000-000000000001',true,now());
select public.record_node_support_request('13000000-0000-4000-8000-000000000001','900000130','92300130001','130',
  '13060000-0000-4000-8000-000000000005','1',(select request from handoff_fixture),
  '{"original_event_id":"13060000-0000-4000-8000-000000000001","text":"Existing custom wording."}');
select is((select count(*) from public.messages where content->>'text'='Existing custom wording.'),2::bigint,'Available agents preserve custom wording');
select is((select count(*) from public.messages where direction='outgoing'),5::bigint,'Every support request has exactly one selected acknowledgment');
select public.notify_support_unavailability('13030000-0000-4000-8000-000000000001','legacy-available');
select is((select count(*) from public.messages where direction='outgoing'),5::bigint,'Legacy/native notice behavior stays unchanged');
update public.contacts_addresses set status='blocked' where organization_id='13000000-0000-4000-8000-000000000001' and address='92300130001';
select public.notify_support_unavailability('13030000-0000-4000-8000-000000000001','blocked',null,null,true);
select is((select count(*) from public.messages where direction='outgoing'),5::bigint,'Blocked contacts receive no acknowledgment');
update public.contacts_addresses set status='active' where organization_id='13000000-0000-4000-8000-000000000001' and address='92300130001';
update public.messages set timestamp=now()-interval '25 hours' where direction='incoming';
select public.notify_support_unavailability('13030000-0000-4000-8000-000000000001','expired',null,null,true);
select is((select count(*) from public.messages where direction='outgoing'),5::bigint,'Expired service window prevents sending');
update public.chatbot_node_conversations set human_owned=true,support_request=jsonb_set(support_request,'{status}','"handling"') where node_conversation_id='130';
select public.record_node_support_request('13000000-0000-4000-8000-000000000001','900000130','92300130001','130',
  '13060000-0000-4000-8000-000000000006','1',(select request from handoff_fixture),'{"original_event_id":"13060000-0000-4000-8000-000000000001"}');
select is((select count(*) from public.messages where direction='outgoing'),5::bigint,'Delayed waiting acknowledgment cannot speak after takeover');
select * from finish();
rollback;
