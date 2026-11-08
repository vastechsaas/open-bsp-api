begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public,auth;
select no_plan();
insert into public.organizations(id,name) values('14100000-0000-4000-8000-000000000001','Activity test'),('14100000-0000-4000-8000-000000000009','Other tenant');
insert into auth.users(id,email) values('14100000-0000-4000-8000-000000000002','activity@example.test');
insert into public.agents(id,organization_id,user_id,name,ai,extra) values('14100000-0000-4000-8000-000000000003','14100000-0000-4000-8000-000000000001','14100000-0000-4000-8000-000000000002','Owner',false,'{"role":"owner"}');
insert into public.organizations_addresses(organization_id,address,service,status,extra) values('14100000-0000-4000-8000-000000000001','activity-number','whatsapp','connected','{}');
insert into public.campaigns(id,organization_id,name,organization_address,template,audience_type) values
('14100000-0000-4000-8000-000000000010','14100000-0000-4000-8000-000000000001','Activity','activity-number','{"id":"approved","name":"approved","language":"en_US","status":"APPROVED","components":[]}','csv_upload');
insert into public.campaign_csv_recipients(organization_id,campaign_id,contact_address) values
('14100000-0000-4000-8000-000000000001','14100000-0000-4000-8000-000000000010','15550000001'),
('14100000-0000-4000-8000-000000000001','14100000-0000-4000-8000-000000000010','15550000002');
select set_config('request.jwt.claim.sub','14100000-0000-4000-8000-000000000002',true);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;
select is(public.start_campaign('14100000-0000-4000-8000-000000000001','14100000-0000-4000-8000-000000000010'),2::bigint,'start creates recipients');
select throws_ok($$select public.ingest_campaign_receipt('14100000-0000-4000-8000-000000000001','activity-number','fake','read',now())$$,'42501',null,'users cannot inject receipts');
select throws_ok($$select * from public.campaign_activity$$,'42501',null,'raw activity table is private');
reset role;
create temp table attempt as select id,delivery_id,(public.claim_campaign_dispatch_job(id)->>'lease_token')::uuid token from public.campaign_dispatch_jobs order by id limit 1;
select ok(public.begin_campaign_dispatch_send(id,token),'submission boundary') from attempt;
select ok(public.ingest_campaign_receipt('14100000-0000-4000-8000-000000000001','activity-number','wamid.activity','read','2026-11-01T10:00:00Z','campaign:job:'||id),'early read receipt reconciles acceptance') from attempt;
select is((select status from public.campaign_deliveries where id=(select delivery_id from attempt)),'accepted','receipt recovers only matching submitted attempt');
select is((select phase from public.campaign_dispatch_jobs where id=(select id from attempt)),'accepted','job accepted without another send');
select is(public.finish_campaign_dispatch_job(id,token,'accepted','wamid.activity'),'accepted','late HTTP acceptance remains idempotent') from attempt;
select ok(public.ingest_campaign_receipt('14100000-0000-4000-8000-000000000001','activity-number','wamid.activity','read','2026-11-01T10:00:00Z'),'duplicate accepted');
select is((select count(*) from public.campaign_activity where event_type='read'),1::bigint,'duplicate creates no event');
select ok(public.ingest_campaign_receipt('14100000-0000-4000-8000-000000000001','activity-number','wamid.activity','failed','2026-11-01T09:59:00Z',null,'meta_131026'),'conflicting failure retained');
select is((select read_at from public.campaign_delivery_receipts), '2026-11-01T10:00:00Z'::timestamptz,'failure does not remove read');
select is((select delivered_at from public.campaign_delivery_receipts),null::timestamptz,'read does not fabricate delivery timestamp');
select is((select status from public.campaign_deliveries where id=(select delivery_id from attempt)),'accepted','delivery failure cannot requeue');
select ok(public.ingest_campaign_receipt('14100000-0000-4000-8000-000000000001','activity-number','wamid.unknown','delivered',now()),'unknown is retained');
select is((select count(*) from public.messages),0::bigint,'no empty chat messages created');
select is((select count(*) from public.conversations),0::bigint,'no inbox conversations created');
select is((select count(*) from public.campaign_receipt_inbox where processed_at is null),1::bigint,'unmatched evidence remains durable');
select ok(public.ingest_campaign_receipt('14100000-0000-4000-8000-000000000001','activity-number','wamid.wrong','read',now(),'campaign:job:'||gen_random_uuid()),'unknown job safely retained');
select is((select count(*) from public.campaign_delivery_receipts),1::bigint,'unknown correlation cannot change recipient');
update public.organizations_addresses set status='disconnected' where address='activity-number';
select ok(public.ingest_campaign_receipt('14100000-0000-4000-8000-000000000001','activity-number','wamid.activity','delivered','2026-11-01T09:58:00Z'),'disconnected account retains late receipt');
select is((select status from public.organizations_addresses where address='activity-number'),'disconnected','receipt cannot reconnect account');
select is((select delivered_at from public.campaign_delivery_receipts),'2026-11-01T09:58:00Z'::timestamptz,'actual provider time is recorded');
set local role authenticated;
select is(public.get_campaign_receipt_summary('14100000-0000-4000-8000-000000000001','14100000-0000-4000-8000-000000000010'),'{"sent":1,"delivered":1,"read":1,"delivery_failed":0}'::jsonb,'monotonic milestone counts');
select is((select count(*) from public.list_campaign_activity_page('14100000-0000-4000-8000-000000000001','14100000-0000-4000-8000-000000000010',1,2)),2::bigint,'server page size applied');
select ok((select min(total_count)>2 from public.list_campaign_activity_page('14100000-0000-4000-8000-000000000001','14100000-0000-4000-8000-000000000010',1,2)),'totals before pagination');
select throws_ok($$select public.get_campaign_receipt_summary('14100000-0000-4000-8000-000000000009','14100000-0000-4000-8000-000000000010')$$,'42501','organization is not accessible','other tenant denied');
reset role;
select ok(not has_function_privilege('authenticated','public.reconcile_campaign_receipts(integer)','execute'),'recovery is worker only');

-- Receipt without callback races the send-result write: recover from its WAMID later.
update public.organizations_addresses set status='connected' where address='activity-number';
create temp table second_attempt as select id,delivery_id,(public.claim_campaign_dispatch_job(id)->>'lease_token')::uuid token
  from public.campaign_dispatch_jobs where phase='pending' order by id limit 1;
select ok(public.begin_campaign_dispatch_send(id,token),'second submission starts') from second_attempt;
select is(public.finish_campaign_dispatch_job(id,token,'needs_review',null,'submission_outcome_unknown'),'needs_review','ambiguous submission remains paused') from second_attempt;
select ok(public.ingest_campaign_receipt('14100000-0000-4000-8000-000000000001','activity-number','wamid.recovery','delivered',now()),'unmatched receipt accepted durably');
select is((select phase from public.campaign_dispatch_jobs where id=(select id from second_attempt)),'needs_review','uncorrelated receipt cannot guess a send');
select ok(public.ingest_campaign_receipt('14100000-0000-4000-8000-000000000001','activity-number','wamid.recovery','sent',now(),'campaign:job:'||id),'signed callback reconciles exact uncertain attempt') from second_attempt;
select is((select phase from public.campaign_dispatch_jobs where id=(select id from second_attempt)),'accepted','uncertain job reconciled without send');
update public.campaign_receipt_inbox set next_check_at=clock_timestamp() where external_id='wamid.recovery' and processed_at is null;
select ok(public.reconcile_campaign_receipts(100)>=1,'recovery matches earlier WAMID evidence');
select is((select count(*) from public.campaign_dispatch_jobs),2::bigint,'receipt recovery creates no retry jobs');
select ok((select delivered_at is not null from public.campaign_delivery_receipts where delivery_id=(select delivery_id from second_attempt)),'earlier delivery applied after acceptance');
select ok(public.ingest_campaign_receipt('14100000-0000-4000-8000-000000000001','activity-number','wamid.wrongnumber','read',now(),'campaign:job:'||id),'conflicting WAMID safely retained') from second_attempt;
select is((select external_id from public.campaign_deliveries where id=(select delivery_id from second_attempt)),'wamid.recovery','conflicting WAMID cannot replace accepted evidence');
select is((select count(*) from public.campaign_activity where event_type='dispatch_finished'),1::bigint,'dispatch completion recorded once independently of receipts');
select ok(public.ingest_campaign_receipt('14100000-0000-4000-8000-000000000001','activity-number','wamid.recovery','read',now()),'late read after dispatch finish');
select is((select status from public.campaigns where id='14100000-0000-4000-8000-000000000010'),'completed','receipt does not reopen completed campaign');

-- Legacy transport reuses its persisted attempt number; no new legacy queue is introduced.
update public.campaign_dispatch_settings set enabled=false where organization_id='14100000-0000-4000-8000-000000000001';
insert into public.campaigns(id,organization_id,name,organization_address,template,audience_type)
select '14100000-0000-4000-8000-000000000011',organization_id,'Legacy activity',organization_address,template,audience_type
  from public.campaigns where id='14100000-0000-4000-8000-000000000010';
insert into public.campaign_csv_recipients(organization_id,campaign_id,contact_address)
values('14100000-0000-4000-8000-000000000001','14100000-0000-4000-8000-000000000011','15550000003');
set local role authenticated;
select is(public.start_campaign('14100000-0000-4000-8000-000000000001','14100000-0000-4000-8000-000000000011'),1::bigint,'legacy transport starts normally');
reset role;
create temp table legacy_claim as select * from public.claim_campaign_deliveries(25);
select is((select count(*) from legacy_claim),1::bigint,'legacy claim is transport isolated');
select ok(public.ingest_campaign_receipt('14100000-0000-4000-8000-000000000001','activity-number','wamid.legacy','delivered',now(),'campaign:legacy:'||delivery_id||':'||attempts),'early legacy receipt reconciles its attempt') from legacy_claim;
select is(public.record_campaign_delivery_result(delivery_id,'wamid.legacy'),'accepted','legacy HTTP result is idempotent after receipt') from legacy_claim;
select is((select status from public.campaign_deliveries where id=(select delivery_id from legacy_claim)),'accepted','legacy accepted state preserved');
select is((select count(*) from public.campaign_dispatch_jobs),2::bigint,'legacy receipts create no AMQP work');
select ok((select delivered_at is not null from public.campaign_delivery_receipts where delivery_id=(select delivery_id from legacy_claim)),'legacy delivery tracked');

insert into public.campaign_activity(organization_id,campaign_id,event_type)
select '14100000-0000-4000-8000-000000000001','14100000-0000-4000-8000-000000000011','test_fixture' from generate_series(1,60);
set local role authenticated;
select is((select count(*) from public.list_campaign_activity_page('14100000-0000-4000-8000-000000000001','14100000-0000-4000-8000-000000000011',1,500)),50::bigint,'page size capped at 50');
select is((select count(*) from (
  select id from public.list_campaign_activity_page('14100000-0000-4000-8000-000000000001','14100000-0000-4000-8000-000000000011',1,10)
  intersect select id from public.list_campaign_activity_page('14100000-0000-4000-8000-000000000001','14100000-0000-4000-8000-000000000011',2,10)
) overlap),0::bigint,'deterministic pages do not overlap');
reset role;
select * from finish();
rollback;
