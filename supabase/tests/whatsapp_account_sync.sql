begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public,auth;
select no_plan();
insert into public.organizations(id,name,extra) values
 ('12800000-0000-4000-8000-000000000001','Disposable account sync','{}'),
 ('12800000-0000-4000-8000-000000000002','Other account sync tenant','{}');
insert into public.organizations_addresses(organization_id,service,address,status,extra) values
 ('12800000-0000-4000-8000-000000000001','whatsapp','90000128','connected','{"access_token":"test-private-token","waba_id":"128"}'),
 ('12800000-0000-4000-8000-000000000002','whatsapp','90000129','connected','{}');
insert into public.chatbot_node_bridges(organization_id,organization_address,node_company_id,engine,sync_status)
 values('12800000-0000-4000-8000-000000000001','90000128','128','node','active');
select is((select account_revision from public.chatbot_node_bridges where node_company_id='128'),1::bigint,'Initial account revision is queued');
select is((select count(*) from public.chatbot_node_operations where action='account-sync' and organization_id='12800000-0000-4000-8000-000000000001'),1::bigint,'One initial operation');
select ok(not exists(select 1 from public.chatbot_node_operations where organization_id='12800000-0000-4000-8000-000000000001' and payload::text like '%test-private-token%'),'Durable payload has no credential');
create temp table original_operation as select request_id from public.chatbot_node_operations where organization_id='12800000-0000-4000-8000-000000000001';
select is((public.resolve_whatsapp_account_sync((select request_id from original_operation))->>'access_token'),'test-private-token','Service-only resolution reads current source');
update public.organizations_addresses set status='disconnected' where address='90000128';
select is((select account_revision from public.chatbot_node_bridges where node_company_id='128'),2::bigint,'Disconnect increments account revision');
select is(public.resolve_whatsapp_account_sync((select request_id from original_operation)),null::jsonb,'Obsolete operation cannot resolve replacement credentials');
select ok(not public.complete_whatsapp_account_sync((select request_id from original_operation),'1'),'Late acknowledgment cannot overwrite disconnect');
select is((select engine from public.chatbot_node_bridges where node_company_id='128'),'node','Account operation preserves engine selection');
select is((select sync_status from public.chatbot_node_bridges where node_company_id='128'),'active','Account operation preserves activation state');
select is((public.resolve_whatsapp_account_sync((select request_id from public.chatbot_node_operations where organization_id='12800000-0000-4000-8000-000000000001' and status='pending'))->>'access_token'),null::text,'Disconnected operation transfers no token');
update public.organizations_addresses set extra='{"verified_name":"Updated profile"}' where address='90000128';
select is((select account_revision from public.chatbot_node_bridges where node_company_id='128'),2::bigint,'Profile metadata does not enqueue account operation');
update public.organizations_addresses set extra='{"access_token":"replacement-private-token"}',status='connected' where address='90000128';
select is((select account_revision from public.chatbot_node_bridges where node_company_id='128'),3::bigint,'Reconnect/rotation increments once');
select ok(public.complete_whatsapp_account_sync((select request_id from public.chatbot_node_operations where organization_id='12800000-0000-4000-8000-000000000001' and status='pending'),'3'),'Current acknowledgment applies');
select is((select account_sync_status from public.chatbot_node_bridges where node_company_id='128'),'synchronized','Confirmed synchronization visible');
select ok(not public.record_node_account_auth_failure('12800000-0000-4000-8000-000000000001','90000128','2'),'Old token failure cannot disconnect newly connected account');
select is((select status from public.organizations_addresses where address='90000128'),'connected','New credential retains connectivity');
select ok(public.record_node_account_auth_failure('12800000-0000-4000-8000-000000000001','90000128','3'),'Confirmed current auth failure marks disconnected and enqueues suspension');
select is((select status from public.organizations_addresses where address='90000128'),'disconnected','Invalid token requires reconnect');
select is((select status from public.organizations_addresses where address='90000129'),'connected','Unrelated tenant unchanged');
select ok(not has_function_privilege('authenticated','public.resolve_whatsapp_account_sync(uuid)','EXECUTE'),'Browser cannot resolve account credentials');
select ok(not has_function_privilege('anon','public.resolve_whatsapp_account_sync(uuid)','EXECUTE'),'Anonymous cannot resolve account credentials');
select ok(not has_function_privilege('authenticated','public.complete_whatsapp_account_sync(uuid,text)','EXECUTE'),'Browser cannot forge acknowledgments');
select ok(not has_function_privilege('authenticated','public.record_node_account_auth_failure(uuid,text,text)','EXECUTE'),'Browser cannot suspend another account');
select * from finish();
rollback;
