begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, storage;
select no_plan();

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at, created_at,
  updated_at, confirmation_token, recovery_token, email_change_token_new, email_change
) values
('00000000-0000-0000-0000-000000000000','b1100000-0000-4000-8000-000000000001','authenticated','authenticated','rr-owner@example.test',crypt('password',gen_salt('bf')),'{}','{}',now(),now(),now(),'','','',''),
('00000000-0000-0000-0000-000000000000','b1100000-0000-4000-8000-000000000002','authenticated','authenticated','rr-ali@example.test',crypt('password',gen_salt('bf')),'{}','{}',now(),now(),now(),'','','',''),
('00000000-0000-0000-0000-000000000000','b1100000-0000-4000-8000-000000000003','authenticated','authenticated','rr-sara@example.test',crypt('password',gen_salt('bf')),'{}','{}',now(),now(),now(),'','','','');

insert into public.organizations (id,name,extra)
values ('b1000000-0000-4000-8000-000000000001','Round Robin Org','{}');
insert into public.agents (id,organization_id,user_id,name,ai,extra) values
('b1200000-0000-4000-8000-000000000001','b1000000-0000-4000-8000-000000000001','b1100000-0000-4000-8000-000000000001','Owner',false,'{"role":"owner"}'),
('b1200000-0000-4000-8000-000000000002','b1000000-0000-4000-8000-000000000001','b1100000-0000-4000-8000-000000000002','Ali',false,'{"role":"agent"}'),
('b1200000-0000-4000-8000-000000000003','b1000000-0000-4000-8000-000000000001','b1100000-0000-4000-8000-000000000003','Sara',false,'{"role":"agent"}');
insert into public.organizations_addresses (organization_id,service,address,extra,status)
values ('b1000000-0000-4000-8000-000000000001','whatsapp','rr-phone','{}','connected');
insert into public.routing_queues (id,organization_id,name,status)
values ('b1300000-0000-4000-8000-000000000001','b1000000-0000-4000-8000-000000000001','VIP Support','active');
insert into public.routing_queue_members values
('b1000000-0000-4000-8000-000000000001','b1300000-0000-4000-8000-000000000001','b1200000-0000-4000-8000-000000000002',now()),
('b1000000-0000-4000-8000-000000000001','b1300000-0000-4000-8000-000000000001','b1200000-0000-4000-8000-000000000003',now()+interval '1 second');

select is((select auto_assign_conversations from public.organization_automation_settings where organization_id='b1000000-0000-4000-8000-000000000001'),false,'organization defaults to manual');
select is((select assignment_strategy from public.routing_queues where id='b1300000-0000-4000-8000-000000000001'),'manual','queue defaults to manual');

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','b1100000-0000-4000-8000-000000000001',true);
select is((select auto_assign_conversations from public.update_organization_auto_assignment('b1000000-0000-4000-8000-000000000001',true)),true,'Owner enables master automation');
select is((select assignment_strategy from public.update_routing_queue_assignment_strategy('b1300000-0000-4000-8000-000000000001','round_robin')),'round_robin','Owner enables Round Robin');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','b1100000-0000-4000-8000-000000000002',true);
select is((select available from public.set_my_assignment_availability('b1000000-0000-4000-8000-000000000001',true)),true,'Ali becomes available');
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub','b1100000-0000-4000-8000-000000000003',true);
select is((select eligible from public.set_my_assignment_availability('b1000000-0000-4000-8000-000000000001',true)),true,'Sara becomes eligible');
reset role;

insert into public.conversations (id,organization_id,service,organization_address,contact_address,status,routing_queue_id,routed_at,extra) values
('b1400000-0000-4000-8000-000000000001','b1000000-0000-4000-8000-000000000001','whatsapp','rr-phone','15550000001','active','b1300000-0000-4000-8000-000000000001',now(),'{}'),
('b1400000-0000-4000-8000-000000000002','b1000000-0000-4000-8000-000000000001','whatsapp','rr-phone','15550000002','active','b1300000-0000-4000-8000-000000000001',now()+interval '1 second','{}');
select is((public.try_auto_assign_conversation('b1400000-0000-4000-8000-000000000001','recovery')).assigned_agent_id,'b1200000-0000-4000-8000-000000000002'::uuid,'first conversation goes to Ali');
select is((public.try_auto_assign_conversation('b1400000-0000-4000-8000-000000000002','recovery')).assigned_agent_id,'b1200000-0000-4000-8000-000000000003'::uuid,'second conversation rotates to Sara');
select is((select count(*) from public.conversation_assignment_events),2::bigint,'assignment history is append only');
select is((select count(*) from public.user_notifications where notification_type='conversation_assigned'),2::bigint,'assignees receive notifications');
select is((select count(*) from public.messages where direction='internal' and content->>'kind'='assignment_event'),2::bigint,'timeline receives internal assignment events');

update public.agent_assignment_presence set last_heartbeat_at=now()-interval '3 minutes' where agent_id='b1200000-0000-4000-8000-000000000002';
insert into public.conversations (id,organization_id,service,organization_address,contact_address,status,routing_queue_id,routed_at,extra)
values ('b1400000-0000-4000-8000-000000000003','b1000000-0000-4000-8000-000000000001','whatsapp','rr-phone','15550000003','active','b1300000-0000-4000-8000-000000000001',now(),'{}');
select is((public.try_auto_assign_conversation('b1400000-0000-4000-8000-000000000003','recovery')).assigned_agent_id,'b1200000-0000-4000-8000-000000000003'::uuid,'expired heartbeat is not eligible');

select * from finish();
rollback;
