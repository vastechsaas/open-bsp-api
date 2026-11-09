begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public,auth;
select no_plan();
insert into public.organizations(id,name) values
('15500000-0000-4000-8000-000000000001','CSV export test'),
('15500000-0000-4000-8000-000000000009','Other export tenant');
insert into auth.users(id,email) values('15500000-0000-4000-8000-000000000002','campaign-export@example.test');
insert into auth.users(id,email) values('15500000-0000-4000-8000-000000000004','campaign-export-other-owner@example.test');
insert into public.agents(id,organization_id,user_id,name,ai,extra) values
('15500000-0000-4000-8000-000000000003','15500000-0000-4000-8000-000000000001','15500000-0000-4000-8000-000000000002','Export Owner',false,'{"role":"owner"}');
insert into public.agents(id,organization_id,user_id,name,ai,extra) values
('15500000-0000-4000-8000-000000000005','15500000-0000-4000-8000-000000000001','15500000-0000-4000-8000-000000000004','Second Owner',false,'{"role":"owner"}');
insert into public.organizations_addresses(organization_id,address,service,status,extra) values
('15500000-0000-4000-8000-000000000001','export-number-id','whatsapp','connected','{"phone_number":"+923001234567","verified_name":"Test Sender","access_token":"do-not-export"}');
insert into public.campaigns(id,organization_id,name,organization_address,template,audience_type,status,schedule_timezone) values
('15500000-0000-4000-8000-000000000010','15500000-0000-4000-8000-000000000001','CSV export','export-number-id',
'{"id":"approved","name":"approved","language":"en_US","status":"APPROVED","components":[{"type":"BODY","text":"Hello"}]}','csv_upload','completed','Asia/Karachi');
insert into public.campaign_deliveries(organization_id,campaign_id,contact_address,status,external_id)
select '15500000-0000-4000-8000-000000000001','15500000-0000-4000-8000-000000000010','1555'||lpad(i::text,7,'0'),
case i when 3 then 'failed' when 4 then 'needs_review' when 5 then 'cancelled' when 6 then 'expired' else 'accepted' end,'wamid.export.'||i
from generate_series(1,601) i;
insert into public.campaign_delivery_receipts(delivery_id,organization_id,campaign_id,read_at,failed_at)
select id,organization_id,campaign_id,case when contact_address='15550000001' then now() end,
  case when contact_address in ('15550000001','15550000002') then now() end
from public.campaign_deliveries where contact_address in ('15550000001','15550000002');
select set_config('request.jwt.claim.sub','15500000-0000-4000-8000-000000000002',true);
select set_config('request.jwt.claim.role','authenticated',true);
create temp table export_result(info jsonb);
grant all on export_result to authenticated;
set local role authenticated;
select is(public.get_campaign_log_export('15500000-0000-4000-8000-000000000001','15500000-0000-4000-8000-000000000010'),null::jsonb,'no export initially');
insert into export_result select public.request_campaign_log_export('15500000-0000-4000-8000-000000000001','15500000-0000-4000-8000-000000000010','15500000-0000-4000-8000-000000000020');
select is((select (info->>'row_count')::bigint from export_result),601::bigint,'exports every recipient beyond 500 rows');
select is(public.request_campaign_log_export('15500000-0000-4000-8000-000000000001','15500000-0000-4000-8000-000000000010','15500000-0000-4000-8000-000000000020'),(select info from export_result),'duplicate request is idempotent');
select is(public.request_campaign_log_export('15500000-0000-4000-8000-000000000001','15500000-0000-4000-8000-000000000010','15500000-0000-4000-8000-000000000021'),(select info from export_result),'simultaneous preparation coalesces');
select throws_ok($$select * from public.campaign_log_export_rows$$,'42501',null,'snapshots have no direct REST access');
select throws_ok($$select public.claim_campaign_log_export()$$,'42501',null,'claim is backend-only');
select throws_ok($$select public.request_campaign_log_export('15500000-0000-4000-8000-000000000009','15500000-0000-4000-8000-000000000010',gen_random_uuid())$$,'42501',null,'tenant isolation');
reset role;
select is((select status from public.campaign_log_export_rows where recipient='15550000001'),'Delivered','read evidence wins over conflicting failure');
select is((select status from public.campaign_log_export_rows where recipient='15550000002'),'Not Delivered','receipt failure');
select is((select status from public.campaign_log_export_rows where recipient='15550000003'),'Not Delivered','definitive dispatch failure');
select is((select count(*) from public.campaign_log_export_rows where status=''),598::bigint,'accepted, cancelled, expired and uncertain stay blank');
select ok((select bool_and(sent_at is null) from public.campaign_log_export_rows),'no invented historical attempt timestamps');
select is((select sender_number from public.campaign_log_exports),'+923001234567','sender is a phone number, not provider ID');
select ok(not exists(select 1 from public.campaign_log_exports where template::text like '%do-not-export%' or mapping::text like '%do-not-export%'),'account credential is never copied');
insert into public.campaign_delivery_receipts(delivery_id,organization_id,campaign_id,delivered_at)
select id,organization_id,campaign_id,now() from public.campaign_deliveries where contact_address='15550000007';
select is((select status from public.campaign_log_export_rows where recipient='15550000007'),'','late receipt cannot mutate snapshot');

create temp table claimed as select * from public.claim_campaign_log_export();
select is((select state from claimed),'processing','background claim starts');
select is((public.claim_campaign_log_export()).id,null::uuid,'live lease prevents simultaneous claimant');
select is(public.finish_campaign_log_export_part((select id from claimed),gen_random_uuid(),true),false,'stale token cannot checkpoint');
select ok(public.finish_campaign_log_export_part(id,lease_token,false),'upload failure recorded') from claimed;
select is((select processed_count from public.campaign_log_exports),0::bigint,'failed upload cannot advance cursor');
truncate claimed;
insert into claimed select * from public.claim_campaign_log_export();
update public.campaign_log_exports set lease_until=now()-interval '1 minute';
select is(public.finish_campaign_log_export_part(id,lease_token,true),false,'expired worker cannot commit') from claimed;
truncate claimed;
insert into claimed select * from public.claim_campaign_log_export();
select ok(public.finish_campaign_log_export_part(id,lease_token,true),'lease recovery checkpoints one part') from claimed;
select is((select processed_count from public.campaign_log_exports),100::bigint,'bounded checkpoint');
do $$declare j public.campaign_log_exports; begin
  for i in 1..3 loop select * into j from public.claim_campaign_log_export();
    perform public.finish_campaign_log_export_part(j.id,j.lease_token,false); end loop;
end$$;
select is((select state from public.campaign_log_exports),'failed','three failures stop automatic processing');
select is((select processed_count from public.campaign_log_exports),100::bigint,'retry exhaustion preserves finished parts');
set local role authenticated;
select is(public.retry_campaign_log_export((select (info->>'id')::uuid from export_result))->>'state','queued','Owner can retry failed preparation');
select throws_ok($$select public.issue_campaign_log_download((select (info->>'id')::uuid from export_result))$$,'P0001','Export unavailable','partial export cannot be downloaded');
reset role;
do $$declare j public.campaign_log_exports; begin
  for i in 1..6 loop select * into j from public.claim_campaign_log_export();
    perform public.finish_campaign_log_export_part(j.id,j.lease_token,true); end loop;
end$$;
select is((select state from public.campaign_log_exports),'ready','all seven chunks complete');
select is((select count(*) from public.campaign_log_export_parts),7::bigint,'parts are unique and ordered');
select is((select processed_count from public.campaign_log_exports),601::bigint,'last partial batch counted exactly');
create temp table download_ticket(value text);
grant all on download_ticket to authenticated;
set local role authenticated;
insert into download_ticket select public.issue_campaign_log_download((select (info->>'id')::uuid from export_result));
reset role;
select ok(public.consume_campaign_log_download((select value from download_ticket)) is not null,'download authorized');
select is(public.consume_campaign_log_download((select value from download_ticket)),null::jsonb,'ticket is one-use');
update public.agents set extra='{"role":"admin"}' where name='Export Owner';
set local role authenticated;
select throws_ok($$select public.get_campaign_log_export('15500000-0000-4000-8000-000000000001','15500000-0000-4000-8000-000000000010')$$,'42501',null,'revoked Owner cannot read status');
select throws_ok($$select public.issue_campaign_log_download((select (info->>'id')::uuid from export_result))$$,'42501',null,'revoked Owner cannot request download');
reset role;
update public.agents set extra='{"role":"owner"}' where name='Export Owner';
set local role authenticated;
truncate download_ticket;
insert into download_ticket select public.issue_campaign_log_download((select (info->>'id')::uuid from export_result));
reset role;
update public.agents set extra='{"role":"member"}' where name='Export Owner';
select is(public.consume_campaign_log_download((select value from download_ticket)),null::jsonb,'revocation after ticket issuance blocks download');
insert into auth.users(id,email) values('15500000-0000-4000-8000-000000000006','pending-export@example.test');
insert into public.agents(id,organization_id,user_id,name,ai,extra) values
('15500000-0000-4000-8000-000000000007','15500000-0000-4000-8000-000000000001','15500000-0000-4000-8000-000000000006','Pending Owner',false,
'{"role":"owner","invitation":{"status":"pending","email":"pending-export@example.test"}}');
select is(public.authorize_campaign_log_export('15500000-0000-4000-8000-000000000001','15500000-0000-4000-8000-000000000010','15500000-0000-4000-8000-000000000006'),false,'pending Owner cannot export');
update public.agents set extra='{"role":"owner"}' where name='Export Owner';
update public.campaign_log_exports set expires_at=now()-interval '1 second';
set local role authenticated;
select is(public.get_campaign_log_export('15500000-0000-4000-8000-000000000001','15500000-0000-4000-8000-000000000010'),null::jsonb,'expired export disappears');
reset role;
select is((select count(*) from public.campaign_log_export_cleanup_candidates()),1::bigint,'expired data queued for bounded cleanup');
update public.campaigns set status='running' where id='15500000-0000-4000-8000-000000000010';
set local role authenticated;
select throws_ok($$select public.request_campaign_log_export('15500000-0000-4000-8000-000000000001','15500000-0000-4000-8000-000000000010',gen_random_uuid())$$,'42501',null,'running campaign cannot export');
reset role;
select is((select count(*) from public.campaign_dispatch_jobs where campaign_id='15500000-0000-4000-8000-000000000010'),0::bigint,'export never creates sending jobs');
select is((select status from public.campaign_deliveries where contact_address='15550000003'),'failed','export never resets delivery outcomes');
select * from finish();
rollback;
