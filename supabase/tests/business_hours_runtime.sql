begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public,auth,storage;
select no_plan();

create temp table hours_schedule as select jsonb_build_object(
 'enabled',true,'mode','per_day','timezone','UTC',
 'all_days',jsonb_build_object('start_time','09:00','end_time','17:00'),
 'per_day',(select jsonb_object_agg(day,jsonb_build_object('enabled',day not in ('saturday','sunday'),
 'start_time','09:00','end_time','17:00')) from unnest(array['monday','tuesday','wednesday','thursday','friday','saturday','sunday']) day)
) value;
select ok(public.business_hours_schedule_open(null,'2026-10-05T10:00Z'),'unconfigured tenants preserve existing behavior');
select ok(public.business_hours_schedule_open((select value from hours_schedule),'2026-10-05T09:00Z'),'opening boundary is inclusive');
select ok(not public.business_hours_schedule_open((select value from hours_schedule),'2026-10-05T17:00Z'),'closing boundary is exclusive');
select ok(not public.business_hours_schedule_open((select value from hours_schedule),'2026-10-05T08:59Z'),'before opening is closed');
select ok(not public.business_hours_schedule_open((select value from hours_schedule),'2026-10-04T12:00Z'),'unchecked Sunday is closed');
select ok(public.business_hours_schedule_open((select value||'{"enabled":false}' from hours_schedule),'2026-10-04T12:00Z'),'disabled schedule is unrestricted');
select ok(public.business_hours_schedule_open((select value||'{"timezone":"Asia/Karachi"}' from hours_schedule),'2026-10-05T04:00Z'),'IANA timezone is evaluated against UTC');
select ok(not public.business_hours_schedule_open((select value||'{"holidays":[{"date":"2026-10-05","closed":true}]}' from hours_schedule),'2026-10-05T12:00Z'),'holiday closure overrides an open weekday');
select ok(public.business_hours_schedule_open((select value||'{"holidays":[{"date":"2026-10-04","closed":false,"start_time":"10:00","end_time":"12:00"}]}' from hours_schedule),'2026-10-04T11:00Z'),'special opening overrides a closed weekend');
select ok(not public.business_hours_schedule_open((select value||'{"holidays":[{"date":"2026-10-04","closed":false,"start_time":"10:00","end_time":"12:00"}]}' from hours_schedule),'2026-10-04T12:00Z'),'holiday closing boundary is exclusive');
select ok(public.business_hours_schedule_open((select value||'{"mode":"all_days","timezone":"America/New_York","all_days":{"start_time":"01:00","end_time":"04:00"}}' from hours_schedule),'2026-03-08T07:30Z'),'spring DST gap is evaluated in local time');
select ok(public.business_hours_schedule_open((select value||'{"mode":"all_days","timezone":"America/New_York","all_days":{"start_time":"01:00","end_time":"04:00"}}' from hours_schedule),'2026-11-01T06:30Z'),'repeated fall DST hour stays open');
select ok(public.business_hours_schedule_open((select value||'{"mode":"all_days","all_days":{"start_time":"00:00","end_time":"24:00"}}' from hours_schedule),'2026-10-05T23:59Z'),'24:00 supports full-day schedules');
select throws_ok($$select public.validate_business_hours_schedule((select value||'{"timezone":"Invalid/Zone"}' from hours_schedule))$$,'22023',null,'invalid timezone rejected server-side');
select throws_ok($$select public.validate_business_hours_schedule((select value||'{"holidays":[{"date":"2026-12-25","closed":true},{"date":"2026-12-25","closed":true}]}' from hours_schedule))$$,'22023',null,'duplicate holiday dates rejected');
select throws_ok($$select public.validate_business_hours_schedule((select value||'{"mode":"all_days","all_days":{"start_time":"17:00","end_time":"09:00"}}' from hours_schedule))$$,'22023',null,'unsupported overnight range rejected clearly');
select ok(not has_function_privilege('anon','public.business_hours_status(uuid,uuid,uuid,timestamptz)','EXECUTE'),'internal availability is not anonymous');
select ok(not has_function_privilege('authenticated','public.notify_support_unavailability(uuid,text,uuid)','EXECUTE'),'clients cannot originate arbitrary support notices');

insert into auth.users(instance_id,id,aud,role,email,encrypted_password,raw_app_meta_data,raw_user_meta_data,
 email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
select '00000000-0000-0000-0000-000000000000'::uuid,('cb110000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,
 'authenticated','authenticated','hours-runtime-'||i||'@example.test',crypt('password',gen_salt('bf')),'{}','{}',now(),now(),now(),'','','',''
from generate_series(1,3) i;
insert into public.organizations(id,name,extra) values
 ('cb100000-0000-4000-8000-000000000001','Hours Runtime','{}'),
 ('cb100000-0000-4000-8000-000000000002','Other Runtime','{}');
insert into public.agents(id,organization_id,user_id,name,ai,extra) values
 ('cb120000-0000-4000-8000-000000000001','cb100000-0000-4000-8000-000000000001','cb110000-0000-4000-8000-000000000001','Owner',false,'{"role":"owner"}'),
 ('cb120000-0000-4000-8000-000000000002','cb100000-0000-4000-8000-000000000001','cb110000-0000-4000-8000-000000000002','Agent',false,'{"role":"agent"}'),
 ('cb120000-0000-4000-8000-000000000003','cb100000-0000-4000-8000-000000000002','cb110000-0000-4000-8000-000000000003','Other Owner',false,'{"role":"owner"}');
insert into public.organizations_addresses(organization_id,service,address,extra,status)
values('cb100000-0000-4000-8000-000000000001','whatsapp','hours-phone','{}','connected');
insert into public.routing_queues(id,organization_id,name,assignment_strategy) values
 ('cb130000-0000-4000-8000-000000000001','cb100000-0000-4000-8000-000000000001','VIP','round_robin'),
 ('cb130000-0000-4000-8000-000000000002','cb100000-0000-4000-8000-000000000001','Mobile','round_robin'),
 ('cb130000-0000-4000-8000-000000000003','cb100000-0000-4000-8000-000000000002','Other','manual');
insert into public.routing_queue_members values('cb100000-0000-4000-8000-000000000001','cb130000-0000-4000-8000-000000000001','cb120000-0000-4000-8000-000000000002',now());
update public.organizations set extra=jsonb_build_object('business_hours',
 (select value||jsonb_build_object('holidays',jsonb_build_array(jsonb_build_object('date',to_char(now() at time zone 'UTC','YYYY-MM-DD'),'closed',true))) from hours_schedule))
where id='cb100000-0000-4000-8000-000000000001';
select is(public.business_hours_status('cb100000-0000-4000-8000-000000000001')->>'reason','outside_hours','closed date wins over presence');
update public.organizations set extra=jsonb_build_object('business_hours',jsonb_build_object('queue_overrides',
 jsonb_build_object('cb130000-0000-4000-8000-000000000001',(select value||'{"enabled":false}' from hours_schedule))))
where id='cb100000-0000-4000-8000-000000000001';
select ok((public.business_hours_status('cb100000-0000-4000-8000-000000000001','cb130000-0000-4000-8000-000000000001')->>'open')::boolean,'queue override replaces organization schedule');
select ok(not (public.business_hours_status('cb100000-0000-4000-8000-000000000001','cb130000-0000-4000-8000-000000000002')->>'open')::boolean,'other queues inherit organization schedule');
select throws_ok($$update public.organizations set extra=jsonb_build_object('business_hours',jsonb_build_object('queue_overrides',
 jsonb_build_object('cb130000-0000-4000-8000-000000000003',(select value from hours_schedule)))) where id='cb100000-0000-4000-8000-000000000001'$$,
 '22023',null,'cross-tenant queue overrides rejected');
update public.organizations set extra='{"business_hours":{"queue_overrides":{"cb130000-0000-4000-8000-000000000001":null}}}' where id='cb100000-0000-4000-8000-000000000001';
select ok(not (public.business_hours_status('cb100000-0000-4000-8000-000000000001','cb130000-0000-4000-8000-000000000001')->>'open')::boolean,'null removes override and restores inheritance');

update public.organization_automation_settings set auto_assign_conversations=true where organization_id='cb100000-0000-4000-8000-000000000001';
insert into public.agent_assignment_presence(organization_id,agent_id,available,last_heartbeat_at)
values('cb100000-0000-4000-8000-000000000001','cb120000-0000-4000-8000-000000000002',true,now());
insert into public.conversations(id,organization_id,service,organization_address,contact_address,status,routing_queue_id,extra)
values('cb140000-0000-4000-8000-000000000001','cb100000-0000-4000-8000-000000000001','whatsapp','hours-phone','15550009901','active','cb130000-0000-4000-8000-000000000001','{}');
select is((public.try_auto_assign_conversation('cb140000-0000-4000-8000-000000000001')).assigned_agent_id,null::uuid,'available agent is not assigned outside hours');
insert into public.messages(organization_id,conversation_id,direction,service,organization_address,contact_address,external_id,content)
values('cb100000-0000-4000-8000-000000000001','cb140000-0000-4000-8000-000000000001','incoming','whatsapp','hours-phone','15550009901','wamid.hours-source','{"version":"1","type":"text","kind":"text","text":"Support"}');
select lives_ok($$select public.notify_support_unavailability('cb140000-0000-4000-8000-000000000001','test-request')$$,'unavailable notice uses normal durable message dispatch');
select public.notify_support_unavailability('cb140000-0000-4000-8000-000000000001','test-request');
select is((select count(*) from public.messages where conversation_id='cb140000-0000-4000-8000-000000000001' and direction='outgoing'),1::bigint,'duplicate handoff notice is idempotent');
select is((select contact_address from public.messages where conversation_id='cb140000-0000-4000-8000-000000000001' and direction='outgoing'),
 '15550009901','notice preserves recipient for actual WhatsApp dispatch');
update public.contacts_addresses set status='blocked' where organization_id='cb100000-0000-4000-8000-000000000001' and address='15550009901';
select public.notify_support_unavailability('cb140000-0000-4000-8000-000000000001','blocked-request');
select is((select count(*) from public.messages where conversation_id='cb140000-0000-4000-8000-000000000001' and direction='outgoing'),1::bigint,'blocked contacts receive no availability reply');
update public.contacts_addresses set status='active' where organization_id='cb100000-0000-4000-8000-000000000001' and address='15550009901';

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','cb110000-0000-4000-8000-000000000001',true);
select lives_ok($$select public.get_business_hours_status('cb100000-0000-4000-8000-000000000001')$$,'owner can preview availability');
select throws_ok($$select public.get_business_hours_status('cb100000-0000-4000-8000-000000000002')$$,'42501',null,'preview enforces tenant membership');
select lives_ok($$update public.conversations set assigned_agent_id='cb120000-0000-4000-8000-000000000002' where id='cb140000-0000-4000-8000-000000000001'$$,'owner can explicitly override hours');
reset role;
select set_config('request.jwt.claim.sub','',true);
select lives_ok($$update public.conversations set name='Still serving' where id='cb140000-0000-4000-8000-000000000001'$$,'existing support chat remains usable after hours');
update public.conversations set assigned_agent_id=null where id='cb140000-0000-4000-8000-000000000001';
select throws_ok($$update public.conversations set assigned_agent_id='cb120000-0000-4000-8000-000000000002' where id='cb140000-0000-4000-8000-000000000001'$$,
 '23514',null,'service role cannot bypass schedule on direct assignment');
update public.organizations set extra='{"business_hours":{"mode":"all_days","all_days":{"start_time":"00:00","end_time":"24:00"},"holidays":[]}}'
where id='cb100000-0000-4000-8000-000000000001';
select is((public.try_auto_assign_conversation('cb140000-0000-4000-8000-000000000001')).assigned_agent_id,
 'cb120000-0000-4000-8000-000000000002'::uuid,'queued work becomes assignable after opening');
update public.agent_assignment_presence set available=false where agent_id='cb120000-0000-4000-8000-000000000002';
select is(public.business_hours_status('cb100000-0000-4000-8000-000000000001','cb130000-0000-4000-8000-000000000001')->>'reason','no_agents','open hours do not imply agent availability');
update public.agent_assignment_presence set available=true,last_heartbeat_at=now()-interval '3 minutes' where agent_id='cb120000-0000-4000-8000-000000000002';
select is(public.business_hours_status('cb100000-0000-4000-8000-000000000001','cb130000-0000-4000-8000-000000000001')->>'reason','no_agents','stale presence does not count as available');
-- A direct target that was offline must be able to claim its waiting request,
-- without granting other agents permission to take that target's chat.
update public.conversations set assigned_agent_id=null,routing_queue_id=null where id='cb140000-0000-4000-8000-000000000001';
insert into public.chatbot_node_bridges(organization_id,organization_address,node_company_id,engine,sync_status)
values('cb100000-0000-4000-8000-000000000001','hours-phone','991','node','active');
insert into public.chatbot_node_conversations(organization_id,organization_address,node_conversation_id,conversation_id,
 human_owned,lifecycle_enabled,ownership_revision,state,last_inbound_wamid,support_request)
values('cb100000-0000-4000-8000-000000000001','hours-phone','992','cb140000-0000-4000-8000-000000000001',false,true,'1','bot_ready','wamid.hours-source',
 '{"id":"cb150000-0000-4000-8000-000000000001","status":"waiting","source_wamid":"wamid.hours-source","target":{"agent_id":"cb120000-0000-4000-8000-000000000002"}}');
set local role authenticated;
select set_config('request.jwt.claim.sub','cb110000-0000-4000-8000-000000000002',true);
select lives_ok($$select public.begin_node_conversation_operation('cb100000-0000-4000-8000-000000000001',
 'cb140000-0000-4000-8000-000000000001','cb160000-0000-4000-8000-000000000001','takeover','wamid.hours-source','1')$$,'direct target can take over an unassigned waiting request after opening');
reset role;
select set_config('request.jwt.claim.sub','',true);
update public.chatbot_node_conversations set pending_request_id=null where conversation_id='cb140000-0000-4000-8000-000000000001';
update public.chatbot_node_operations set status='failed' where request_id='cb160000-0000-4000-8000-000000000001';
update public.organizations set extra=jsonb_build_object('business_hours',jsonb_build_object('holidays',
 jsonb_build_array(jsonb_build_object('date',to_char(now() at time zone 'UTC','YYYY-MM-DD'),'closed',true))))
where id='cb100000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub','cb110000-0000-4000-8000-000000000002',true);
select throws_ok($$select public.begin_node_conversation_operation('cb100000-0000-4000-8000-000000000001',
 'cb140000-0000-4000-8000-000000000001','cb160000-0000-4000-8000-000000000002','takeover','wamid.hours-source','1')$$,'23514',null,'agent cannot take over outside schedule even when already assigned');
reset role;
select set_config('request.jwt.claim.sub','',true);
-- More than one recovery page of closed requests cannot starve an open team.
update public.organizations set extra=jsonb_build_object('business_hours',jsonb_build_object('queue_overrides',
 jsonb_build_object('cb130000-0000-4000-8000-000000000002',(select value||'{"enabled":false}' from hours_schedule))))
where id='cb100000-0000-4000-8000-000000000001';
insert into public.routing_queue_members values('cb100000-0000-4000-8000-000000000001',
 'cb130000-0000-4000-8000-000000000002','cb120000-0000-4000-8000-000000000002',now());
update public.agent_assignment_presence set available=true,last_heartbeat_at=now() where agent_id='cb120000-0000-4000-8000-000000000002';
insert into public.conversations(id,organization_id,service,organization_address,contact_address,status,routing_queue_id,routed_at,extra)
select ('cb140000-0000-4000-9000-'||lpad(i::text,12,'0'))::uuid,'cb100000-0000-4000-8000-000000000001','whatsapp','hours-phone',
 '1555099'||lpad(i::text,5,'0'),'active','cb130000-0000-4000-8000-000000000001',now()-interval '2 days','{}'
from generate_series(1,100) i;
insert into public.conversations(id,organization_id,service,organization_address,contact_address,status,routing_queue_id,routed_at,extra)
values('cb140000-0000-4000-9000-000000000101','cb100000-0000-4000-8000-000000000001','whatsapp','hours-phone','155509999999','active',
 'cb130000-0000-4000-8000-000000000002',now(),'{}');
select is(public.process_auto_assignment_backlog('cb100000-0000-4000-8000-000000000001',null,100),1,
 'recovery page ignores closed-team requests before applying its limit');
select is((select assigned_agent_id from public.conversations where id='cb140000-0000-4000-9000-000000000101'),
 'cb120000-0000-4000-8000-000000000002'::uuid,'open team receives work behind 100 closed-team requests');
select * from finish();
rollback;
