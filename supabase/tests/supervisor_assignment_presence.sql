begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, storage;
select no_plan();

insert into auth.users (
  instance_id,id,aud,role,email,encrypted_password,raw_app_meta_data,raw_user_meta_data,
  email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change
) values
('00000000-0000-0000-0000-000000000000','c5100000-0000-4000-8000-000000000001','authenticated','authenticated','presence-supervisor@example.test',crypt('password',gen_salt('bf')),'{}','{}',now(),now(),now(),'','','',''),
('00000000-0000-0000-0000-000000000000','c5100000-0000-4000-8000-000000000002','authenticated','authenticated','presence-pending@example.test',crypt('password',gen_salt('bf')),'{}','{}',now(),now(),now(),'','','',''),
('00000000-0000-0000-0000-000000000000','c5100000-0000-4000-8000-000000000003','authenticated','authenticated','presence-owner@example.test',crypt('password',gen_salt('bf')),'{}','{}',now(),now(),now(),'','','','');
insert into public.organizations(id,name,extra) values
('c5000000-0000-4000-8000-000000000001','Presence organization','{}'),
('c5000000-0000-4000-8000-000000000002','Other organization','{}');
insert into public.agents(id,organization_id,user_id,name,ai,extra) values
('c5200000-0000-4000-8000-000000000001','c5000000-0000-4000-8000-000000000001','c5100000-0000-4000-8000-000000000001','Supervisor',false,'{"role":"supervisor","invitation":{"status":"accepted","email":"presence-supervisor@example.test"}}'),
('c5200000-0000-4000-8000-000000000002','c5000000-0000-4000-8000-000000000001','c5100000-0000-4000-8000-000000000002','Pending supervisor',false,'{"role":"supervisor","invitation":{"status":"pending","email":"presence-pending@example.test"}}'),
('c5200000-0000-4000-8000-000000000003','c5000000-0000-4000-8000-000000000001','c5100000-0000-4000-8000-000000000003','Owner',false,'{"role":"owner"}');

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','c5100000-0000-4000-8000-000000000001',true);
select is((select available from public.get_my_assignment_availability('c5000000-0000-4000-8000-000000000001')),false,'Supervisor initially Away');
select is((select available from public.set_my_assignment_availability('c5000000-0000-4000-8000-000000000001',true)),true,'Supervisor can become Available');
select is((select eligible from public.get_my_assignment_availability('c5000000-0000-4000-8000-000000000001')),true,'Supervisor fresh presence is eligible');
select is((select eligible from public.heartbeat_my_assignment_availability('c5000000-0000-4000-8000-000000000001')),true,'Supervisor refreshes heartbeat');
select is((select available from public.set_my_assignment_availability('c5000000-0000-4000-8000-000000000001',false)),false,'Supervisor can become Away');
select is((select last_heartbeat_at from public.get_my_assignment_availability('c5000000-0000-4000-8000-000000000001')),null::timestamptz,'Away clears heartbeat');
select throws_ok($$select * from public.heartbeat_my_assignment_availability('c5000000-0000-4000-8000-000000000001')$$,'23514','Agent is unavailable','Away supervisor cannot heartbeat back to Available');
select throws_ok($$select * from public.set_my_assignment_availability('c5000000-0000-4000-8000-000000000002',true)$$,'42501','accepted Agent or Supervisor role required','Cannot update another organization');
select throws_ok($$select * from public.get_my_assignment_availability('c5000000-0000-4000-8000-000000000002')$$,'42501','accepted Agent or Supervisor role required','Cannot read another organization');
select throws_ok($$select * from public.heartbeat_my_assignment_availability('c5000000-0000-4000-8000-000000000002')$$,'42501','accepted Agent or Supervisor role required','Cannot heartbeat another organization');
select throws_ok($$select * from public.set_my_assignment_availability('c5000000-0000-4000-8000-000000000001',null)$$,'42501','accepted Agent or Supervisor role required','Null availability rejected');

select set_config('request.jwt.claim.sub','c5100000-0000-4000-8000-000000000002',true);
select throws_ok($$select * from public.get_my_assignment_availability('c5000000-0000-4000-8000-000000000001')$$,'42501','accepted Agent or Supervisor role required','Pending supervisor cannot read presence');
select throws_ok($$select * from public.set_my_assignment_availability('c5000000-0000-4000-8000-000000000001',true)$$,'42501','accepted Agent or Supervisor role required','Pending supervisor cannot change presence');
select throws_ok($$select * from public.heartbeat_my_assignment_availability('c5000000-0000-4000-8000-000000000001')$$,'42501','accepted Agent or Supervisor role required','Pending supervisor cannot heartbeat');
select set_config('request.jwt.claim.sub','c5100000-0000-4000-8000-000000000003',true);
select throws_ok($$select * from public.set_my_assignment_availability('c5000000-0000-4000-8000-000000000001',true)$$,'42501','accepted Agent or Supervisor role required','Owner role not newly enrolled');
reset role;
select is((select count(*) from public.agent_assignment_presence where organization_id='c5000000-0000-4000-8000-000000000001'),1::bigint,'Only accepted supervisor own presence created');
select * from finish();
rollback;
