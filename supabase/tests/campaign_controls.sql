begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public,auth;
select no_plan();
insert into public.organizations(id,name) values
('15000000-0000-4000-8000-000000000001','Pause fixture'),('15000000-0000-4000-8000-000000000002','Other tenant');
insert into auth.users(id,email) select ('15010000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'pause'||n||'@example.test' from generate_series(1,5)n;
insert into public.agents(organization_id,user_id,name,ai,extra)
select '15000000-0000-4000-8000-000000000001',('15010000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
  'Test '||n,false,jsonb_build_object('role',(array['owner','admin','member','supervisor','agent'])[n]) from generate_series(1,5)n;
insert into public.organizations_addresses(organization_id,address,service,status,extra)
values('15000000-0000-4000-8000-000000000001','mock-pause-number','whatsapp','connected','{}');
insert into public.campaign_dispatch_settings values('15000000-0000-4000-8000-000000000001',true);
insert into public.campaigns(id,organization_id,name,organization_address,template,audience_type)
select ('15030000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'15000000-0000-4000-8000-000000000001','Pause '||n,
 'mock-pause-number','{"id":"mock","name":"mock","language":"en_US","status":"APPROVED","components":[]}','csv_upload' from generate_series(1,5)n;
insert into public.campaign_csv_recipients(organization_id,campaign_id,contact_address)
select c.organization_id,c.id,'mock-recipient-'||n from public.campaigns c cross join generate_series(1,3)n where c.organization_id='15000000-0000-4000-8000-000000000001';
select set_config('request.jwt.claims','{"sub":"15010000-0000-4000-8000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select public.start_campaign('15000000-0000-4000-8000-000000000001',('15030000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid) from generate_series(1,4)n;
select is(public.pause_campaign('15000000-0000-4000-8000-000000000001','15030000-0000-4000-8000-000000000001',0,'15040000-0000-4000-8000-000000000001')->>'control_revision','1','Owner pauses with revision');
select is(public.pause_campaign('15000000-0000-4000-8000-000000000001','15030000-0000-4000-8000-000000000001',0,'15040000-0000-4000-8000-000000000001')->>'control_revision','1','Duplicate pause is idempotent');
select throws_ok($$select public.resume_campaign('15000000-0000-4000-8000-000000000001','15030000-0000-4000-8000-000000000001',0,gen_random_uuid())$$,'40001',null,'Stale competing action rejected');
select throws_ok($$select public.resume_campaign('15000000-0000-4000-8000-000000000001','15030000-0000-4000-8000-000000000001',1,'15040000-0000-4000-8000-000000000001')$$,'22023',null,'Request ID cannot be reused for opposite action');
select throws_ok($$select public.pause_campaign('15000000-0000-4000-8000-000000000002','15030000-0000-4000-8000-000000000001',0,gen_random_uuid())$$,'42501',null,'Tenant isolation');
select throws_ok($$select public.pause_campaign('15000000-0000-4000-8000-000000000001','15030000-0000-4000-8000-000000000005',0,gen_random_uuid())$$,'23514',null,'Draft cannot pause');
select throws_ok($$update public.campaigns set paused_at=now() where id='15030000-0000-4000-8000-000000000005'$$,'42501',null,'Draft REST cannot set pause state');
select throws_ok($$update public.campaigns set control_revision=1 where id='15030000-0000-4000-8000-000000000005'$$,'42501',null,'Draft REST cannot forge revisions');
update public.campaigns set name='edited' where id='15030000-0000-4000-8000-000000000001';
select is((select name from public.campaigns where id='15030000-0000-4000-8000-000000000001'),'Pause 1','Paused campaign remains immutable');
select is((select count(*) from public.list_campaigns_page('15000000-0000-4000-8000-000000000001',1,1,null,null,null,'paused')),1::bigint,'Paused list is paginated server-side');
select is((select total_count from public.list_campaigns_page('15000000-0000-4000-8000-000000000001',1,1,null,null,null,'paused')),1::bigint,'Paused count after filtering');
select ok((select sending_state->>'paused_at' is not null from public.list_campaigns_page('15000000-0000-4000-8000-000000000001',1,1,null,null,null,'paused')),'List includes hold state without per-row HTTP calls');
reset role;
create temp table controls_jobs as select j.id,j.campaign_id,d.contact_address,null::uuid as token from public.campaign_dispatch_jobs j join public.campaign_deliveries d on d.id=j.delivery_id where j.organization_id='15000000-0000-4000-8000-000000000001';
select is((public.claim_campaign_dispatch_job((select id from controls_jobs where campaign_id='15030000-0000-4000-8000-000000000001' limit 1)))->>'phase','deferred','Queued notification for paused campaign is acknowledged as deferred');
select is((select sum(attempts) from public.campaign_deliveries where campaign_id='15030000-0000-4000-8000-000000000001'),0::bigint,'Pause consumes no Meta attempts');
select ok(not exists(select 1 from jsonb_array_elements(public.claim_campaign_dispatch_publications()) x where x->>'campaign_id'='15030000-0000-4000-8000-000000000001'),'Paused publisher excludes held jobs');
select is((select count(*) from public.campaign_activity where campaign_id='15030000-0000-4000-8000-000000000001' and event_type='campaign_paused'),1::bigint,'One pause activity event');
select is((select actor_name from public.campaign_activity where campaign_id='15030000-0000-4000-8000-000000000001' and event_type='campaign_paused'),'Test 1','Actor derived server-side');
-- Prepared work must pass the final gate again; already authorized sends may finish.
update controls_jobs set token=(public.claim_campaign_dispatch_job(id)->>'lease_token')::uuid where campaign_id='15030000-0000-4000-8000-000000000002';
select ok(public.begin_campaign_dispatch_send(id,token),'One send crosses uncertainty boundary before pause') from controls_jobs where campaign_id='15030000-0000-4000-8000-000000000002' and contact_address='mock-recipient-1';
set local role authenticated;
select public.pause_campaign('15000000-0000-4000-8000-000000000001','15030000-0000-4000-8000-000000000002',0,gen_random_uuid());
reset role;
select ok(not public.begin_campaign_dispatch_send(id,token),'Pause fences already preparing work') from controls_jobs where campaign_id='15030000-0000-4000-8000-000000000002' and contact_address='mock-recipient-2';
select is(public.finish_campaign_dispatch_job(id,token,'accepted','wamid.mock.pause'),'accepted','Already authorized result persists while paused') from controls_jobs where campaign_id='15030000-0000-4000-8000-000000000002' and contact_address='mock-recipient-1';
update public.campaign_dispatch_jobs set lease_expires_at=clock_timestamp()-interval '1 second' where id in(select id from controls_jobs where campaign_id='15030000-0000-4000-8000-000000000002' and contact_address='mock-recipient-3');
select public.recover_campaign_dispatch_jobs();
select is((select waiting_reason from public.campaign_dispatch_jobs where id=(select id from controls_jobs where campaign_id='15030000-0000-4000-8000-000000000002' and contact_address='mock-recipient-3')),'manual_pause','Restart recovers expired preparation into hold');
select is((select accepted_count from public.campaigns where id='15030000-0000-4000-8000-000000000002'),1,'In-flight progress survives pause');
select is((select sum(attempts) from public.campaign_deliveries where campaign_id='15030000-0000-4000-8000-000000000002'),1::bigint,'Blocked preparation consumes no attempts');
-- Keep a future retry deadline intact through a pause/resume.
update public.campaign_dispatch_jobs set due_at=clock_timestamp()+interval '1 hour' where campaign_id='15030000-0000-4000-8000-000000000001';
set local role authenticated;
select is(public.resume_campaign('15000000-0000-4000-8000-000000000001','15030000-0000-4000-8000-000000000001',1,'15040000-0000-4000-8000-000000000002')->>'control_revision','2','Resume advances revision');
select ok(public.pause_campaign('15000000-0000-4000-8000-000000000001','15030000-0000-4000-8000-000000000001',0,'15040000-0000-4000-8000-000000000001')->>'paused_at' is null,'Delayed retry of old pause never reapplies hold after resume');
reset role;
select ok((select bool_and(due_at>clock_timestamp()+interval '59 minutes' and publish_after>=due_at) from public.campaign_dispatch_jobs where campaign_id='15030000-0000-4000-8000-000000000001'),'Resume preserves retry backoff');
-- Admin and Member have the same controls; Supervisor and Agent do not.
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"15010000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select lives_ok($$select public.pause_campaign('15000000-0000-4000-8000-000000000001','15030000-0000-4000-8000-000000000001',2,gen_random_uuid())$$,'Admin can pause');
select set_config('request.jwt.claims','{"sub":"15010000-0000-4000-8000-000000000003","role":"authenticated"}',true);
select lives_ok($$select public.resume_campaign('15000000-0000-4000-8000-000000000001','15030000-0000-4000-8000-000000000001',3,gen_random_uuid())$$,'Member can resume');
select set_config('request.jwt.claims','{"sub":"15010000-0000-4000-8000-000000000004","role":"authenticated"}',true);
select throws_ok($$select public.pause_campaign('15000000-0000-4000-8000-000000000001','15030000-0000-4000-8000-000000000001',4,gen_random_uuid())$$,'42501',null,'Supervisor cannot pause');
select set_config('request.jwt.claims','{"sub":"15010000-0000-4000-8000-000000000005","role":"authenticated"}',true);
select throws_ok($$select public.pause_campaign('15000000-0000-4000-8000-000000000001','15030000-0000-4000-8000-000000000001',4,gen_random_uuid())$$,'42501',null,'Agent cannot pause');
reset role;
select set_config('request.jwt.claims','{"sub":"15010000-0000-4000-8000-000000000001","role":"authenticated"}',true);
update public.campaign_dispatch_settings set enabled=false where organization_id='15000000-0000-4000-8000-000000000001';
set local role authenticated;
select public.start_campaign('15000000-0000-4000-8000-000000000001','15030000-0000-4000-8000-000000000005');
select throws_ok($$select public.pause_campaign('15000000-0000-4000-8000-000000000001','15030000-0000-4000-8000-000000000005',0,gen_random_uuid())$$,'23514',null,'Legacy transport untouched');
select public.cancel_campaign('15000000-0000-4000-8000-000000000001','15030000-0000-4000-8000-000000000002');
select throws_ok($$select public.resume_campaign('15000000-0000-4000-8000-000000000001','15030000-0000-4000-8000-000000000002',1,gen_random_uuid())$$,'23514',null,'Cancellation wins over resume');
select is((select actor_name from public.list_campaign_activity_page('15000000-0000-4000-8000-000000000001','15030000-0000-4000-8000-000000000001',1,50) where event_type='campaign_resumed' order by id limit 1),'Test 1','Activity exposes safe actor label');
reset role;
select * from finish();
rollback;
