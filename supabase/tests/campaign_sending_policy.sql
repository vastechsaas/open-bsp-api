begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions,public,auth;
select no_plan();
insert into public.organizations(id,name) values
('14000000-0000-4000-8000-000000000001','Policy A'),('14000000-0000-4000-8000-000000000002','Policy B');
insert into auth.users(id,email) values
('14010000-0000-4000-8000-000000000001','policy-owner@example.test'),('14010000-0000-4000-8000-000000000002','policy-platform@example.test');
insert into public.agents(id,organization_id,user_id,name,ai,extra) values
('14020000-0000-4000-8000-000000000001','14000000-0000-4000-8000-000000000001','14010000-0000-4000-8000-000000000001','Owner',false,'{"role":"owner"}');
insert into public.platform_admins(user_id) values ('14010000-0000-4000-8000-000000000002');
insert into public.organizations_addresses(organization_id,address,service,status,extra) values
('14000000-0000-4000-8000-000000000001','policy-a','whatsapp','connected','{}'),
('14000000-0000-4000-8000-000000000001','policy-b','whatsapp','connected','{}');
insert into public.campaign_dispatch_settings values ('14000000-0000-4000-8000-000000000001',true);
create temp table policy_input(value jsonb);
insert into policy_input values ('{"enabled":true,"daily_limit":2,"max_sends_per_minute":60,"recipient_cap":1,"budget_timezone":"UTC"}');
grant select on policy_input to authenticated;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"14010000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select throws_ok($$select public.get_platform_campaign_policy('14000000-0000-4000-8000-000000000001')$$,'42501',null,'Owner cannot read Super Admin policy');
select throws_ok($$select public.update_platform_campaign_policy('14000000-0000-4000-8000-000000000001',(select value from policy_input),0,gen_random_uuid())$$,'42501',null,'Owner cannot configure limits');
select throws_ok($$select public.get_campaign_sending_policy('14000000-0000-4000-8000-000000000002')$$,'42501',null,'No cross-tenant policy access');
select ok(not has_table_privilege('authenticated','public.campaign_send_ledger','select'),'Recipient accounting remains backend-only');
select ok(not has_table_privilege('authenticated','public.campaign_sending_policies','update'),'Direct REST cannot change policy');
select ok(not has_function_privilege('anon','public.begin_campaign_dispatch_send(uuid,uuid)','execute'),'API-key caller cannot invoke send boundary');
select set_config('request.jwt.claims','{"sub":"14010000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select is(public.update_platform_campaign_policy('14000000-0000-4000-8000-000000000001',(select value from policy_input),0,'14040000-0000-4000-8000-000000000001')->>'revision','1','Super Admin saves policy atomically');
select is(public.update_platform_campaign_policy('14000000-0000-4000-8000-000000000001',(select value from policy_input),0,'14040000-0000-4000-8000-000000000001')->>'revision','1','Duplicate save returns original result');
select throws_ok($$select public.update_platform_campaign_policy('14000000-0000-4000-8000-000000000001',(select value from policy_input),0,gen_random_uuid())$$,'40001',null,'Concurrent stale policy save rejected');
select throws_ok($$select public.update_platform_campaign_policy('14000000-0000-4000-8000-000000000001',(select value||'{"daily_limit":0}'::jsonb from policy_input),1,gen_random_uuid())$$,'22023',null,'Zero ceiling rejected');
select throws_ok($$select public.update_platform_campaign_policy('14000000-0000-4000-8000-000000000001',(select value||'{"budget_timezone":"Not/AZone"}'::jsonb from policy_input),1,gen_random_uuid())$$,'22023',null,'Unknown time zone rejected');
select throws_ok($$select public.update_platform_campaign_policy('14000000-0000-4000-8000-000000000001',(select value||'{"daily_limit":"2"}'::jsonb from policy_input),1,gen_random_uuid())$$,'22023',null,'Numeric strings do not bypass validation');
reset role;
select is((select count(*) from public.platform_admin_action_events where action_type='organization_campaign_policy.update' and organization_id='14000000-0000-4000-8000-000000000001'),1::bigint,'Save audit is idempotent');
insert into public.campaigns(id,organization_id,name,organization_address,template,audience_type,expires_at)
select ('14030000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'14000000-0000-4000-8000-000000000001','Policy campaign '||n,
 case when n in (11,15,16) then 'policy-b' else 'policy-a' end,
 '{"id":"mock-only","name":"mock_only","language":"en_US","status":"APPROVED","components":[]}', 'csv_upload',clock_timestamp()+interval '7 days'
from generate_series(10,16) n;
insert into public.campaign_csv_recipients(organization_id,campaign_id,contact_address)
select organization_id,id,case when right(name,2)='10' then '+923001234567' when right(name,2)='11' then '923001234567' else '9230012345'||right(name,2) end
from public.campaigns where organization_id='14000000-0000-4000-8000-000000000001';
select set_config('request.jwt.claims','{"sub":"14010000-0000-4000-8000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select is(public.start_campaign('14000000-0000-4000-8000-000000000001','14030000-0000-4000-8000-000000000010'),1::bigint,'Start snapshots once with policy');
select is(public.start_campaign('14000000-0000-4000-8000-000000000001','14030000-0000-4000-8000-000000000011'),1::bigint,'Second number shares organization policy');
reset role;
select ok((select policy_required from public.campaigns where id='14030000-0000-4000-8000-000000000010'),'Started campaign cannot lose enforcement');
select throws_ok($$update public.campaigns set expires_at=null where id='14030000-0000-4000-8000-000000000010'$$,'23514',null,'Queued schedule cannot be removed');
create temp table policy_jobs(label text primary key,id uuid,token uuid,claim jsonb);
insert into policy_jobs(label,id) select right(c.name,2),j.id from public.campaign_dispatch_jobs j join public.campaigns c on c.id=j.campaign_id where j.organization_id='14000000-0000-4000-8000-000000000001';
-- Immediate fixtures must be safely due, not depend on sub-millisecond host/VM
-- clock agreement. Scheduled-start assertions below keep their future due date.
update public.campaign_dispatch_jobs set due_at=clock_timestamp()-interval '1 second' where organization_id='14000000-0000-4000-8000-000000000001';
update policy_jobs set claim=public.claim_campaign_dispatch_job(id) where label='10';
select diag('initial preparation: '||claim::text) from policy_jobs where label='10' and claim->>'phase'<>'claimed';
update policy_jobs set token=(claim->>'lease_token')::uuid where label='10';
select ok(public.begin_campaign_dispatch_send(id,token),'First actual submission reserves capacity') from policy_jobs where label='10';
select ok(not public.begin_campaign_dispatch_send(id,token),'Same attempt cannot reserve twice') from policy_jobs where label='10';
select is(public.finish_campaign_dispatch_job(id,token,'needs_review',null,'mock_uncertainty'),'needs_review','Ambiguous send remains uncertain') from policy_jobs where label='10';
select is((select count(*) from public.campaign_send_ledger where state='reserved' and organization_id='14000000-0000-4000-8000-000000000001'),1::bigint,'Unknown send retains allowance');
select is(public.finish_campaign_dispatch_job(id,token,'accepted','wamid.mock-only'),'accepted','Late acceptance settles same reservation') from policy_jobs where label='10';
select is(public.finish_campaign_dispatch_job(id,token,'accepted','wamid.mock-only'),'accepted','Repeated settlement remains idempotent') from policy_jobs where label='10';
select is((public.claim_campaign_dispatch_job(id)->>'phase'),'deferred','Recipient cap spans numbers and plus formatting') from policy_jobs where label='11';
select is((select waiting_reason from public.campaign_dispatch_jobs where id=(select id from policy_jobs where label='11')),'recipient_frequency','Recipient wait is explicit');
select is((select d.attempts from public.campaign_deliveries d join public.campaign_dispatch_jobs j on j.delivery_id=d.id where j.id=(select id from policy_jobs where label='11')),0,'Deferral does not consume a send attempt');
-- Move only mock accounting timestamps, not the database clock, beyond rate pacing.
update public.campaign_send_ledger set submitted_at=clock_timestamp()-interval '61 seconds',accepted_at=clock_timestamp()-interval '61 seconds' where organization_id='14000000-0000-4000-8000-000000000001';
select public.start_campaign('14000000-0000-4000-8000-000000000001','14030000-0000-4000-8000-000000000012');
select public.start_campaign('14000000-0000-4000-8000-000000000001','14030000-0000-4000-8000-000000000013');
insert into policy_jobs(label,id) select right(c.name,2),j.id from public.campaign_dispatch_jobs j join public.campaigns c on c.id=j.campaign_id where j.organization_id='14000000-0000-4000-8000-000000000001' and right(c.name,2) in ('12','13');
update public.campaign_dispatch_jobs set due_at=clock_timestamp()-interval '1 second' where id in (select id from policy_jobs where label in ('12','13'));
update policy_jobs set claim=public.claim_campaign_dispatch_job(id) where label='12';
update policy_jobs set claim=public.claim_campaign_dispatch_job(id) where label='13';
select diag('preparation '||label||': '||claim::text) from policy_jobs where label in ('12','13') and claim->>'phase'<>'claimed';
select is(claim->>'phase','claimed','Both contenders prepare before the final capacity fence: '||label) from policy_jobs where label in ('12','13') order by label;
update policy_jobs set token=(claim->>'lease_token')::uuid where label in ('12','13');
select ok(public.begin_campaign_dispatch_send(id,token),'One preparer takes the final daily slot') from policy_jobs where label='12';
select ok(not public.begin_campaign_dispatch_send(id,token),'Another preparer cannot spend the same last slot') from policy_jobs where label='13';
select is((select waiting_reason from public.campaign_dispatch_jobs where id=(select id from policy_jobs where label='13')),'daily_allowance','Budget wait is not a failure');
select is((select count(*) from public.campaign_send_ledger where organization_id='14000000-0000-4000-8000-000000000001' and state<>'released'),2::bigint,'Reservations plus accepted sends obey ceiling');
select public.finish_campaign_dispatch_job(id,token,'failed',null,'mock_rejected') from policy_jobs where label='12';
select is((select state from public.campaign_send_ledger where job_id=(select id from policy_jobs where label='12')),'released','Definitive rejection releases count capacity');
select is((select count(*) from public.campaign_send_ledger where organization_id='14000000-0000-4000-8000-000000000001'),2::bigint,'Rejected send still remains in rate accounting');
update public.campaign_send_ledger set submitted_at=clock_timestamp()-interval '61 seconds' where job_id=(select id from policy_jobs where label='12');
-- Scheduled starts are not published early.
update public.campaigns set scheduled_start_at=clock_timestamp()+interval '2 days' where id='14030000-0000-4000-8000-000000000014';
select public.start_campaign('14000000-0000-4000-8000-000000000001','14030000-0000-4000-8000-000000000014');
select ok(not exists(select 1 from jsonb_array_elements(public.claim_campaign_dispatch_publications(100)) n where n->>'campaign_id'='14030000-0000-4000-8000-000000000014'),'Scheduled campaign is not put on broker early');
select is(public.campaign_window_next_at('2026-10-31 00:00:00+05','Asia/Karachi','09:00','18:00'),'2026-10-31 09:00:00+05'::timestamptz,'Midnight reset still waits for daily opening');
select is(public.campaign_window_next_at('2026-10-31 02:00:00+05','Asia/Karachi','22:00','06:00'),'2026-10-31 02:00:00+05'::timestamptz,'Overnight window includes next-day early hours');
select is(public.campaign_window_next_at('2026-11-01 05:30:00+00','America/New_York','01:00','03:00'),'2026-11-01 05:30:00+00'::timestamptz,'DST overlap evaluates an explicit instant');
-- Cancellation fences preparation without touching acceptance/uncertainty.
select public.start_campaign('14000000-0000-4000-8000-000000000001','14030000-0000-4000-8000-000000000016');
insert into policy_jobs(label,id) select '16',id from public.campaign_dispatch_jobs where campaign_id='14030000-0000-4000-8000-000000000016';
update public.campaign_dispatch_jobs set due_at=clock_timestamp()-interval '1 second' where id=(select id from policy_jobs where label='16');
update policy_jobs set claim=public.claim_campaign_dispatch_job(id) where label='16';
update policy_jobs set token=(claim->>'lease_token')::uuid where label='16';
select lives_ok($$select public.cancel_campaign('14000000-0000-4000-8000-000000000001','14030000-0000-4000-8000-000000000016')$$,'Authorized cancellation is idempotent');
select ok(not public.begin_campaign_dispatch_send(id,token),'Cancelled preparer cannot send') from policy_jobs where label='16';
select is((select phase from public.campaign_dispatch_jobs where id=(select id from policy_jobs where label='16')),'cancelled','Cancelled job is terminal');
select ok(not exists(select 1 from public.campaign_send_ledger where job_id=(select id from policy_jobs where label='16')),'Cancellation does not spend allowance');
-- Expiry while preparation is in progress is checked again before submitting.
update public.campaigns set expires_at=clock_timestamp()+interval '1 second' where id='14030000-0000-4000-8000-000000000015';
select public.start_campaign('14000000-0000-4000-8000-000000000001','14030000-0000-4000-8000-000000000015');
insert into policy_jobs(label,id) select '15',id from public.campaign_dispatch_jobs where campaign_id='14030000-0000-4000-8000-000000000015';
update public.campaign_dispatch_jobs set due_at=clock_timestamp()-interval '1 second' where id=(select id from policy_jobs where label='15');
update policy_jobs set claim=public.claim_campaign_dispatch_job(id) where label='15';
update policy_jobs set token=(claim->>'lease_token')::uuid where label='15';
select ok((select expires_at is not null from public.campaigns where id='14030000-0000-4000-8000-000000000015'),'Starting a legacy campaign preserves its explicit deadline');
-- Wait for the actual database deadline, not an assumed host/container clock delta.
do $$declare deadline timestamptz; waits integer:=0; begin
  select expires_at into strict deadline from public.campaigns where id='14030000-0000-4000-8000-000000000015';
  while clock_timestamp()<deadline loop
    perform pg_sleep(0.05); waits:=waits+1;
    if waits>200 then raise exception 'Database clock did not reach fixture deadline'; end if;
  end loop;
end$$;
select ok(not public.begin_campaign_dispatch_send(id,token),'Expiry wins over an already-prepared send') from policy_jobs where label='15';
select is((select phase from public.campaign_dispatch_jobs where id=(select id from policy_jobs where label='15')),'expired','Expired job does not silently complete');
select is((select expired_count from public.campaigns where id='14030000-0000-4000-8000-000000000015'),1,'Unsent expired recipient has its own count');
select is((select sum(attempts) from public.campaign_deliveries where campaign_id='14030000-0000-4000-8000-000000000015'),0::bigint,'Expiry does not consume a send attempt');
select set_config('request.jwt.claims','{"sub":"14010000-0000-4000-8000-000000000002","role":"authenticated"}',true);
set local role authenticated;
select throws_ok($$select public.update_platform_campaign_policy('14000000-0000-4000-8000-000000000001',(select value||'{"enabled":false}'::jsonb from policy_input),1,gen_random_uuid())$$,'23514',null,'Active policy-managed jobs cannot be released by disabling limits');
select throws_ok($$select public.update_platform_campaign_policy('14000000-0000-4000-8000-000000000001',(select value||'{"budget_timezone":"Asia/Karachi"}'::jsonb from policy_input),1,gen_random_uuid())$$,'23514',null,'Recent submissions prevent time-zone quota reset');
reset role;
select ok((select count(*)=0 from public.campaign_send_ledger where organization_id='14000000-0000-4000-8000-000000000002'),'Other organization has independent usage');
-- Rejections free budget/frequency, but still consume real submission pacing.
update public.campaign_send_ledger set submitted_at=clock_timestamp(),accepted_at=clock_timestamp()
where job_id=(select id from policy_jobs where label='12');
select is(public.campaign_dispatch_eligibility(id)->>'reason','number_rate','Definitive rejection still enforces smooth per-number pacing') from policy_jobs where label='13';
update public.campaign_send_ledger set submitted_at=clock_timestamp()-interval '25 hours',accepted_at=clock_timestamp()-interval '25 hours'
where organization_id='14000000-0000-4000-8000-000000000001';
select is(public.campaign_dispatch_eligibility(id),'{}'::jsonb,'Expired accounting windows make deferred work eligible without a new audience') from policy_jobs where label='13';
-- Recovery must stop even far-future scheduled work without waiting for MQ.
select set_config('request.jwt.claims','{"sub":"14010000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select public.cancel_campaign('14000000-0000-4000-8000-000000000001','14030000-0000-4000-8000-000000000014');
select lives_ok($$select public.recover_campaign_dispatch_jobs()$$,'Recovery handles cancellation and expiry without alias conflicts');
select is((select phase from public.campaign_dispatch_jobs where campaign_id='14030000-0000-4000-8000-000000000014'),'cancelled','Future notification cannot send cancelled campaign');
select is((select cancelled_count from public.campaigns where id='14030000-0000-4000-8000-000000000014'),1,'Cancelled recipients have distinct terminal counters');
select is((select count(*) from public.campaign_send_ledger where organization_id='14000000-0000-4000-8000-000000000001'),2::bigint,'Unsent cancellation and expiry create no reservations');
-- Campaigns can drain their audience across days without a final deadline.
insert into public.campaigns(id,organization_id,name,organization_address,template,audience_type,send_window_start,send_window_end,scheduled_start_at,schedule_timezone)
values ('14030000-0000-4000-8000-000000000017','14000000-0000-4000-8000-000000000001','No deadline policy campaign','policy-a',
 '{"id":"mock-only","name":"mock_only","language":"en_US","status":"APPROVED","components":[]}','csv_upload','09:00','18:00',clock_timestamp()+interval '1 day','Asia/Karachi');
insert into public.campaign_csv_recipients(organization_id,campaign_id,contact_address)
values ('14000000-0000-4000-8000-000000000001','14030000-0000-4000-8000-000000000017','mock-no-real-recipient');
select is(public.start_campaign('14000000-0000-4000-8000-000000000001','14030000-0000-4000-8000-000000000017'),1::bigint,'Enforced scheduled campaign with a daily window can start without expiry');
select ok((select policy_required and expires_at is null and max_sends_per_minute is null from public.campaigns where id='14030000-0000-4000-8000-000000000017'),'No deadline retains policy enforcement and inherits organization speed');
select ok((select phase='pending' and waiting_reason='scheduled' from public.campaign_dispatch_jobs where campaign_id='14030000-0000-4000-8000-000000000017'),'No deadline does not bypass scheduled start');
update public.campaign_send_ledger set state='reserved',submitted_at=clock_timestamp() where organization_id='14000000-0000-4000-8000-000000000001';
select ok(not (public.campaign_dispatch_eligibility(id) ? 'terminal') and (public.campaign_dispatch_eligibility(id)->>'next_at')::timestamptz>clock_timestamp(),'A no-deadline campaign waits for capacity rather than expiring') from public.campaign_dispatch_jobs where campaign_id='14030000-0000-4000-8000-000000000017';
select * from finish();
rollback;
