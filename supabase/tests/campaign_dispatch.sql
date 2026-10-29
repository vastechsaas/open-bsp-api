begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select no_plan();
insert into public.organizations (id, name) values ('13300000-0000-4000-8000-000000000001', 'Dispatch Test');
insert into auth.users (id, email) values ('13300000-0000-4000-8000-000000000002', 'dispatch@example.test');
insert into public.agents (id, organization_id, user_id, name, ai, extra) values
 ('13300000-0000-4000-8000-000000000003', '13300000-0000-4000-8000-000000000001', '13300000-0000-4000-8000-000000000002', 'Dispatcher', false, '{"role":"owner"}');
insert into public.organizations_addresses (organization_id, address, service, status, extra)
values ('13300000-0000-4000-8000-000000000001', 'dispatch-number', 'whatsapp', 'connected', '{}');
insert into public.campaigns (id, organization_id, name, organization_address, template, audience_type)
select ('13300000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
 '13300000-0000-4000-8000-000000000001', 'Dispatch ' || n, 'dispatch-number',
 '{"id":"approved","name":"approved","language":"en_US","status":"APPROVED","components":[]}', 'csv_upload'
from generate_series(10, 11) n;
insert into public.campaign_csv_recipients (organization_id, campaign_id, contact_address)
select '13300000-0000-4000-8000-000000000001', '13300000-0000-4000-8000-000000000010', '1555000000' || n from generate_series(1,3) n;
insert into public.campaign_csv_recipients (organization_id, campaign_id, contact_address)
values ('13300000-0000-4000-8000-000000000001', '13300000-0000-4000-8000-000000000011', '15550000004');
insert into public.campaign_dispatch_settings values ('13300000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.sub', '13300000-0000-4000-8000-000000000002', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
select throws_ok($$select * from public.campaign_dispatch_settings$$, '42501', null, 'tenant cannot read deployment controls');
select throws_ok($$select public.claim_campaign_dispatch_publications(25)$$, '42501', null, 'tenant cannot publish jobs');
select is(public.start_campaign('13300000-0000-4000-8000-000000000001','13300000-0000-4000-8000-000000000010'),3::bigint,'Run snapshots three recipients');
select throws_ok($$select public.start_campaign('13300000-0000-4000-8000-000000000001','13300000-0000-4000-8000-000000000010')$$, '23514', 'campaign has already been started', 'duplicate Run does not duplicate work');
reset role;
select is((select count(*) from public.campaign_dispatch_jobs),3::bigint,'jobs are created transactionally');
select is((select dispatch_transport from public.campaigns where id='13300000-0000-4000-8000-000000000010'),'cloudamqp','flag selects CloudAMQP');
update public.campaign_dispatch_settings set enabled=false;
set local role authenticated;
select is(public.start_campaign('13300000-0000-4000-8000-000000000001','13300000-0000-4000-8000-000000000011'),1::bigint,'disabled flag preserves legacy Run');
reset role;
select is((select count(*) from public.campaign_dispatch_jobs),3::bigint,'legacy Run creates no AMQP jobs');
select throws_ok($$update public.campaigns set dispatch_transport='postgres' where id='13300000-0000-4000-8000-000000000010'$$,'23514','campaign transport is immutable after start','transport remains fixed after disabling');
select ok(not has_function_privilege('anon','public.claim_campaign_dispatch_job(uuid)','execute'),'anon cannot dispatch');
select ok(not has_table_privilege('authenticated','public.campaign_dispatch_jobs','select'),'jobs are backend-only');
set local role service_role;
select is((select count(*) from public.claim_campaign_deliveries(25)),1::bigint,'legacy worker never claims AMQP recipients');
select is(jsonb_array_length(public.claim_campaign_dispatch_publications(25)),3,'publisher reserves three jobs');
select is(jsonb_array_length(public.claim_campaign_dispatch_publications(25)),0,'active publication leases cannot be double claimed');
create temp table states (label text primary key, id uuid, token uuid);
insert into states(label,id)
select right(d.contact_address,1), j.id from public.campaign_dispatch_jobs j join public.campaign_deliveries d on d.id=j.delivery_id;
select ok(not public.confirm_campaign_dispatch_publication((select id from states where label='1'),gen_random_uuid()),'wrong publisher token is fenced');
select ok(public.confirm_campaign_dispatch_publication(j.id,j.publication_token),'broker confirmation uses matching token')
from public.campaign_dispatch_jobs j join states s on s.id=j.id where s.label='1';
update states set token=(public.claim_campaign_dispatch_job(id)->>'lease_token')::uuid;
select is((select phase from public.campaign_dispatch_jobs j join states s on s.id=j.id where s.label='1'),'preparing','claim enters preparation');
select is((select sum(attempts) from public.campaign_deliveries where campaign_id='13300000-0000-4000-8000-000000000010'),0::bigint,'preparation does not consume send attempts');
select ok(public.begin_campaign_dispatch_send(id,token),'send boundary commits before external request') from states where label='1';
select is(public.finish_campaign_dispatch_job(id,token,'accepted','wamid.dispatch.test'),'accepted','known Meta acceptance is saved') from states where label='1';
select is(public.finish_campaign_dispatch_job(id,token,'accepted','wamid.dispatch.test'),'accepted','acceptance write is idempotent') from states where label='1';
select is((select accepted_count from public.campaigns where id='13300000-0000-4000-8000-000000000010'),1,'duplicate result does not inflate counts');
select is(public.claim_campaign_dispatch_job(id)->>'phase','accepted','redelivery returns accepted without another send') from states where label='1';
update public.campaign_dispatch_jobs set lease_expires_at=clock_timestamp()-interval '1 second' where id=(select id from states where label='2');
select is(public.recover_campaign_dispatch_jobs(),1,'crashed pre-send preparation recovers');
select is((select phase from public.campaign_dispatch_jobs where id=(select id from states where label='2')),'pending','only provably unsent work is requeued');
select public.claim_campaign_dispatch_job(id) from states where label='2';
select ok(not public.begin_campaign_dispatch_send(id,token),'old preparer cannot send after recovery') from states where label='2';
update states set token=(select lease_token from public.campaign_dispatch_jobs where id=states.id) where label='2';
select public.begin_campaign_dispatch_send(id,token) from states where label='2';
update public.campaign_dispatch_jobs set lease_expires_at=clock_timestamp()-interval '1 second' where id=(select id from states where label='2');
select is(public.recover_campaign_dispatch_jobs(),1,'crashed submitting attempt is recovered conservatively');
select is((select phase from public.campaign_dispatch_jobs where id=(select id from states where label='2')),'needs_review','uncertain send is not queued');
select is((select needs_review_count from public.campaigns where id='13300000-0000-4000-8000-000000000010'),1,'uncertainty is counted independently');
select is((select status from public.campaigns where id='13300000-0000-4000-8000-000000000010'),'needs_review','uncertainty is not completed or failed');
select is(public.finish_campaign_dispatch_job(id,token,'accepted','wamid.dispatch.late'),'accepted','late known message ID reconciles the same attempt') from states where label='2';
select is((select needs_review_count from public.campaigns where id='13300000-0000-4000-8000-000000000010'),0,'late acceptance removes review count');
select is(public.finish_campaign_dispatch_job(id,token,'retry',null,'meta_130429'),'retry_scheduled','definitive transient rejection schedules next attempt') from states where label='3';
select is((select count(*) from public.campaign_dispatch_jobs),4::bigint,'retry has a new stable attempt job');
select ok((select due_at>clock_timestamp() from public.campaign_dispatch_jobs where attempt_no=2),'retry is delayed');
select is(public.claim_campaign_dispatch_job((select id from public.campaign_dispatch_jobs where attempt_no=2))->>'phase','deferred','early notification cannot send ahead of retry time');
update public.campaign_dispatch_jobs set due_at=clock_timestamp() where attempt_no=2;
insert into states(label,id) select 'retry2',id from public.campaign_dispatch_jobs where attempt_no=2;
update states set token=(public.claim_campaign_dispatch_job(id)->>'lease_token')::uuid where label='retry2';
select public.finish_campaign_dispatch_job(id,token,'retry',null,'meta_130429') from states where label='retry2';
update public.campaign_dispatch_jobs set due_at=clock_timestamp() where attempt_no=3;
insert into states(label,id) select 'retry3',id from public.campaign_dispatch_jobs where attempt_no=3;
update states set token=(public.claim_campaign_dispatch_job(id)->>'lease_token')::uuid where label='retry3';
select is(public.finish_campaign_dispatch_job(id,token,'retry',null,'meta_130429'),'failed','third failed attempt exhausts bounded retries') from states where label='retry3';
select is((select count(*) from public.campaign_dispatch_jobs where attempt_no>3),0::bigint,'no fourth attempt exists');
select is((select status from public.campaigns where id='13300000-0000-4000-8000-000000000010'),'completed','resolved terminal deliveries complete campaign');
reset role;
select * from finish();
rollback;
