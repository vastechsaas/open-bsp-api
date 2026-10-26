begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public,auth;
select no_plan();
insert into auth.users(id,email,raw_user_meta_data) values
('13010000-0000-4000-8000-000000000001','setup-admin@example.test','{}'),
('13010000-0000-4000-8000-000000000002','setup-outsider@example.test','{}');
insert into public.platform_admins(user_id) values ('13010000-0000-4000-8000-000000000001');
create temp table setup_fixture(payload jsonb,result jsonb);
insert into setup_fixture(payload) values ('{"organization_name":"SCRUM130 mixed","owner":{"name":"Owner","email":"setup-owner@example.test","mode":"direct"},"members":[{"client_key":"first","name":"First","email":"setup-first@example.test","role":"agent","mode":"invitation"},{"client_key":"second","name":"Second","email":"setup-second@example.test","role":"supervisor","mode":"pending"}],"max_agent_seats":2,"storage_quota_gb":25,"auto_assign":false}');
grant all on setup_fixture to authenticated;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"13010000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select throws_ok($$select public.begin_platform_organization_setup('13020000-0000-4000-8000-000000000001',(select payload from setup_fixture))$$,'42501',null,'Non-Super-Admin cannot create v2 organizations');
select set_config('request.jwt.claims','{"sub":"13010000-0000-4000-8000-000000000001","role":"authenticated"}',true);
update setup_fixture set result=public.begin_platform_organization_setup('13020000-0000-4000-8000-000000000001',payload);
select is((select result->>'version' from setup_fixture),'2','New organization uses shared setup version');
select is((select jsonb_array_length(result->'people') from setup_fixture),3,'Owner and members get independent durable targets');
select is((select result->'people'->0->>'mode' from setup_fixture),'direct','Owner uses own setup mode');
select is((select result->'people'->1->>'mode' from setup_fixture),'invitation','First member uses invitation');
select is((select result->'people'->2->>'status' from setup_fixture),'pending_membership','Pending-only requires no account setup');
select is((select result->>'status' from setup_fixture),'processing','Organization created does not mean every account ready');
select is(public.begin_platform_organization_setup('13020000-0000-4000-8000-000000000001',(select payload from setup_fixture))->>'organization_id',
  (select result->>'organization_id' from setup_fixture),'Duplicate create reuses organization');
select throws_ok($$select public.begin_platform_organization_setup('13020000-0000-4000-8000-000000000001',jsonb_set((select payload from setup_fixture),'{owner,mode}','"pending"'))$$,'22023','ONBOARDING_REQUEST_REUSED','Setup choices cannot change after reservation');
select throws_ok($$select public.begin_platform_organization_setup('13020000-0000-4000-8000-000000000002',jsonb_set((select payload from setup_fixture),'{owner,password}','"do-not-store"'))$$,'22023',null,'SQL rejects passwords in saved payload');
select throws_ok($$select public.provision_platform_organization('13020000-0000-4000-8000-000000000001','SCRUM130 mixed','Owner','setup-owner@example.test','[{"name":"First","email":"setup-first@example.test","role":"agent"},{"name":"Second","email":"setup-second@example.test","role":"supervisor"}]',2,25,false)$$,'22023','ONBOARDING_VERSION_REQUIRED','Legacy retry cannot accidentally invite v2 pending-only people');
select ok(not has_table_privilege('authenticated','public.organization_provisioning_people','update'),'REST cannot rewrite reserved references');
select is(public.record_platform_provisioning_person_result((select (result->>'provisioning_id')::uuid from setup_fixture),
  (select (result->'people'->0->>'member_id')::uuid from setup_fixture),'WEAK_PASSWORD')->>'status','partial','Failure retains organization and reports partial setup');
select is(public.get_platform_organization_setup((select (result->>'provisioning_id')::uuid from setup_fixture))->'people'->1->>'status','queued','One failure does not cancel other people');
select throws_ok($$select public.record_platform_provisioning_person_result((select (result->>'provisioning_id')::uuid from setup_fixture),
  (select (result->'people'->0->>'member_id')::uuid from setup_fixture),'raw password or auth error')$$,'22023',null,'Raw error text cannot enter history');
select set_config('request.jwt.claims','{"sub":"13010000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select throws_ok($$select public.get_platform_organization_setup((select (result->>'provisioning_id')::uuid from setup_fixture))$$,'42501',null,'Setup status remains Super Admin only');
reset role;
select is((select count(*) from auth.users where email in ('setup-owner@example.test','setup-first@example.test','setup-second@example.test')),0::bigint,'Reserving memberships creates no Auth users');
select is((select count(*) from public.organizations where name='SCRUM130 mixed'),1::bigint,'Retries create exactly one organization');
select is((select count(*) from public.platform_user_onboarding where organization_id=(select (result->>'organization_id')::uuid from setup_fixture)),0::bigint,'Creation defers all external account work');
-- Reuse the established operation for an already-reserved membership.
select set_config('request.jwt.claims','{"sub":"13010000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select lives_ok($$select public.platform_onboarding_command('13010000-0000-4000-8000-000000000001','begin',
  (select (result->'people'->1)||jsonb_build_object('organization_id',result->>'organization_id') from setup_fixture))$$,'Shared setup executor binds existing membership');
select is((select count(*) from public.agents where organization_id=(select (result->>'organization_id')::uuid from setup_fixture)),3::bigint,'Attaching setup does not duplicate memberships');
update public.agents set name='Changed after reservation' where id=(select (result->'people'->2->>'member_id')::uuid from setup_fixture);
set local role authenticated;
select is(public.get_platform_organization_setup((select (result->>'provisioning_id')::uuid from setup_fixture))->'people'->2->>'failure_code','TEAM_MEMBER_STALE','Concurrent membership edits block stale setup');
reset role;
select ok((select request_payload::text not like '%password%' from public.organization_provisioning where id=(select (result->>'provisioning_id')::uuid from setup_fixture)),'Saved organization payload has no credentials');
select * from finish();
rollback;
