begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public,auth;
select no_plan();
insert into public.organizations(id,name) values
('17100000-0000-4000-8000-000000000001','Media cache A'),
('17100000-0000-4000-8000-000000000002','Media cache B');
insert into public.organizations_addresses(organization_id,address,service,status) values
('17100000-0000-4000-8000-000000000001','cache-number-1','whatsapp','connected'),
('17100000-0000-4000-8000-000000000001','cache-number-2','whatsapp','connected'),
('17100000-0000-4000-8000-000000000002','cache-number-1','whatsapp','connected');
create temp table cache_fixture(org uuid,sender text,uri text);
insert into cache_fixture values
('17100000-0000-4000-8000-000000000001','cache-number-1',
'internal://media/organizations/17100000-0000-4000-8000-000000000001/attachments/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
create temp table cache_claims(label text,result jsonb);
insert into cache_claims select 'first',public.claim_campaign_media_cache(org,sender,uri) from cache_fixture;
select is((select result->>'state' from cache_claims where label='first'),'claimed','First upload acquires durable lease');
select is((select public.claim_campaign_media_cache(org,sender,uri)->>'state' from cache_fixture),'busy','Concurrent worker cannot upload same image');
select ok(not public.complete_campaign_media_cache(org,sender,uri,gen_random_uuid(),'123')) from cache_fixture;
select ok(not public.release_campaign_media_cache(org,sender,uri,gen_random_uuid())) from cache_fixture;
select ok(public.complete_campaign_media_cache(org,sender,uri,(select (result->>'lease_token')::uuid from cache_claims where label='first'),'123'),'Current uploader commits ID') from cache_fixture;
select is((select public.claim_campaign_media_cache(org,sender,uri)->>'media_id' from cache_fixture),'123','Subsequent jobs reuse persisted ID');
select is((select public.claim_campaign_media_cache(org,sender,uri,'old-unknown')->>'media_id' from cache_fixture),'123','Stale invalidation cannot remove newer cached ID');
insert into cache_claims select 'replacement',public.claim_campaign_media_cache(org,sender,uri,'123') from cache_fixture;
select is((select result->>'state' from cache_claims where label='replacement'),'claimed','Definitively expired ID can be replaced');
select ok(not public.complete_campaign_media_cache(org,sender,uri,(select (result->>'lease_token')::uuid from cache_claims where label='first'),'456'),'Stale uploader cannot overwrite replacement') from cache_fixture;
select ok(not public.release_campaign_media_cache(org,sender,uri,(select (result->>'lease_token')::uuid from cache_claims where label='first')),'Stale release cannot clear replacement lease') from cache_fixture;
select ok(public.complete_campaign_media_cache(org,sender,uri,(select (result->>'lease_token')::uuid from cache_claims where label='replacement'),'456'),'Replacement commits') from cache_fixture;
select is((select public.claim_campaign_media_cache(org,sender,uri)->>'media_id' from cache_fixture),'456','Replacement survives subsequent requests');
select is((select public.claim_campaign_media_cache(org,'cache-number-2',uri)->>'state' from cache_fixture),'claimed','Sending numbers never share Meta IDs');
select throws_ok($$select public.claim_campaign_media_cache('17100000-0000-4000-8000-000000000002','cache-number-1',(select uri from cache_fixture))$$,'23514',null,'Cross-tenant storage URI rejected');
select is(public.claim_campaign_media_cache('17100000-0000-4000-8000-000000000002','cache-number-1',
'internal://media/organizations/17100000-0000-4000-8000-000000000002/attachments/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')->>'state','claimed','Different tenant has independent cache for same bytes');
select is((select count(*) from public.campaign_media_cache),3::bigint,'Cache identities remain isolated');
insert into cache_claims select 'crashed',public.claim_campaign_media_cache(org,sender,uri,'456') from cache_fixture;
update public.campaign_media_cache set lease_expires_at=clock_timestamp()-interval '1 second'
where organization_id=(select org from cache_fixture) and organization_address='cache-number-1';
insert into cache_claims select 'recovered',public.claim_campaign_media_cache(org,sender,uri) from cache_fixture;
select is((select result->>'state' from cache_claims where label='recovered'),'claimed','Expired upload lease recovers after worker restart');
select ok(not public.complete_campaign_media_cache(org,sender,uri,(select (result->>'lease_token')::uuid from cache_claims where label='crashed'),'789'),'Expired lease cannot commit') from cache_fixture;
select ok(public.release_campaign_media_cache(org,sender,uri,(select (result->>'lease_token')::uuid from cache_claims where label='recovered')),'Failed preparation releases its lease') from cache_fixture;
select is((select public.claim_campaign_media_cache(org,sender,uri)->>'state' from cache_fixture),'claimed','A later retry can prepare missing media');
select throws_ok($$select public.complete_campaign_media_cache(org,sender,uri,gen_random_uuid(),'https://secret-token') from cache_fixture$$,'22023',null,'Only numeric Meta IDs can be cached');
update public.organizations_addresses set status='disconnected' where organization_id=(select org from cache_fixture) and address='cache-number-1';
select throws_ok($$select public.claim_campaign_media_cache(org,sender,uri) from cache_fixture$$,'42501',null,'Disconnected sending account cannot reuse/upload media');
select ok(not has_table_privilege('authenticated','public.campaign_media_cache','SELECT'),'Cache is private to backend');
select ok(not has_table_privilege('anon','public.campaign_media_cache','INSERT'),'Public requests cannot poison cache');
select ok(not has_function_privilege('authenticated','public.claim_campaign_media_cache(uuid,text,text,text)','EXECUTE'),'Tenant API clients cannot claim cache');
select ok(not has_function_privilege('authenticated','public.complete_campaign_media_cache(uuid,text,text,uuid,text)','EXECUTE'),'Tenant API clients cannot inject media IDs');
select ok(not has_function_privilege('anon','public.release_campaign_media_cache(uuid,text,text,uuid)','EXECUTE'),'Anonymous clients cannot release leases');
select ok(has_function_privilege('service_role','public.claim_campaign_media_cache(uuid,text,text,text)','EXECUTE'),'Backend can coordinate reuse');
select * from finish();
rollback;
