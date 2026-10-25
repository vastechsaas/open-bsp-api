begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select no_plan();

insert into public.organizations(id,name,extra) values
('12900000-0000-4000-8000-000000000001','Integration A','{}'),
('12900000-0000-4000-8000-000000000002','Integration B','{}');
insert into auth.users(id,email,raw_user_meta_data)
select ('12910000-0000-4000-8000-' || lpad(i::text,12,'0'))::uuid, 'integration-' || i || '@example.test', '{}' from generate_series(1,7) i;
insert into public.agents(id,organization_id,user_id,name,ai,extra)
select ('12920000-0000-4000-8000-' || lpad(i::text,12,'0'))::uuid,'12900000-0000-4000-8000-000000000001',
('12910000-0000-4000-8000-' || lpad(i::text,12,'0'))::uuid,'Role '||i,false,
jsonb_build_object('role',(array['owner','admin','supervisor','member','agent','owner'])[i]) ||
case when i=6 then '{"invitation":{"status":"pending"}}'::jsonb else '{}'::jsonb end from generate_series(1,6) i;
insert into public.platform_admins(user_id) values ('12910000-0000-4000-8000-000000000007');
insert into public.api_keys(organization_id,name,key,role) values ('12900000-0000-4000-8000-000000000001','Availability test','availability-owner-key','owner');
insert into public.organizations_addresses(organization_id,service,address,status,extra) values
('12900000-0000-4000-8000-000000000001','instagram','129-instagram','connected','{"access_token":"never-return-this"}'),
('12900000-0000-4000-8000-000000000001','whatsapp','129-whatsapp','disconnected','{}');
insert into public.onboarding_tokens(id,name,organization_id,expires_at,service) values
('12930000-0000-4000-8000-000000000001','Saved link','12900000-0000-4000-8000-000000000001',now()+interval '1 day','instagram');

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"12910000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select ok(public.is_integration_available('12900000-0000-4000-8000-000000000001','whatsapp'),'WhatsApp enabled by default');
select ok(public.is_integration_available('12900000-0000-4000-8000-000000000001','instagram'),'Instagram enabled by default');
select ok(not public.is_integration_available('12900000-0000-4000-8000-000000000002','whatsapp'),'Boolean helper cannot disclose other tenant');
select throws_ok($$select public.get_effective_integration_availability('12900000-0000-4000-8000-000000000002')$$,'42501',null,'Effective query requires tenant access');
select throws_ok($$select public.get_platform_integration_availability('12900000-0000-4000-8000-000000000001')$$,'42501',null,'Owner cannot read Super Admin settings');
select throws_ok($$select public.update_platform_integration_availability('12900000-0000-4000-8000-000000000001','[]',0,gen_random_uuid())$$,'42501',null,'Owner cannot change availability');
select ok(not has_table_privilege('authenticated','public.organization_integration_availability','update'),'REST writes cannot bypass Super Admin');
select ok(not has_table_privilege('anon','public.integration_catalogue','insert'),'API keys cannot add providers');
select ok(not has_function_privilege('anon','public.update_platform_integration_availability(uuid,jsonb,bigint,uuid)','execute'),'Anonymous/API-key RPC cannot save');
select set_config('request.jwt.claims','{"sub":"12910000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select throws_ok($$select public.update_platform_integration_availability('12900000-0000-4000-8000-000000000001','[]',0,gen_random_uuid())$$,'42501',null,'Admin cannot change availability');
select set_config('request.jwt.claims','{"sub":"12910000-0000-4000-8000-000000000005","role":"authenticated"}',true);
select is(jsonb_array_length(public.get_effective_integration_availability('12900000-0000-4000-8000-000000000001')->'integrations'),2,'Accepted agents can load safe effective availability');
select set_config('request.jwt.claims','{"sub":"12910000-0000-4000-8000-000000000006","role":"authenticated"}',true);
select throws_ok($$select public.get_effective_integration_availability('12900000-0000-4000-8000-000000000001')$$,'42501',null,'Pending membership rejected');

select set_config('request.jwt.claims','{"sub":"12910000-0000-4000-8000-000000000007","role":"authenticated"}',true);
select is(public.get_platform_integration_availability('12900000-0000-4000-8000-000000000001')->>'revision','0','Defaults have revision zero');
select is(public.get_platform_integration_availability('12900000-0000-4000-8000-000000000001')->'integrations'->0->>'connected_count','1','Connected counts are separate from enabled state');
select ok(public.get_platform_integration_availability('12900000-0000-4000-8000-000000000001')::text not like '%never-return-this%','Credentials never returned');
select throws_ok($$select public.update_platform_integration_availability('12900000-0000-4000-8000-000000000001','[{"id":"unknown","enabled":true},{"id":"whatsapp","enabled":true}]',0,gen_random_uuid())$$,'22023',null,'Unknown provider rejected');
select throws_ok($$select public.update_platform_integration_availability('12900000-0000-4000-8000-000000000001','[{"id":"instagram","enabled":"false"},{"id":"whatsapp","enabled":true}]',0,gen_random_uuid())$$,'22023',null,'Flags must be booleans');
select throws_ok($$select public.update_platform_integration_availability('12900000-0000-4000-8000-000000000001','[{"id":"instagram","enabled":true},{"id":"instagram","enabled":false}]',0,gen_random_uuid())$$,'22023',null,'Duplicate provider rejected');
select is(public.update_platform_integration_availability('12900000-0000-4000-8000-000000000001','[{"id":"instagram","enabled":false},{"id":"whatsapp","enabled":true}]',0,'12940000-0000-4000-8000-000000000001')->>'revision','1','Atomic save increments revision');
select is(public.update_platform_integration_availability('12900000-0000-4000-8000-000000000001','[{"id":"instagram","enabled":false},{"id":"whatsapp","enabled":true}]',0,'12940000-0000-4000-8000-000000000001')->>'revision','1','Retry reuses original result');
select throws_ok($$select public.update_platform_integration_availability('12900000-0000-4000-8000-000000000002','[{"id":"instagram","enabled":false},{"id":"whatsapp","enabled":true}]',0,'12940000-0000-4000-8000-000000000001')$$,'22023',null,'Request ID cannot target another tenant');
select throws_ok($$select public.update_platform_integration_availability('12900000-0000-4000-8000-000000000001','[{"id":"instagram","enabled":true},{"id":"whatsapp","enabled":true}]',0,gen_random_uuid())$$,'40001',null,'Concurrent stale save rejected');

select set_config('request.jwt.claims','{"sub":"12910000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select ok(not public.is_integration_available('12900000-0000-4000-8000-000000000001','instagram'),'Disabled integration unavailable to owner');
select ok(public.is_integration_available('12900000-0000-4000-8000-000000000001','whatsapp'),'Independent provider remains enabled');
select is((select count(*) from public.organizations_addresses where organization_id='12900000-0000-4000-8000-000000000001' and service in ('whatsapp','instagram')),2::bigint,'Availability does not hide account/history data');
select throws_ok($$insert into public.onboarding_tokens(name,organization_id,expires_at,service) values ('Blocked','12900000-0000-4000-8000-000000000001',now()+interval '1 day','instagram')$$,'42501',null,'Direct REST onboarding creation blocked');
select is((select status from public.onboarding_tokens where id='12930000-0000-4000-8000-000000000001'),'active','Saved links not consumed or expired');
select lives_ok($$delete from public.onboarding_tokens where id='12930000-0000-4000-8000-000000000001'$$,'Revocation remains allowed');

reset role;
select is((select count(*) from public.platform_admin_action_events where organization_id='12900000-0000-4000-8000-000000000001' and action_type='organization_integrations.update'),1::bigint,'Idempotent saves create one audit event');
select ok((select before_state->>'revision'='0' and after_state->'result'->>'revision'='1' from public.platform_admin_action_events where request_id='12940000-0000-4000-8000-000000000001'),'Audit preserves before and after settings');
insert into public.integration_catalogue(id,name) values ('future_connector','Future connector');
select set_config('request.jwt.claims','{"role":"service_role"}',true);
select ok(not public.is_integration_available('12900000-0000-4000-8000-000000000002','future_connector'),'Future catalogue providers disabled by default');
select ok(public.is_integration_available('12900000-0000-4000-8000-000000000002','instagram'),'Other organizations retain defaults');
select is((select status from public.organizations_addresses where address='129-instagram'),'connected','Disable never disconnects existing accounts');

select set_config('request.jwt.claims','{}',true);
select set_config('request.headers','{"api-key":"availability-owner-key"}',true);
set local role anon;
select ok(not public.is_integration_available('12900000-0000-4000-8000-000000000001','instagram'),'Organization API key respects disabled setting');
select throws_ok($$insert into public.onboarding_tokens(name,organization_id,expires_at,service) values ('Blocked key','12900000-0000-4000-8000-000000000001',now()+interval '1 day','instagram')$$,'42501',null,'API key cannot bypass link guard');
reset role;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"12910000-0000-4000-8000-000000000007","role":"authenticated"}',true);
select is(public.update_platform_integration_availability('12900000-0000-4000-8000-000000000001','[{"id":"instagram","enabled":true},{"id":"whatsapp","enabled":true},{"id":"future_connector","enabled":false}]',1,'12940000-0000-4000-8000-000000000002')->>'revision','2','Re-enable supported after adding a future provider');
select set_config('request.jwt.claims','{"sub":"12910000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select lives_ok($$insert into public.onboarding_tokens(name,organization_id,expires_at,service) values ('Enabled again','12900000-0000-4000-8000-000000000001',now()+interval '1 day','instagram')$$,'Re-enabling restores setup without touching accounts');
reset role;
select * from finish();
rollback;
