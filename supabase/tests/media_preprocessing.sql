begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public,auth;
select no_plan();

-- Other existing message hooks need a URL even in an isolated database.
-- Requests remain transactional and are rolled back; no provider is contacted.
select vault.create_secret('http://127.0.0.1:1/functions/v1','edge_functions_url')
where not exists(select 1 from vault.decrypted_secrets where name='edge_functions_url');
select vault.create_secret('local-test-only','edge_functions_token')
where not exists(select 1 from vault.decrypted_secrets where name='edge_functions_token');

insert into public.organizations(id,name,extra) values
('16100000-0000-4000-8000-000000000001','Media job test','{"media_preprocessing":{"mode":"inactive"}}');
insert into public.organizations_addresses(organization_id,address,service,status,extra) values
('16100000-0000-4000-8000-000000000001','media-test-number','whatsapp','connected','{}');
insert into public.contacts_addresses(organization_id,address,service,extra) values
('16100000-0000-4000-8000-000000000001','15551610001','whatsapp','{}');
insert into public.conversations(id,organization_id,organization_address,contact_address,service) values
('16110000-0000-4000-8000-000000000001','16100000-0000-4000-8000-000000000001','media-test-number','15551610001','whatsapp');
insert into public.messages(id,organization_id,conversation_id,organization_address,contact_address,service,direction,content,status,timestamp)
select ('16120000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
'16100000-0000-4000-8000-000000000001','16110000-0000-4000-8000-000000000001',
'media-test-number','15551610001','whatsapp','incoming',
'{"version":"1","type":"file","kind":"image","file":{"uri":"internal://media/organizations/16100000-0000-4000-8000-000000000001/attachments/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","mime_type":"image/jpeg","size":100}}',
jsonb_build_object('pending',clock_timestamp(),'read',clock_timestamp()),clock_timestamp()-interval '2 minutes'
from generate_series(1,2) n;

select is((select count(*) from public.media_preprocessing_jobs where organization_id='16100000-0000-4000-8000-000000000001'),0::bigint,'Disabled mode does not enqueue work from insert trigger');
select is(public.reserve_media_preprocessing('16120000-0000-4000-8000-000000000001'),null::uuid,'Disabled mode cannot reserve');
select ok(not public.enqueue_media_preprocessing('16120000-0000-4000-8000-000000000001'),'Disabled-mode backlog produces no requests');
update public.organizations set extra='{"media_preprocessing":{"mode":"active"}}' where id='16100000-0000-4000-8000-000000000001';
create temp table media_tokens(attempt integer,token uuid);
insert into media_tokens values (1,public.reserve_media_preprocessing('16120000-0000-4000-8000-000000000001'));
select ok(token is not null,'First attempt reserves before HTTP') from media_tokens where attempt=1;
select is(public.reserve_media_preprocessing('16120000-0000-4000-8000-000000000001'),null::uuid,'Reservation is exclusive');
select ok(public.start_media_preprocessing('16120000-0000-4000-8000-000000000001',token),'Matching queued delivery starts') from media_tokens where attempt=1;
select ok(not public.start_media_preprocessing('16120000-0000-4000-8000-000000000001',token),'Duplicate HTTP delivery cannot process twice') from media_tokens where attempt=1;
select ok(public.finish_media_preprocessing('16120000-0000-4000-8000-000000000001',token,'retry'),'Transient error persists retry') from media_tokens where attempt=1;
select is(public.reserve_media_preprocessing('16120000-0000-4000-8000-000000000001'),null::uuid,'Backoff is retained');
update public.media_preprocessing_jobs set next_attempt_at=clock_timestamp()-interval '1 second' where message_id='16120000-0000-4000-8000-000000000001';
insert into media_tokens values (2,public.reserve_media_preprocessing('16120000-0000-4000-8000-000000000001'));
select ok(public.start_media_preprocessing('16120000-0000-4000-8000-000000000001',token),'Second lease starts') from media_tokens where attempt=2;
select ok(not public.finish_media_preprocessing('16120000-0000-4000-8000-000000000001',token,'succeeded','[]'),'Old worker cannot overwrite new attempt') from media_tokens where attempt=1;
select ok(public.finish_media_preprocessing('16120000-0000-4000-8000-000000000001',token,'retry'),'Second retry persists') from media_tokens where attempt=2;
update public.media_preprocessing_jobs set next_attempt_at=clock_timestamp()-interval '1 second' where message_id='16120000-0000-4000-8000-000000000001';
insert into media_tokens values (3,public.reserve_media_preprocessing('16120000-0000-4000-8000-000000000001'));
select is((select attempts from public.media_preprocessing_jobs where message_id='16120000-0000-4000-8000-000000000001'),3,'Third HTTP reservation consumes final attempt');
-- Simulate an auth failure or crash before the endpoint can claim.
update public.media_preprocessing_jobs set next_attempt_at=clock_timestamp()-interval '1 second' where message_id='16120000-0000-4000-8000-000000000001';
select is(public.reserve_media_preprocessing('16120000-0000-4000-8000-000000000001'),null::uuid,'Expired third reservation never sends again');
select is((select state from public.media_preprocessing_jobs where message_id='16120000-0000-4000-8000-000000000001'),'failed','Retry exhaustion is durable');
select ok((select status ? 'preprocessed' and status ? 'read' and content->>'type'='file' from public.messages where id='16120000-0000-4000-8000-000000000001'),'Exhaustion unblocks waiting AI without deleting media/read state');

insert into media_tokens values (4,public.reserve_media_preprocessing('16120000-0000-4000-8000-000000000002'));
select ok(public.start_media_preprocessing('16120000-0000-4000-8000-000000000002',token),'Other message can process') from media_tokens where attempt=4;
select ok(public.finish_media_preprocessing('16120000-0000-4000-8000-000000000002',token,'succeeded','[{"type":"text","kind":"description","text":"Test fixture"}]'),'Artifacts commit through lease-checked completion') from media_tokens where attempt=4;
select ok((select status ? 'read' and status ? 'preprocessed' and content->'file'->>'mime_type'='image/jpeg' and content->'artifacts'->0->>'text'='Test fixture' from public.messages where id='16120000-0000-4000-8000-000000000002'),'Completion preserves existing message fields');
select ok(not public.finish_media_preprocessing('16120000-0000-4000-8000-000000000002',token,'succeeded','[]'),'Completion cannot run twice') from media_tokens where attempt=4;
select ok(not has_table_privilege('authenticated','public.media_preprocessing_jobs','SELECT'),'Job records are private');
select ok(not has_function_privilege('authenticated','public.reserve_media_preprocessing(uuid)','EXECUTE'),'Tenant clients cannot reserve other tenants work');
select ok(has_function_privilege('service_role','public.finish_media_preprocessing(uuid,uuid,text,jsonb)','EXECUTE'),'Worker can complete jobs');
select * from finish();
rollback;
