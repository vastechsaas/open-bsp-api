begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select no_plan();
insert into public.organizations(id,name,extra) values
 ('73500000-0000-4000-8000-000000000001','Counter org','{}'),
 ('73500000-0000-4000-8000-000000000002','Other counter org','{}');
insert into auth.users(id,email,aud,role,raw_app_meta_data,raw_user_meta_data) values
 ('73510000-0000-4000-8000-000000000001','counter@example.test','authenticated','authenticated','{}','{}'),
 ('73510000-0000-4000-8000-000000000002','counter-owner@example.test','authenticated','authenticated','{}','{}'),
 ('73510000-0000-4000-8000-000000000003','counter-agent@example.test','authenticated','authenticated','{}','{}'),
 ('73510000-0000-4000-8000-000000000004','counter-supervisor@example.test','authenticated','authenticated','{}','{}');
insert into public.agents(id,organization_id,user_id,name,ai,extra) values
 ('73520000-0000-4000-8000-000000000001','73500000-0000-4000-8000-000000000001','73510000-0000-4000-8000-000000000001','Test user',false,'{"role":"owner"}'),
 ('73520000-0000-4000-8000-000000000002','73500000-0000-4000-8000-000000000001','73510000-0000-4000-8000-000000000002','Retained owner',false,'{"role":"owner"}'),
 ('73520000-0000-4000-8000-000000000003','73500000-0000-4000-8000-000000000001','73510000-0000-4000-8000-000000000003','Test agent',false,'{"role":"agent"}'),
 ('73520000-0000-4000-8000-000000000004','73500000-0000-4000-8000-000000000001','73510000-0000-4000-8000-000000000004','Test supervisor',false,'{"role":"supervisor"}');
insert into public.organizations_addresses(organization_id,service,address,status,extra)
 select '73500000-0000-4000-8000-000000000001','whatsapp',address,'connected','{}'
 from unnest(array['counter-native','counter-node']) address;
insert into public.routing_queues(id,organization_id,name) values
 ('73530000-0000-4000-8000-000000000001','73500000-0000-4000-8000-000000000001','Counter VIP'),
 ('73530000-0000-4000-8000-000000000002','73500000-0000-4000-8000-000000000001','Counter Mobile');
insert into public.routing_queue_members(organization_id,routing_queue_id,agent_id)
 values('73500000-0000-4000-8000-000000000001','73530000-0000-4000-8000-000000000001','73520000-0000-4000-8000-000000000003'),
 ('73500000-0000-4000-8000-000000000001','73530000-0000-4000-8000-000000000001','73520000-0000-4000-8000-000000000002');
insert into public.chatbot_node_bridges(organization_id,organization_address,node_company_id,engine,sync_status)
 values('73500000-0000-4000-8000-000000000001','counter-node','735','node','active');
insert into public.conversations(id,organization_id,service,organization_address,contact_address,assigned_agent_id,routing_queue_id,status)
 select ('73540000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,
 '73500000-0000-4000-8000-000000000001','whatsapp',
 case when i=80 then 'counter-node' else 'counter-native' end,'counter-'||i,
 case when i%3=0 then '73520000-0000-4000-8000-000000000003'::uuid
      when i%3=1 then '73520000-0000-4000-8000-000000000002'::uuid else null end,
 case when i%3<>2 or i%2=0 then '73530000-0000-4000-8000-000000000001'::uuid
      else '73530000-0000-4000-8000-000000000002'::uuid end,
 case i when 1 then 'closed' when 2 then 'spam' else 'active' end
 from generate_series(1,80) i;
insert into public.messages(id,organization_id,conversation_id,direction,external_id,service,organization_address,contact_address,content,status,timestamp)
 select ('73550000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,
 '73500000-0000-4000-8000-000000000001',('73540000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,
 'incoming','wamid.counter.'||i,'whatsapp',case when i=80 then 'counter-node' else 'counter-native' end,
 'counter-'||i,'{"version":"1","type":"text","kind":"text","text":"Fixture"}','{}',
 now() - case when i%2=0 then interval '25 hours' else interval '1 minute' end
 from generate_series(1,80) i;
insert into public.message_mentions(organization_id,message_id,mentioned_agent_id)
 select organization_id,id,agents.agent_id from public.messages
 cross join (values ('73520000-0000-4000-8000-000000000001'::uuid),('73520000-0000-4000-8000-000000000003'::uuid)) agents(agent_id)
 where id in ('73550000-0000-4000-8000-000000000003','73550000-0000-4000-8000-000000000080');
select set_config('request.jwt.claim.sub','73510000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;
select is((select count from public.get_conversation_queue_counts('73500000-0000-4000-8000-000000000001') where key='all_active'),77::bigint,'Complete totals exceed preview page size and exclude hidden bot chat');
select is((select count from public.get_conversation_queue_counts('73500000-0000-4000-8000-000000000001') where key='mentioned'),1::bigint,'Mentions cannot reveal hidden bot-only chats');
select ok((select sum(count)>79 from public.get_conversation_queue_counts('73500000-0000-4000-8000-000000000001')),'Views overlap, not a partition');
select ok(not exists (
 select 1 from public.get_conversation_queue_counts('73500000-0000-4000-8000-000000000001') q
 where q.count <> (select count(*) from public.get_conversation_queue_conversations('73500000-0000-4000-8000-000000000001',q.key,500))
),'Owner totals match all existing view predicates');
select ok(not exists (
 select 1 from public.get_conversation_queue_counts('73500000-0000-4000-8000-000000000001','73530000-0000-4000-8000-000000000001') q
 where q.count <> (select count(*) from public.get_conversation_queue_conversations('73500000-0000-4000-8000-000000000001',q.key,500,0,'73530000-0000-4000-8000-000000000001'))
),'Routing-filter totals match existing views, including Mentioned scope');
select throws_ok($$select * from public.get_conversation_queue_counts('73500000-0000-4000-8000-000000000002')$$,'42501',null,'Cross-tenant totals denied');
select throws_ok($$select * from public.get_conversation_queue_counts('73500000-0000-4000-8000-000000000001','73530000-0000-4000-8000-000000000099')$$,'42501',null,'Unknown queue denied');
reset role;
select set_config('request.jwt.claim.sub','73510000-0000-4000-8000-000000000004',true);
set local role authenticated;
select is((select count(*) from public.get_conversation_queue_counts('73500000-0000-4000-8000-000000000001')),7::bigint,'Supervisor retains seven existing views');
select ok(not exists (
 select 1 from public.get_conversation_queue_counts('73500000-0000-4000-8000-000000000001') q
 where q.count <> (select count(*) from public.get_conversation_queue_conversations('73500000-0000-4000-8000-000000000001',q.key,500))
),'Supervisor totals match existing view access');
reset role;
select set_config('request.jwt.claim.sub','73510000-0000-4000-8000-000000000003',true);
set local role authenticated;
select is((select count(*) from public.get_conversation_queue_counts('73500000-0000-4000-8000-000000000001')),6::bigint,'Agent retains six views, without All active');
select ok(not exists (
 select 1 from public.get_conversation_queue_counts('73500000-0000-4000-8000-000000000001') q
 where q.count <> (select count(*) from public.get_conversation_queue_conversations('73500000-0000-4000-8000-000000000001',q.key,500))
),'Agent totals respect assignment and RLS');
select is((select count from public.get_conversation_queue_counts('73500000-0000-4000-8000-000000000001') where key='closed'),0::bigint,'Zero is a successful empty result, not an error');
select throws_ok($$select * from public.get_conversation_queue_counts('73500000-0000-4000-8000-000000000001','73530000-0000-4000-8000-000000000002')$$,'42501',null,'Agent cannot count another routing queue');
select ok(not has_function_privilege('anon','public.get_conversation_queue_counts(uuid,uuid)','execute'),'Anonymous cannot query counters');
select * from finish();
rollback;
