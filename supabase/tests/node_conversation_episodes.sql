begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public,auth;
select no_plan();
insert into public.organizations(id,name,extra) values('12700000-0000-4000-8000-000000000001','Disposable episodes','{}');
insert into auth.users(id,email,aud,role,raw_app_meta_data,raw_user_meta_data) values
 ('12710000-0000-4000-8000-000000000001','episode-agent@example.test','authenticated','authenticated','{}','{}'),
 ('12710000-0000-4000-8000-000000000002','episode-manager@example.test','authenticated','authenticated','{}','{}');
insert into public.agents(id,organization_id,user_id,name,ai,extra) values
 ('12720000-0000-4000-8000-000000000001','12700000-0000-4000-8000-000000000001','12710000-0000-4000-8000-000000000001','Agent',false,'{"role":"agent"}'),
 ('12720000-0000-4000-8000-000000000002','12700000-0000-4000-8000-000000000001','12710000-0000-4000-8000-000000000002','Manager',false,'{"role":"supervisor"}');
insert into public.organizations_addresses(organization_id,service,address,status,extra)
 values('12700000-0000-4000-8000-000000000001','whatsapp','900000127','connected','{}');
insert into public.chatbot_node_bridges(organization_id,organization_address,node_company_id,engine,sync_status)
 values('12700000-0000-4000-8000-000000000001','900000127','127','node','active');
create temporary table episodes(number integer primary key,id uuid);
insert into episodes values(1,public.resolve_node_conversation_episode('12700000-0000-4000-8000-000000000001','900000127','92300127001','1271',1));
select is(public.resolve_node_conversation_episode('12700000-0000-4000-8000-000000000001','900000127','92300127001','1271',1),(select id from episodes where number=1),'Duplicate episode has one mapping');
select throws_ok($$select public.resolve_node_conversation_episode('12700000-0000-4000-8000-000000000001','900000127','92300127001','1272',2,'1271')$$,'40001',null,'Successor waits for predecessor closure');
select throws_ok($$select public.resolve_node_conversation_episode('12700000-0000-4000-8000-000000000001','900000127','92300127001','1273',1)$$,'23514',null,'Cannot invent another first episode for same customer');
insert into public.messages(organization_id,conversation_id,external_id,direction,contact_address,service,organization_address,content,status,timestamp)
 select '12700000-0000-4000-8000-000000000001',id,'wamid.episode.1','incoming','92300127001','whatsapp','900000127','{"version":"1","type":"text","kind":"text","text":"Help"}','{}',now()-interval '1 hour' from episodes where number=1;
select lives_ok($$select public.apply_node_conversation_lifecycle('12700000-0000-4000-8000-000000000001','900000127','1271','92300127001','1','human_owned','wamid.episode.1')$$,'Confirmed takeover is human owned');
update public.conversations set assigned_agent_id='12720000-0000-4000-8000-000000000001' where id=(select id from episodes where number=1);
select lives_ok($$select public.apply_node_conversation_lifecycle('12700000-0000-4000-8000-000000000001','900000127','1271','92300127001','2','closed','wamid.episode.1')$$,'Confirmed closure ends first episode');
insert into episodes values(2,public.resolve_node_conversation_episode('12700000-0000-4000-8000-000000000001','900000127','92300127001','1272',2,'1271'));
select isnt((select id from episodes where number=1),(select id from episodes where number=2),'Successor is a distinct thread');
select is((select assigned_agent_id from public.conversations where id=(select id from episodes where number=2)),null::uuid,'Successor does not inherit previous agent');
insert into public.messages(organization_id,conversation_id,external_id,direction,contact_address,service,organization_address,content,status,timestamp)
 select '12700000-0000-4000-8000-000000000001',id,'wamid.episode.2','incoming','92300127001','whatsapp','900000127','{"version":"1","type":"text","kind":"text","text":"Hello again"}','{}',now()-interval '1 hour' from episodes where number=2;
select is((select status from public.conversations where id=(select id from episodes where number=1)),'closed','New input cannot reopen predecessor');
select throws_ok($$insert into public.messages(organization_id,external_id,direction,contact_address,service,organization_address,content,status,timestamp)
 values('12700000-0000-4000-8000-000000000001','wamid.guess','incoming','92300127001','whatsapp','900000127','{"version":"1","type":"text","kind":"text","text":"No context"}','{}',now()-interval '1 hour')$$,'40001',null,'Missing identity retries instead of guessing thread');
select lives_ok($$select public.apply_node_conversation_lifecycle('12700000-0000-4000-8000-000000000001','900000127','1271','92300127001','99','human_owned','wamid.episode.1')$$,'Delayed old ownership event ignored');
select is((select state from public.chatbot_node_conversations where node_conversation_id='1271'),'closed','Terminal closed ownership never revived');
insert into public.messages(organization_id,external_id,direction,contact_address,service,organization_address,content,status)
 values('12700000-0000-4000-8000-000000000001','wamid.episode.1','outgoing','92300127001','whatsapp','900000127','{}','{"read":"2026-10-11T00:00:00Z"}')
 on conflict(external_id) do update set status=excluded.status,conversation_id=excluded.conversation_id;
select is((select conversation_id from public.messages where external_id='wamid.episode.1'),(select id from episodes where number=1),'Late status stays attached to original message');
select ok(not has_function_privilege('authenticated','public.resolve_node_conversation_episode(uuid,text,text,text,integer,text)','execute'),'Clients cannot forge episodes');
select set_config('request.jwt.claim.sub','12710000-0000-4000-8000-000000000002',true);
select set_config('request.jwt.claim.role','authenticated',true);
grant select on episodes to authenticated;
set local role authenticated;
select is((select count(*) from public.list_previous_conversations_page('12700000-0000-4000-8000-000000000001',(select id from episodes where number=2),1,10)),1::bigint,'Manager sees accessible previous history only');
select is((select total_count from public.list_previous_conversations_page('12700000-0000-4000-8000-000000000001',(select id from episodes where number=2),1,10)),1::bigint,'Pagination returns filtered total');
select is((select count(*) from public.list_previous_conversations_page('12700000-0000-4000-8000-000000000001',(select id from episodes where number=2),2,1)),0::bigint,'Second page is empty');
select throws_ok($$select public.list_previous_conversations_page('12700000-0000-4000-8000-000000000099',(select id from episodes where number=2))$$,'42501',null,'Other tenant history inaccessible');
reset role;
update public.conversations set assigned_agent_id='12720000-0000-4000-8000-000000000001'
 where id=(select id from episodes where number=2);
select set_config('request.jwt.claim.sub','12710000-0000-4000-8000-000000000001',true);
set local role authenticated;
select is((select count(*) from public.list_previous_conversations_page('12700000-0000-4000-8000-000000000001',(select id from episodes where number=2),1,10)),1::bigint,'Assigned agent retains access to their resolved history');
reset role;
update public.conversations set assigned_agent_id='12720000-0000-4000-8000-000000000002'
 where id=(select id from episodes where number=1);
set local role authenticated;
select is((select count(*) from public.list_previous_conversations_page('12700000-0000-4000-8000-000000000001',(select id from episodes where number=2),1,10)),1::bigint,'Previous customer history includes a thread handled by another agent');
select is((select count(*) from public.list_previous_conversation_messages('12700000-0000-4000-8000-000000000001',(select id from episodes where number=2),(select id from episodes where number=1))),1::bigint,'Agent can read another agent completed episode through scoped history');
reset role;
select * from finish();
rollback;
