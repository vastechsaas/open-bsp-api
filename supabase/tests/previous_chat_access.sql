begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public,auth;
select no_plan();

insert into public.organizations(id,name,extra) values
 ('13800000-0000-4000-8000-000000000001','History access','{}'),
 ('13800000-0000-4000-8000-000000000002','Other tenant','{}');
insert into auth.users(id,email,aud,role,raw_app_meta_data,raw_user_meta_data) values
 ('13810000-0000-4000-8000-000000000001','history-agent@example.test','authenticated','authenticated','{}','{}'),
 ('13810000-0000-4000-8000-000000000002','history-manager@example.test','authenticated','authenticated','{}','{}'),
 ('13810000-0000-4000-8000-000000000003','history-outsider@example.test','authenticated','authenticated','{}','{}'),
 ('13810000-0000-4000-8000-000000000004','history-pending@example.test','authenticated','authenticated','{}','{}');
insert into public.agents(id,organization_id,user_id,name,ai,extra) values
 ('13820000-0000-4000-8000-000000000001','13800000-0000-4000-8000-000000000001','13810000-0000-4000-8000-000000000001','New support agent',false,'{"role":"agent"}'),
 ('13820000-0000-4000-8000-000000000002','13800000-0000-4000-8000-000000000001','13810000-0000-4000-8000-000000000002','Manager',false,'{"role":"supervisor"}'),
 ('13820000-0000-4000-8000-000000000003','13800000-0000-4000-8000-000000000002','13810000-0000-4000-8000-000000000003','Outsider',false,'{"role":"agent"}'),
 ('13820000-0000-4000-8000-000000000004','13800000-0000-4000-8000-000000000001','13810000-0000-4000-8000-000000000004','Pending',false,'{"role":"agent","invitation":{"status":"pending","email":"history-pending@example.test"}}');
insert into public.organizations_addresses(organization_id,service,address,status,extra) values
 ('13800000-0000-4000-8000-000000000001','whatsapp','900000138','connected','{}'),
 ('13800000-0000-4000-8000-000000000001','whatsapp','900000139','connected','{}'),
 ('13800000-0000-4000-8000-000000000002','whatsapp','900000138','connected','{}');
insert into public.conversations(id,organization_id,service,organization_address,contact_address,name,assigned_agent_id,status,created_at)
 select ('13830000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 '13800000-0000-4000-8000-000000000001','whatsapp','900000138','92300138001',
 'Previous '||n,'13820000-0000-4000-8000-000000000002','closed',now()-interval '1 day'
 from generate_series(1,52) n;
insert into public.conversations(id,organization_id,service,organization_address,contact_address,name,assigned_agent_id,status) values
 ('13830000-0000-4000-8000-000000000100','13800000-0000-4000-8000-000000000001','whatsapp','900000138','92300138001','Current','13820000-0000-4000-8000-000000000001','active'),
 ('13830000-0000-4000-8000-000000000101','13800000-0000-4000-8000-000000000001','whatsapp','900000138','92300138002','Different customer',null,'closed'),
 ('13830000-0000-4000-8000-000000000102','13800000-0000-4000-8000-000000000001','whatsapp','900000139','92300138001','Different business number',null,'closed'),
 ('13830000-0000-4000-8000-000000000103','13800000-0000-4000-8000-000000000002','whatsapp','900000138','92300138001','Different tenant',null,'closed'),
 ('13830000-0000-4000-8000-000000000104','13800000-0000-4000-8000-000000000001','instagram','900000138','92300138001','Different service',null,'closed');
insert into public.messages(id,organization_id,conversation_id,external_id,direction,contact_address,service,organization_address,content,status,timestamp)
 select ('13840000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 '13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000001',
 'wamid.history.'||n,'incoming','92300138001','whatsapp','900000138',
 '{"version":"1","type":"text","kind":"text","text":"Earlier customer message"}','{}',now()-interval '2 hours'
 from generate_series(1,61) n;

select set_config('request.jwt.claim.sub','13810000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;
select is((select count(*) from public.list_previous_conversations_page('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100')),10::bigint,'New agent sees previous chats handled by a different agent');
select is((select max(total_count) from public.list_previous_conversations_page('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100')),52::bigint,'Total excludes current chat, other customer, number, service and tenant');
select is((select count(*) from public.list_previous_conversations_page('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100',6,10)),2::bigint,'Last list page returns only remaining rows');
select is((select count(*) from public.list_previous_conversations_page('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100',1,500)),50::bigint,'List page size is capped');
select is((select max(total_count) from public.list_previous_conversations_page('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100',1,10,'Previous 52')),1::bigint,'Search runs before counting and pagination');
select is((select id from public.list_previous_conversations_page('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100',1,1)),'13830000-0000-4000-8000-000000000052'::uuid,'Equal creation times use deterministic ID ordering');
select is((select count(*) from public.conversations where id='13830000-0000-4000-8000-000000000001'),0::bigint,'History does not widen ordinary inbox access');
select is((select count(*) from public.messages where conversation_id='13830000-0000-4000-8000-000000000001'),0::bigint,'Ordinary message RLS remains unchanged');
select is((select count(*) from public.list_previous_conversation_messages('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100','13830000-0000-4000-8000-000000000001')),30::bigint,'Previous messages load in 30-message pages regardless of agent assignment');
select is((select count(*) from public.list_previous_conversation_messages('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100','13830000-0000-4000-8000-000000000001',null,null,500)),50::bigint,'Message page size is capped');
select is((select count(*) from public.list_previous_conversation_messages('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100','13830000-0000-4000-8000-000000000002')),0::bigint,'Empty previous chats return empty history');
select is((select count(*) from public.list_previous_conversation_messages('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100','13830000-0000-4000-8000-000000000001',now()-interval '2 hours','13840000-0000-4000-8000-000000000032')),30::bigint,'Second message page preserves messages sharing a timestamp');
select is((select count(*) from public.list_previous_conversation_messages('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100','13830000-0000-4000-8000-000000000001',now()-interval '2 hours','13840000-0000-4000-8000-000000000002')),1::bigint,'Final message page returns oldest message');
select is((select count(*) from public.list_previous_conversation_messages('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100','13830000-0000-4000-8000-000000000001',now()-interval '2 hours','13840000-0000-4000-8000-000000000001')),0::bigint,'Pagination stops at beginning');
select throws_ok($$select public.list_previous_conversation_messages('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100','13830000-0000-4000-8000-000000000001',now(),null)$$,'22023',null,'Partial message cursor is rejected');
select throws_ok($$select public.list_previous_conversations_page('13800000-0000-4000-8000-000000000002','13830000-0000-4000-8000-000000000103')$$,'42501',null,'Cannot list another tenant history');
select throws_ok($$select public.list_previous_conversations_page('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000001')$$,'42501',null,'History cannot use an inaccessible previous chat as its anchor');
select throws_ok($$select public.list_previous_conversation_messages('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100','13830000-0000-4000-8000-000000000101')$$,'42501',null,'Different customer message history rejected');
select throws_ok($$select public.list_previous_conversation_messages('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100','13830000-0000-4000-8000-000000000102')$$,'42501',null,'Different business number history rejected');
select throws_ok($$select public.list_previous_conversation_messages('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100','13830000-0000-4000-8000-000000000103')$$,'42501',null,'Different tenant message history rejected');
select throws_ok($$select public.list_previous_conversation_messages('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100','13830000-0000-4000-8000-000000000104')$$,'42501',null,'Different service message history rejected');
select throws_ok($$select public.list_previous_conversation_messages('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100','13830000-0000-4000-8000-000000000100')$$,'42501',null,'Current conversation cannot be forged as a previous chat');
select ok(not public.agent_owns_conversation('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000001'),'Reading history grants no ownership');
select ok(not has_function_privilege('authenticated','public.authorize_previous_chat_context(uuid,uuid)','execute'),'Internal context helper cannot be called directly');
select ok(not has_function_privilege('anon','public.list_previous_conversations_page(uuid,uuid,integer,integer,text)','execute'),'Anonymous list access denied');
select ok(not has_function_privilege('anon','public.list_previous_conversation_messages(uuid,uuid,uuid,timestamptz,uuid,integer)','execute'),'Anonymous message access denied');
reset role;
update public.agents set user_id=null where id='13820000-0000-4000-8000-000000000001';
set local role authenticated;
select throws_ok($$select public.list_previous_conversations_page('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100')$$,'42501',null,'Removed membership denies history list');
select throws_ok($$select public.list_previous_conversation_messages('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100','13830000-0000-4000-8000-000000000001')$$,'42501',null,'Membership revocation between pages denies messages');
reset role;
update public.agents set user_id='13810000-0000-4000-8000-000000000001' where id='13820000-0000-4000-8000-000000000001';
update public.conversations set assigned_agent_id='13820000-0000-4000-8000-000000000002' where id='13830000-0000-4000-8000-000000000100';
set local role authenticated;
select throws_ok($$select public.list_previous_conversation_messages('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100','13830000-0000-4000-8000-000000000001')$$,'42501',null,'Reassignment of current conversation invalidates later message pages');
reset role;
select set_config('request.jwt.claim.sub','13810000-0000-4000-8000-000000000002',true);
set local role authenticated;
select is((select count(*) from public.list_previous_conversation_messages('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100','13830000-0000-4000-8000-000000000001')),30::bigint,'Manager retains history access');
reset role;
select set_config('request.jwt.claim.sub','13810000-0000-4000-8000-000000000003',true);
set local role authenticated;
select throws_ok($$select public.list_previous_conversation_messages('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100','13830000-0000-4000-8000-000000000001')$$,'42501',null,'Other tenant agent cannot read history');
reset role;
select set_config('request.jwt.claim.sub','13810000-0000-4000-8000-000000000004',true);
set local role authenticated;
select throws_ok($$select public.list_previous_conversations_page('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100')$$,'42501',null,'Pending agent cannot list customer history');
select throws_ok($$select public.list_previous_conversation_messages('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100','13830000-0000-4000-8000-000000000001')$$,'42501',null,'Pending agent cannot read customer history');
reset role;
select set_config('request.jwt.claim.sub','13810000-0000-4000-8000-000000000002',true);
update public.organization_lifecycle set status='archived' where organization_id='13800000-0000-4000-8000-000000000001';
set local role authenticated;
select throws_ok($$select public.list_previous_conversation_messages('13800000-0000-4000-8000-000000000001','13830000-0000-4000-8000-000000000100','13830000-0000-4000-8000-000000000001')$$,'42501',null,'Archived organization history unavailable');
reset role;
select * from finish();
rollback;
