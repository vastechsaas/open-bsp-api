begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select plan(12);
insert into public.organizations(id,name,extra) values
 ('17000000-0000-4000-8000-000000000001','Disposable bridge fixture','{}');
insert into public.organizations_addresses(organization_id,service,address,extra,status) values
 ('17000000-0000-4000-8000-000000000001','whatsapp','900000000117','{}','connected');
insert into public.chatbot_node_bridges(organization_id,organization_address,node_company_id) values
 ('17000000-0000-4000-8000-000000000001','900000000117','117');
select ok(not public.is_node_managed_number('17000000-0000-4000-8000-000000000001','900000000117'),'Native remains the default');
select lives_ok($$select public.enqueue_node_chatbot_operation('17000000-0000-4000-8000-000000000001','900000000117','117','17000000-0000-4000-8000-000000000002','deactivate','{}')$$,'Durable work is enqueued');
select ok(public.is_node_managed_number('17000000-0000-4000-8000-000000000001','900000000117'),'Transition suppresses native execution');
select lives_ok($$select public.enqueue_node_chatbot_operation('17000000-0000-4000-8000-000000000001','900000000117','117','17000000-0000-4000-8000-000000000002','deactivate','{}')$$,'Duplicate request is idempotent');
select is((select count(*) from public.chatbot_node_operations),1::bigint,'Duplicate does not create another operation');
select throws_ok($$select public.enqueue_node_chatbot_operation('17000000-0000-4000-8000-000000000001','900000000117','117','17000000-0000-4000-8000-000000000002','restore','{}')$$,'23514',null,'Request ID cannot change action');
update public.chatbot_node_operations set status='in_flight' where request_id='17000000-0000-4000-8000-000000000002';
select lives_ok($$select public.complete_node_chatbot_operation('17000000-0000-4000-8000-000000000002','deactivate','{}')$$,'Acknowledgment commits atomically');
select is((select engine from public.chatbot_node_bridges where node_company_id='117'),'disabled','Deactivation does not reactivate native');
select lives_ok($$select public.complete_node_chatbot_operation('17000000-0000-4000-8000-000000000002','deactivate','{}')$$,'Repeated completion is idempotent');
select ok(not has_function_privilege('authenticated','public.enqueue_node_chatbot_operation(uuid,text,text,uuid,text,jsonb)','EXECUTE'),'Browser cannot bypass management authorization');
select ok(not has_function_privilege('authenticated','public.complete_node_chatbot_operation(uuid,text,jsonb)','EXECUTE'),'Browser cannot forge acknowledgments');
select ok((select relrowsecurity from pg_class where oid='public.chatbot_node_conversations'::regclass),'Conversation mappings use RLS');
select * from finish();
rollback;
