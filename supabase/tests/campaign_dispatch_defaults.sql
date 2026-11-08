begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public,auth;
select plan(10);

insert into public.organizations(id,name) values
('15100000-0000-4000-8000-000000000001','Default campaign controls A'),
('15100000-0000-4000-8000-000000000002','Default campaign controls B');
select is((select count(*) from public.campaign_dispatch_settings where organization_id in
('15100000-0000-4000-8000-000000000001','15100000-0000-4000-8000-000000000002') and enabled),2::bigint,'all new organizations receive available controls');
select is((select count(*) from public.campaign_sending_policies where organization_id in
('15100000-0000-4000-8000-000000000001','15100000-0000-4000-8000-000000000002')),0::bigint,'availability does not create enforcement or limits');

update public.campaign_dispatch_settings set enabled=false
where organization_id='15100000-0000-4000-8000-000000000001';
select ok(not (select enabled from public.campaign_dispatch_settings where organization_id='15100000-0000-4000-8000-000000000001'),'explicit deployment disable remains supported');
select ok((select enabled from public.campaign_dispatch_settings where organization_id='15100000-0000-4000-8000-000000000002'),'one organization does not affect another');

delete from public.campaign_dispatch_settings where organization_id='15100000-0000-4000-8000-000000000001';
insert into public.campaign_dispatch_settings(organization_id) values('15100000-0000-4000-8000-000000000001');
select ok((select enabled from public.campaign_dispatch_settings where organization_id='15100000-0000-4000-8000-000000000001'),'settings inserts default to available');
select ok(not has_function_privilege('anon','public.initialize_campaign_dispatch_settings()','execute'),'anonymous callers cannot execute initializer');
select ok(not has_function_privilege('authenticated','public.initialize_campaign_dispatch_settings()','execute'),'tenant callers cannot execute initializer');
select ok(not has_table_privilege('authenticated','public.campaign_dispatch_settings','insert'),'tenants cannot alter deployment settings directly');
select ok((select prosecdef from pg_proc where oid='public.initialize_campaign_dispatch_settings()'::regprocedure),'initializer uses scoped definer access');
select is((select confdeltype::text from pg_constraint where conrelid='public.campaign_dispatch_settings'::regclass and contype='f'),'c','existing authorized organization-purge cascade is preserved');
select * from finish();
rollback;
