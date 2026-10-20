begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, billing;
select no_plan();

insert into public.organizations (id, name, extra) values
  ('e1000000-0000-4000-8000-000000000001', 'DKR', '{}'),
  ('e1000000-0000-4000-8000-000000000002', 'Other Tenant', '{}');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, email_confirmed_at, created_at,
  updated_at, confirmation_token, recovery_token, email_change_token_new,
  email_change
) values
  ('00000000-0000-0000-0000-000000000000', 'e1100000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'platform@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'e1100000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'owner@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'e1100000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'supervisor@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'e1100000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'agent@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'e1100000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'member@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', 'e1100000-0000-4000-8000-000000000006', 'authenticated', 'authenticated', 'other-owner@example.test', crypt('password', gen_salt('bf')), '{}', '{}', now(), now(), now(), '', '', '', '');

insert into public.agents (id, organization_id, user_id, name, ai, extra) values
  ('e1200000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'e1100000-0000-4000-8000-000000000002', 'Owner', false, '{"role":"owner"}'),
  ('e1200000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001', 'e1100000-0000-4000-8000-000000000003', 'Supervisor', false, '{"role":"supervisor"}'),
  ('e1200000-0000-4000-8000-000000000003', 'e1000000-0000-4000-8000-000000000001', 'e1100000-0000-4000-8000-000000000004', 'Ali', false, '{"role":"agent"}'),
  ('e1200000-0000-4000-8000-000000000004', 'e1000000-0000-4000-8000-000000000001', 'e1100000-0000-4000-8000-000000000005', 'Member', false, '{"role":"member"}'),
  ('e1200000-0000-4000-8000-000000000005', 'e1000000-0000-4000-8000-000000000001', null, 'Pending Supervisor', false, '{"role":"supervisor","invitation":{"status":"pending","email":"pending-supervisor@example.test"}}'),
  ('e1200000-0000-4000-8000-000000000006', 'e1000000-0000-4000-8000-000000000001', null, 'AI Agent', true, '{}'),
  ('e1200000-0000-4000-8000-000000000007', 'e1000000-0000-4000-8000-000000000002', 'e1100000-0000-4000-8000-000000000006', 'Other Owner', false, '{"role":"owner"}');

insert into public.platform_admins (user_id, active)
values ('e1100000-0000-4000-8000-000000000001', true);

insert into public.routing_queues (id, organization_id, name) values
  ('e1300000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'VIP Support'),
  ('e1300000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000002', 'Other Queue');


-- A real Administrator is visible, but cannot be managed by these RPCs.
insert into public.agents(id,organization_id,name,ai,extra) values
 ('e1200000-0000-4000-8000-000000000008','e1000000-0000-4000-8000-000000000001','Administrator',false,
 '{"role":"admin","invitation":{"status":"pending","email":"admin@example.test"}}');
create function pg_temp.edit_member(member_id uuid,new_role public.role,new_name text default 'Edited',queues uuid[] default '{}')
returns public.agents language sql as $$
 select public.update_platform_organization_member(member_id,new_name,new_role,queues,
 (select updated_at from public.list_platform_organization_members_page('e1000000-0000-4000-8000-000000000001',1,50) where id=member_id),gen_random_uuid());
$$;
create function pg_temp.remove_member(member_id uuid) returns boolean language sql as $$
 select public.remove_platform_organization_member(member_id,
 (select updated_at from public.list_platform_organization_members_page('e1000000-0000-4000-8000-000000000001',1,50) where id=member_id),gen_random_uuid());
$$;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','e1100000-0000-4000-8000-000000000001',true);
set local role authenticated;
select results_eq(
 $$select role::text from public.list_platform_organization_members_page('e1000000-0000-4000-8000-000000000001',1,50) order by role::text$$,
 $$values ('admin'),('agent'),('member'),('owner'),('supervisor'),('supervisor')$$,
 'lists all five human roles, pending and accepted; excludes bots and other organizations');
select results_eq(
 $$select name,total_count from public.list_platform_organization_members_page('e1000000-0000-4000-8000-000000000001',2,1,'example.test')$$,
 $$values ('Ali'::text,6::bigint)$$,'search applies before count and server pagination');
select is((select count(*) from public.list_platform_organization_members_page('e1000000-0000-4000-8000-000000000002')),1::bigint,'selected organization isolation');
select throws_ok($$select pg_temp.edit_member('e1200000-0000-4000-8000-000000000008','owner')$$,'42501','TEAM_MEMBER_READ_ONLY','Administrator is read-only');
select throws_ok($$select pg_temp.remove_member('e1200000-0000-4000-8000-000000000004')$$,'42501','TEAM_MEMBER_READ_ONLY','Member cannot be removed');
select throws_ok($$select pg_temp.edit_member('e1200000-0000-4000-8000-000000000003','admin')$$,'42501','TEAM_MEMBER_READ_ONLY','cannot enter Administrator role');
select throws_ok($$select public.create_platform_organization_member_invitation('e1000000-0000-4000-8000-000000000001','Restricted','r@example.test','member',gen_random_uuid())$$,'42501','TEAM_MEMBER_READ_ONLY','cannot create Member role');
select lives_ok($$select public.create_platform_organization_member_invitation('e1000000-0000-4000-8000-000000000001','Pending owner','new-owner@example.test','owner',gen_random_uuid())$$,'create pending Owner without account');
select lives_ok($$select public.create_platform_organization_member_invitation('e1000000-0000-4000-8000-000000000001','Known account','other-owner@example.test','supervisor',gen_random_uuid())$$,'existing Auth user in another org can get pending Supervisor membership');
select results_eq($$select user_id,invitation_status from public.list_platform_organization_members_page('e1000000-0000-4000-8000-000000000001',1,10,'Known account')$$,
 $$values ('e1100000-0000-4000-8000-000000000006'::uuid,'pending'::text)$$,'known account is linked but not auto-accepted');
select throws_ok($$select public.create_platform_organization_member_invitation('e1000000-0000-4000-8000-000000000001','Duplicate',' OTHER-OWNER@EXAMPLE.TEST ','agent',gen_random_uuid())$$,
 '23505','an active membership or invitation already exists for this email','normalized duplicate rejected across roles');
select throws_ok($$select pg_temp.remove_member('e1200000-0000-4000-8000-000000000001')$$,'P0001','Cannot delete the last owner of an organization','pending owner cannot replace last accepted owner');
select throws_ok($$select pg_temp.edit_member('e1200000-0000-4000-8000-000000000001','supervisor')$$,'P0001','Cannot delete the last owner of an organization','last accepted owner cannot be demoted');
select throws_ok($$select public.update_platform_organization_member('e1200000-0000-4000-8000-000000000003','Stale','agent','{}','2000-01-01',gen_random_uuid())$$,'40001','TEAM_MEMBER_STALE','stale update rejected');
select lives_ok($$select public.create_platform_organization_member_invitation('e1000000-0000-4000-8000-000000000001','Pending agent','new-agent@example.test','agent','e1400000-0000-4000-8000-000000000101')$$,'create pending Agent');
select lives_ok($$select public.create_platform_organization_member_invitation('e1000000-0000-4000-8000-000000000001','Pending agent','new-agent@example.test','agent','e1400000-0000-4000-8000-000000000101')$$,'stable retry returns existing result');
select throws_ok($$select public.create_platform_organization_member_invitation('e1000000-0000-4000-8000-000000000001','Different payload','new-agent@example.test','agent','e1400000-0000-4000-8000-000000000101')$$,'22023','request id was already used for a different platform action','same ID cannot overwrite a different operation');
select throws_ok($$select pg_temp.edit_member('e1200000-0000-4000-8000-000000000005','agent','Pending','{e1300000-0000-4000-8000-000000000001}')$$,'22023','pending Agents cannot be assigned to routing queues','pending memberships cannot receive queues');
select throws_ok($$select pg_temp.edit_member('e1200000-0000-4000-8000-000000000003','agent','Ali','{e1300000-0000-4000-8000-000000000002}')$$,'22023','routing queues must be active and belong to the Agent organization','cross-organization queue rejected');
select lives_ok($$select pg_temp.edit_member('e1200000-0000-4000-8000-000000000003','agent','Ali','{e1300000-0000-4000-8000-000000000001}')$$,'accepted Agent can join a queue');
reset role;
update public.routing_queues set status='archived' where id='e1300000-0000-4000-8000-000000000001';
set local role authenticated;
select lives_ok($$select pg_temp.edit_member('e1200000-0000-4000-8000-000000000003','agent','Ali','{e1300000-0000-4000-8000-000000000001}')$$,'name-only edit preserves an existing archived queue');
reset role;
update public.routing_queues set status='active' where id='e1300000-0000-4000-8000-000000000001';
create temp table member_token as select updated_at from public.agents where id='e1200000-0000-4000-8000-000000000003';
grant select on member_token to authenticated;
delete from public.routing_queue_members where agent_id='e1200000-0000-4000-8000-000000000003';
set local role authenticated;
select throws_ok($$select public.update_platform_organization_member('e1200000-0000-4000-8000-000000000003','Old queue state','agent','{e1300000-0000-4000-8000-000000000001}',(select updated_at from member_token),gen_random_uuid())$$,'40001','TEAM_MEMBER_STALE','queue editor changes invalidate a team editor stale token');
select lives_ok($$select pg_temp.edit_member('e1200000-0000-4000-8000-000000000003','agent','Ali','{e1300000-0000-4000-8000-000000000001}')$$,'fresh token can restore a queue');
reset role;
insert into public.agent_assignment_presence(organization_id,agent_id,available,last_heartbeat_at)
 values('e1000000-0000-4000-8000-000000000001','e1200000-0000-4000-8000-000000000003',true,now());
set local role authenticated;
select lives_ok($$select pg_temp.edit_member('e1200000-0000-4000-8000-000000000003','supervisor')$$,'Agent can change to Supervisor');
reset role;
select is((select count(*) from public.routing_queue_members where agent_id='e1200000-0000-4000-8000-000000000003'),0::bigint,'leaving Agent clears queue membership');
select is((select available from public.agent_assignment_presence where agent_id='e1200000-0000-4000-8000-000000000003'),false,'role change resets availability Away');
select results_eq($$select before_state->>'role',after_state->>'role' from public.platform_admin_action_events where target_id='e1200000-0000-4000-8000-000000000003' and after_state->>'role'='supervisor'$$,
 $$values ('agent'::text,'supervisor'::text)$$,'audit stores before/after roles');
select is((select count(*) from auth.users where email in ('new-owner@example.test','new-agent@example.test')),0::bigint,'pending invitations never create Auth accounts');
set local role authenticated;
select lives_ok($$select pg_temp.edit_member('e1200000-0000-4000-8000-000000000003','agent','Ali','{e1300000-0000-4000-8000-000000000001}')$$,'restore Agent for active-work tests');
reset role;
insert into public.organizations_addresses(organization_id,service,address,extra,status)
values('e1000000-0000-4000-8000-000000000001','local','team-test','{}','connected');
insert into public.conversations(id,organization_id,service,organization_address,assigned_agent_id,routing_queue_id)
 values('e1500000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000001','local','team-test','e1200000-0000-4000-8000-000000000003','e1300000-0000-4000-8000-000000000001');
set local role authenticated;
select throws_ok($$select pg_temp.remove_member('e1200000-0000-4000-8000-000000000003')$$,'23514','TEAM_MEMBER_ACTIVE_WORK','active assignment blocks removal');
select throws_ok($$select pg_temp.edit_member('e1200000-0000-4000-8000-000000000003','supervisor')$$,'23514','TEAM_MEMBER_ACTIVE_WORK','active assignment blocks role change');
select throws_ok($$select pg_temp.edit_member('e1200000-0000-4000-8000-000000000003','agent')$$,'23514','TEAM_MEMBER_ACTIVE_WORK','cannot remove queue used by assignment');
select throws_ok($$select public.remove_platform_organization_agent('e1200000-0000-4000-8000-000000000003',gen_random_uuid())$$,'23514','TEAM_MEMBER_ACTIVE_WORK','legacy Agent RPC cannot bypass active-work guard');
select lives_ok($$select pg_temp.edit_member('e1200000-0000-4000-8000-000000000003','agent','Renamed','{e1300000-0000-4000-8000-000000000001}')$$,'name-only edit allowed with active assignment');
reset role;
update public.conversations set status='closed' where id='e1500000-0000-4000-8000-000000000001';
insert into public.messages(id,organization_id,conversation_id,direction,agent_id,service,organization_address,content,timestamp)
values('e1600000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000001','e1500000-0000-4000-8000-000000000001','outgoing','e1200000-0000-4000-8000-000000000003','whatsapp','team-test','{"version":"1","type":"text","kind":"text","text":"Preserved history"}',now()+interval '1 hour');
set local role authenticated;
select throws_ok($$select pg_temp.remove_member('e1200000-0000-4000-8000-000000000003')$$,'23514','TEAM_MEMBER_ACTIVE_WORK','unresolved send blocks removal even after conversation closes');
reset role;
update public.messages set status='{"sent":"2026-01-01T00:00:00Z"}' where id='e1600000-0000-4000-8000-000000000001';
set local role authenticated;
select ok(pg_temp.remove_member('e1200000-0000-4000-8000-000000000003'),'remove accepted organization access after work is complete');
reset role;
select is((select count(*) from public.messages where id='e1600000-0000-4000-8000-000000000001'),1::bigint,'removal preserves message history');
select is((select count(*) from public.conversations where id='e1500000-0000-4000-8000-000000000001'),1::bigint,'removal preserves closed conversation');
select is((select count(*) from auth.users where id='e1100000-0000-4000-8000-000000000004'),1::bigint,'removal preserves Auth account');
select results_eq($$select before_state->>'name',before_state->>'role' from public.platform_admin_action_events where action_type='organization_member.remove' and target_id='e1200000-0000-4000-8000-000000000003'$$,
 $$values ('Renamed'::text,'agent'::text)$$,'removed identity and role retained in audit');
select is((select extra->>'role' from public.agents where id='e1200000-0000-4000-8000-000000000007'),'owner','other organization membership unchanged');
insert into public.chatbot_node_bridges(organization_id,organization_address,node_company_id)
values('e1000000-0000-4000-8000-000000000001','team-test','1');
insert into public.chatbot_node_operations(request_id,organization_id,organization_address,action,conversation_id,payload)
values('e1700000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000001','team-test','takeover','e1500000-0000-4000-8000-000000000001','{"actor_agent_id":"e1200000-0000-4000-8000-000000000002"}');
set local role authenticated;
select throws_ok($$select pg_temp.remove_member('e1200000-0000-4000-8000-000000000002')$$,'23514','TEAM_MEMBER_ACTIVE_WORK','pending lifecycle operation blocks removal');
select throws_ok($$select pg_temp.edit_member('e1200000-0000-4000-8000-000000000002','owner')$$,'23514','TEAM_MEMBER_ACTIVE_WORK','pending lifecycle operation blocks role change');
select lives_ok($$select pg_temp.edit_member('e1200000-0000-4000-8000-000000000002','supervisor','Name during pending work')$$,'name-only edit allowed while lifecycle operation pending');
reset role;
update public.chatbot_node_operations set status='succeeded' where request_id='e1700000-0000-4000-8000-000000000001';
set local role authenticated;
select lives_ok($$select pg_temp.edit_member('e1200000-0000-4000-8000-000000000002','owner')$$,'accepted Supervisor can become second Owner');
select lives_ok($$select pg_temp.edit_member('e1200000-0000-4000-8000-000000000001','supervisor')$$,'demotion allowed after another accepted Owner exists');
select results_eq($$select role::text from public.list_platform_organization_members_page('e1000000-0000-4000-8000-000000000001',1,50) where id='e1200000-0000-4000-8000-000000000001'$$,
 $$values ('supervisor')$$,'owner demotion actually changes saved role');
select lives_ok($$select * from public.update_platform_organization_agent_capacity('e1000000-0000-4000-8000-000000000001',1,gen_random_uuid())$$,'configure capacity below usage');
select throws_ok($$select pg_temp.edit_member('e1200000-0000-4000-8000-000000000002','agent')$$,'23514','organization Agent capacity has been reached','Owner entering Agent reserves a seat and respects limit');
select throws_ok($$select public.create_platform_organization_member_invitation('e1000000-0000-4000-8000-000000000001','Over limit','capacity@example.test','supervisor',gen_random_uuid())$$,'23514','organization Agent capacity has been reached','pending Supervisor respects capacity limit');
select lives_ok($$select public.create_platform_organization_member_invitation('e1000000-0000-4000-8000-000000000001','Owner no seat','owner-no-seat@example.test','owner',gen_random_uuid())$$,'Owner does not consume Agent capacity');
select ok(pg_temp.remove_member((select id from public.list_platform_organization_members_page('e1000000-0000-4000-8000-000000000001',1,50,'Owner no seat'))),'pending Owner cancellation is allowed');
set local role authenticated;
select set_config('request.jwt.claim.sub','e1100000-0000-4000-8000-000000000002',true);
select throws_ok($$select * from public.list_platform_organization_members_page('e1000000-0000-4000-8000-000000000001')$$,'42501','platform administrator access required','tenant Owner cannot list through platform RPC');
select throws_ok($$select public.create_platform_organization_member_invitation('e1000000-0000-4000-8000-000000000002','Bad','bad@example.test','agent',gen_random_uuid())$$,'42501','platform administrator access required','tenant Owner cannot mutate another organization');
reset role;
select * from finish();
rollback;
