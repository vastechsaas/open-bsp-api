begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public,auth;
select no_plan();

insert into public.organizations(id,name) values
 ('14700000-0000-4000-8000-000000000001','Attachment test'),
 ('14700000-0000-4000-8000-000000000002','Other attachment tenant');
insert into auth.users(id,email) values
 ('14700000-0000-4000-8000-000000000003','attachment-owner@example.test'),
 ('14700000-0000-4000-8000-000000000004','attachment-outsider@example.test');
insert into public.agents(organization_id,user_id,name,ai,extra) values
 ('14700000-0000-4000-8000-000000000001','14700000-0000-4000-8000-000000000003','Owner',false,'{"role":"owner"}'),
 ('14700000-0000-4000-8000-000000000002','14700000-0000-4000-8000-000000000004','Outsider',false,'{"role":"owner"}');
insert into public.organizations_addresses(organization_id,address,service,status) values
 ('14700000-0000-4000-8000-000000000001','14755500001','whatsapp','connected');
insert into public.contacts_addresses(organization_id,address,service) values
 ('14700000-0000-4000-8000-000000000001','14755500002','whatsapp');

create temp table inbound_fixture as
select '[{"organization_id":"14700000-0000-4000-8000-000000000001","organization_address":"14755500001",
"contact_address":"14755500002","external_id":"wamid.recover-fixture","direction":"incoming","service":"whatsapp",
"timestamp":"2026-01-01T00:00:00Z","content":{"version":"1","type":"file","kind":"image","text":"Original caption",
"file":{"uri":"123456","name":"photo.jpg","mime_type":"image/jpeg","size":0}}}]'::jsonb as payload;
select is(public.persist_whatsapp_attachment_messages(payload),1,'message and attachment job inserted') from inbound_fixture;
select is(public.persist_whatsapp_attachment_messages(payload),0,'duplicate delivery is a no-op') from inbound_fixture;
select is((select count(*) from public.whatsapp_attachment_recovery_jobs),1::bigint,'one private job');
select is((select content->>'attachment_recovery' from public.messages where external_id='wamid.recover-fixture'),'pending','placeholder state stored on message');
select is((select content->>'text' from public.messages where external_id='wamid.recover-fixture'),'Original caption','caption visible before attachment');
create temp table job_ref as select id from public.messages where external_id='wamid.recover-fixture';
grant select on job_ref to authenticated;

select set_config('request.jwt.claim.sub','14700000-0000-4000-8000-000000000004',true);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;
select is(public.retry_whatsapp_attachment_recovery(id),'not_found','another tenant cannot retry or enumerate') from job_ref;
select throws_ok('select * from public.whatsapp_attachment_recovery_jobs','42501',null,'queue is private');
select throws_ok('select * from public.claim_whatsapp_attachment_recovery()','42501',null,'worker claim is private');
reset role;

create temp table first_lease as select * from public.claim_whatsapp_attachment_recovery();
select is((select count(*) from first_lease),1::bigint,'initial job claimed');
select is((select count(*) from public.claim_whatsapp_attachment_recovery()),0::bigint,'overlapping invocation cannot claim same job');
select is((select media_id from first_lease f cross join lateral public.whatsapp_attachment_recovery_context(f.message_id,f.lease_token)),'123456','worker context tied to lease');
select ok(public.finish_whatsapp_attachment_recovery(message_id,lease_token,'temporary',null,null,90),'temporary failure is scheduled') from first_lease;
select ok((select next_attempt_at >= now()+interval '90 seconds' from public.whatsapp_attachment_recovery_jobs),'honors Meta Retry-After');
select ok(not public.finish_whatsapp_attachment_recovery(message_id,lease_token,'unavailable'),'stale worker cannot overwrite state') from first_lease;

update public.whatsapp_attachment_recovery_jobs set next_attempt_at=now();
create temp table second_lease as select * from public.claim_whatsapp_attachment_recovery();
select ok(public.finish_whatsapp_attachment_recovery(message_id,lease_token,'temporary'),'second failure schedules another retry') from second_lease;
select is((select next_attempt_at from public.whatsapp_attachment_recovery_jobs),now()+interval '2 minutes','second retry has two-minute delay');
update public.whatsapp_attachment_recovery_jobs set next_attempt_at=now();
create temp table third_lease as select * from public.claim_whatsapp_attachment_recovery();
select ok(public.finish_whatsapp_attachment_recovery(message_id,lease_token,'temporary'),'third failure schedules another retry') from third_lease;
select is((select next_attempt_at from public.whatsapp_attachment_recovery_jobs),now()+interval '10 minutes','third retry has ten-minute delay');
update public.whatsapp_attachment_recovery_jobs set next_attempt_at=now();
create temp table expired as select * from public.claim_whatsapp_attachment_recovery();
update public.whatsapp_attachment_recovery_jobs set lease_until=now()-interval '1 second';
select is((select count(*) from public.claim_whatsapp_attachment_recovery()),0::bigint,'expired final automatic lease is not left pending');
select is((select state from public.whatsapp_attachment_recovery_jobs),'failed','expired final attempt has actionable state');
set local role authenticated;
select is(public.retry_whatsapp_attachment_recovery(id),'not_found','another tenant cannot enqueue retry') from job_ref;
reset role;
select set_config('request.jwt.claim.sub','14700000-0000-4000-8000-000000000003',true);
set local role authenticated;
select is(public.retry_whatsapp_attachment_recovery(id),'pending','owner can request manual retry') from job_ref;
select is(public.retry_whatsapp_attachment_recovery(id),'pending','repeat request shares the job') from job_ref;
reset role;
select is((select manual_attempts from public.whatsapp_attachment_recovery_jobs),1,'repeat click does not consume a second attempt');
create temp table manual as select * from public.claim_whatsapp_attachment_recovery();
select ok(public.finish_whatsapp_attachment_recovery(message_id,lease_token,'storage'),'storage failure is projected distinctly') from manual;
set local role authenticated;
select is(public.retry_whatsapp_attachment_recovery(id),'cooldown','manual retries cooled down') from job_ref;
reset role;
update public.whatsapp_attachment_recovery_jobs set manual_requested_at=now()-interval '6 minutes';
set local role authenticated;
select is(public.retry_whatsapp_attachment_recovery(id),'pending','second manual retry permitted') from job_ref;
reset role;
create temp table success as select * from public.claim_whatsapp_attachment_recovery();
create temp table fixture_path as
select 'organizations/14700000-0000-4000-8000-000000000001/attachments/'||repeat('a',43) as path;
insert into storage.buckets(id,name) values('media','media') on conflict do nothing;
insert into storage.objects(bucket_id,name,metadata) select 'media',path,'{"size":17}' from fixture_path;
update public.messages set status='{"read":"2026-01-02T00:00:00Z"}' where id=(select id from job_ref);
select ok(public.finish_whatsapp_attachment_recovery(message_id,lease_token,'ready',path,17),'verified private object links') from success,fixture_path;
update public.messages set content='{"file":{"uri":"123456"}}' where id=(select id from job_ref);
select is((select content#>>'{file,uri}' from public.messages where id=(select id from job_ref)),
 (select 'internal://media/'||path from fixture_path),'older delivery cannot replace recovered file');
select is((select content->>'text' from public.messages where id=(select id from job_ref)),'Original caption','original caption preserved');
select is((select status->>'read' from public.messages where id=(select id from job_ref)),'2026-01-02T00:00:00Z','read status preserved');
select is((select count(*) from public.messages where external_id='wamid.recover-fixture'),1::bigint,'no new chat message');

select is(public.persist_whatsapp_attachment_messages(jsonb_set(payload,'{0,external_id}','"wamid.deleted-attachment"')),1,'second fixture queued') from inbound_fixture;
create temp table deleted as select * from public.claim_whatsapp_attachment_recovery();
update public.messages set status='{"deleted":"2026-01-02T00:00:00Z"}' where id=(select message_id from deleted);
select ok(public.finish_whatsapp_attachment_recovery(message_id,lease_token,'ready',path,17),'deletion cancels leased job') from deleted,fixture_path;
select is((select state from public.whatsapp_attachment_recovery_jobs where message_id=(select message_id from deleted)),'cancelled','deleted attachment is not linked');

select * from finish();
rollback;
