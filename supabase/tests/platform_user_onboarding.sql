begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public,auth;
select no_plan();
insert into public.organizations(id,name) values('e2000000-0000-4000-8000-000000000001','Onboarding Test'),('e2000000-0000-4000-8000-000000000002','Other');
insert into auth.users(id,email,raw_app_meta_data,raw_user_meta_data,email_confirmed_at,encrypted_password) values
 ('e2100000-0000-4000-8000-000000000001','platform-onboard@example.test','{}','{}',now(),'test-hash'),
 ('e2100000-0000-4000-8000-000000000002','existing@example.test','{}','{}',now(),'original-password-hash');
insert into public.platform_admins(user_id) values('e2100000-0000-4000-8000-000000000001');
create function pg_temp.cmd(command text,payload jsonb) returns jsonb language sql as $$
  select public.platform_onboarding_command('e2100000-0000-4000-8000-000000000001',command,payload);
$$;
create function pg_temp.start(email text,role text default 'agent',mode text default 'direct',req uuid default gen_random_uuid()) returns jsonb language sql as $$
  select pg_temp.cmd('begin',jsonb_build_object('organization_id','e2000000-0000-4000-8000-000000000001','request_id',req,'name','Onboarding user','email',email,'role',role,'mode',mode));
$$;
create temp table ops(op jsonb);
insert into ops select pg_temp.start('new@example.test','agent','direct','e2400000-0000-4000-8000-000000000001');
select is((select count(*) from public.agents where extra->'invitation'->>'email'='new@example.test'),1::bigint,'reserve selected membership before Auth');
select is((select count(*) from auth.users where email='new@example.test'),0::bigint,'reservation does not create Auth');
select is(pg_temp.start('NEW@example.test','agent','direct','e2400000-0000-4000-8000-000000000001')->>'id',(select op->>'id' from ops),'stable normalized retry');
select throws_ok($$select pg_temp.start('existing@example.test')$$,'23505','ONBOARDING_EMAIL_IN_USE','unrelated existing user rejected');
select throws_ok($$select pg_temp.start('new@example.test')$$,'23505','ONBOARDING_EMAIL_RESERVED','email serialized across requests');
select throws_ok($$select pg_temp.start('restricted@example.test','admin')$$,'22023','ONBOARDING_INVALID_REQUEST','restricted role rejected server-side');
select throws_ok($$select public.platform_onboarding_command('e2100000-0000-4000-8000-000000000002','begin','{}')$$,'42501','ONBOARDING_FORBIDDEN','non-platform user rejected');
select ok(not has_function_privilege('authenticated','public.platform_onboarding_command(uuid,text,jsonb)','execute'),'private service RPC unavailable to clients');
select ok(not has_table_privilege('authenticated','public.platform_user_onboarding','select'),'context hashes and leases not exposed');
select ok(not has_table_privilege('service_role','public.platform_user_onboarding_events','update'),'audit append-only for service role');
insert into auth.users(id,email,raw_app_meta_data,raw_user_meta_data,email_confirmed_at,encrypted_password)
 select (op->>'intended_user_id')::uuid,'new@example.test',jsonb_build_object('onboarding_operation_id',op->>'id'),'{}',now(),'created-password-hash' from ops;
select throws_ok($$update public.agents set extra=jsonb_build_object('invitation',jsonb_build_object('status','accepted')) where extra->'invitation'->>'email'='new@example.test'$$,
 '23514','ONBOARDING_SETUP_REQUIRED','partial-JSON direct acceptance cannot bypass setup');
select lives_ok($$select pg_temp.cmd('claim',op||jsonb_build_object('operation_id',op->>'id','lease_id','e2500000-0000-4000-8000-000000000001')) from ops$$,'claim external work lease');
select throws_ok($$select pg_temp.cmd('claim',op||jsonb_build_object('operation_id',op->>'id','lease_id',gen_random_uuid())) from ops$$,'55P03','ONBOARDING_BUSY','concurrent work excluded');
select lives_ok($$select pg_temp.cmd('finish',op||jsonb_build_object('operation_id',op->>'id','lease_id','e2500000-0000-4000-8000-000000000001')) from ops$$,'direct operation finalizes selected membership');
select is((select extra->'invitation'->>'status' from public.agents where extra->'invitation'->>'email'='new@example.test'),'accepted','direct member accepted');
select is((select encrypted_password from auth.users where email='existing@example.test'),'original-password-hash','existing credentials unchanged');
truncate ops;
insert into ops select pg_temp.start('invite@example.test','supervisor','invitation');
insert into public.agents(organization_id,name,ai,extra) values('e2000000-0000-4000-8000-000000000002','Other pending',false,'{"role":"agent","invitation":{"email":"invite@example.test","status":"pending"}}');
insert into auth.users(id,email,raw_app_meta_data,raw_user_meta_data,email_confirmed_at,encrypted_password)
 select (op->>'intended_user_id')::uuid,'invite@example.test',jsonb_build_object('onboarding_operation_id',op->>'id'),'{}',null,'' from ops;
select lives_ok($$select pg_temp.cmd('claim',op||jsonb_build_object('operation_id',op->>'id','lease_id','e2500000-0000-4000-8000-000000000002')) from ops$$,'invitation claim');
select lives_ok($$select pg_temp.cmd('context',op||jsonb_build_object('operation_id',op->>'id','lease_id','e2500000-0000-4000-8000-000000000002','context_hash',repeat('a',64))) from ops$$,'only context hash stored');
select lives_ok($$select pg_temp.cmd('sent',op||jsonb_build_object('operation_id',op->>'id','lease_id','e2500000-0000-4000-8000-000000000002')) from ops$$,'SMTP acceptance recorded independently');
select is((select extra->'invitation'->>'status' from public.agents where id=(select (op->>'member_id')::uuid from ops)),'pending','email sent is not accepted membership');
select throws_ok($$select pg_temp.cmd('preview',op||jsonb_build_object('operation_id',op->>'id','context_hash',repeat('b',64))) from ops$$,'23514','ONBOARDING_LINK_INVALID','wrong context rejected');
select throws_ok($$select public.platform_onboarding_command((op->>'intended_user_id')::uuid,'complete_claim',op||jsonb_build_object('operation_id',op->>'id','context_hash',repeat('a',64),'lease_id','e2500000-0000-4000-8000-000000000003')) from ops$$,'42501','ONBOARDING_FORBIDDEN','unverified Auth recipient cannot complete');
update auth.users set email_confirmed_at=now() where email='invite@example.test';
select lives_ok($$select public.platform_onboarding_command((op->>'intended_user_id')::uuid,'complete_claim',op||jsonb_build_object('operation_id',op->>'id','context_hash',repeat('a',64),'lease_id','e2500000-0000-4000-8000-000000000003')) from ops$$,'confirmed recipient claims bounded password lease');
select throws_ok($$delete from public.agents where id=(select (op->>'member_id')::uuid from ops)$$,'55P03','ONBOARDING_BUSY','cancellation cannot race password write');
update auth.users set encrypted_password='new-password-hash',raw_app_meta_data=raw_app_meta_data||'{"onboarding_password_set":true}' where email='invite@example.test';
select lives_ok($$select public.platform_onboarding_command((op->>'intended_user_id')::uuid,'complete_finish',op||jsonb_build_object('operation_id',op->>'id','context_hash',repeat('a',64),'lease_id','e2500000-0000-4000-8000-000000000003')) from ops$$,'recipient finalizes');
select is((select extra->'invitation'->>'status' from public.agents where organization_id='e2000000-0000-4000-8000-000000000002'),'pending','other organization remains pending');
select throws_ok($$select pg_temp.cmd('preview',op||jsonb_build_object('operation_id',op->>'id','context_hash',repeat('a',64))) from ops$$,'23514','ONBOARDING_LINK_INVALID','completed public link cannot reopen setup');
truncate ops;
insert into ops select pg_temp.start('cancel@example.test','owner','invitation');
update public.agents set extra=jsonb_build_object('role','supervisor') where id=(select (op->>'member_id')::uuid from ops);
select is((select status from public.platform_user_onboarding where id=(select (op->>'id')::uuid from ops)),'revoked','role change invalidates context');
select is((select count(*) from public.platform_user_onboarding_events where event='revoked'),1::bigint,'revocation audit retains original member role');
select lives_ok($$select pg_temp.start('owner-setup@example.test','owner')$$,'Owner creation supported');
select lives_ok($$select pg_temp.start('supervisor-setup@example.test','supervisor')$$,'Supervisor creation supported');
select throws_ok($$select pg_temp.start('changed@example.test','agent','direct','e2400000-0000-4000-8000-000000000001')$$,'22023','ONBOARDING_REQUEST_REUSED','request ID cannot change its target');
insert into public.agents(id,organization_id,name,ai,extra) values('e2200000-0000-4000-8000-000000000005','e2000000-0000-4000-8000-000000000001','Existing pending',false,'{"role":"agent","invitation":{"email":"pending-only@example.test","status":"pending"}}');
select lives_ok($$select pg_temp.cmd('begin',jsonb_build_object('organization_id','e2000000-0000-4000-8000-000000000001','member_id','e2200000-0000-4000-8000-000000000005','expected_updated_at',(select updated_at from public.agents where id='e2200000-0000-4000-8000-000000000005'),'request_id',gen_random_uuid(),'name','Existing pending','email','pending-only@example.test','role','agent','mode','direct'))$$,'existing pending membership reused');
select is((select count(*) from public.agents where extra->'invitation'->>'email'='pending-only@example.test'),1::bigint,'no second membership');
insert into public.organization_agent_capacity(organization_id,max_agent_seats) values('e2000000-0000-4000-8000-000000000001',1) on conflict(organization_id) do update set max_agent_seats=1;
select throws_ok($$select pg_temp.start('capacity@example.test')$$,'23514',null,'capacity checked before Auth');
select is((select count(*) from public.platform_user_onboarding where email='capacity@example.test'),0::bigint,'capacity failure leaves no operation');
select ok(not exists(select 1 from information_schema.columns where table_schema='public' and table_name in ('platform_user_onboarding','platform_user_onboarding_events') and column_name ~ '(password|token$|request_body)'), 'no password, password fingerprint or raw token columns');
select * from finish();
rollback;
