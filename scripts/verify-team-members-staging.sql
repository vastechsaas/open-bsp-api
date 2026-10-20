-- Staging-only smoke test. Caller must verify linked ref acifbsuxmpdtlhbsvhlj.
-- Uses existing disposable Auth identities; creates no Auth accounts or emails.
-- Every fixture and audit event rolls back, including on failure.
begin;
do $verify$
declare
  org uuid:='e3000000-0000-4000-8000-000000000001';
  actor uuid; fixture_users uuid[]; known_email text; auth_digest text; auth_count bigint;
  owner_a public.agents; owner_b public.agents; agent public.agents;
  pending public.agents; linked public.agents; restricted public.agents;
  queue uuid:=gen_random_uuid(); request uuid:=gen_random_uuid(); stamp timestamptz;
begin
  select user_id into actor from public.platform_admins where active order by user_id limit 1;
  select array_agg(id order by id) into fixture_users from auth.users where id<>actor;
  if actor is null or cardinality(fixture_users)<3 then raise exception 'Need an active staging Super Admin and three existing test accounts'; end if;
  select email into known_email from auth.users where id=fixture_users[3];
  select count(*),md5(string_agg(id::text||coalesce(email,'')||coalesce(encrypted_password,''),',' order by id))
    into auth_count,auth_digest from auth.users;
  insert into public.organizations(id,name,extra) values(org,'Disposable Team Management smoke test','{}');
  insert into public.agents(organization_id,user_id,name,ai,extra)
    values(org,actor,'Owner A',false,'{"role":"owner"}') returning * into owner_a;
  insert into public.agents(organization_id,user_id,name,ai,extra)
    values(org,fixture_users[1],'Owner B',false,'{"role":"owner"}') returning * into owner_b;
  insert into public.agents(organization_id,user_id,name,ai,extra)
    values(org,fixture_users[2],'Agent fixture',false,'{"role":"agent"}') returning * into agent;
  insert into public.agents(organization_id,name,ai,extra)
    values(org,'Read-only Administrator',false,'{"role":"admin","invitation":{"email":"admin@team-fixture.invalid","status":"pending"}}') returning * into restricted;
  insert into public.routing_queues(id,organization_id,name) values(queue,org,'Disposable queue');
  perform set_config('request.jwt.claim.sub',actor::text,true);
  perform set_config('request.jwt.claim.role','authenticated',true);
  set local role authenticated;
  if (select count(*) from public.list_platform_organization_members_page(org,1,50))<>4 then raise exception 'Team listing failed'; end if;
  select * into pending from public.create_platform_organization_member_invitation(org,'Pending Supervisor','pending@team-fixture.invalid','supervisor',request);
  if pending.user_id is not null or pending.extra->'invitation'->>'status'<>'pending' then raise exception 'New email unexpectedly created/accepted Auth'; end if;
  if (select id from public.create_platform_organization_member_invitation(org,'Pending Supervisor','pending@team-fixture.invalid','supervisor',request))<>pending.id then raise exception 'Stable retry failed'; end if;
  select * into linked from public.create_platform_organization_member_invitation(org,'Known account',upper(known_email),'owner',gen_random_uuid());
  if linked.user_id<>fixture_users[3] or linked.extra->'invitation'->>'status'<>'pending' then raise exception 'Existing account linking/acceptance failed'; end if;
  begin
    perform public.create_platform_organization_member_invitation(org,'Duplicate',upper(known_email),'agent',gen_random_uuid());
    raise exception 'Duplicate was accepted';
  exception when unique_violation then null; end;
  begin
    perform public.update_platform_organization_member(restricted.id,'Forbidden','owner','{}',restricted.updated_at,gen_random_uuid());
    raise exception 'Read-only role was changed';
  exception when insufficient_privilege then null; end;
  select * into agent from public.update_platform_organization_member(agent.id,'Queued Agent','agent',array[queue],agent.updated_at,gen_random_uuid());
  if cardinality((select queue_ids from public.list_platform_organization_members_page(org,1,50) where id=agent.id))<>1 then raise exception 'Queue assignment failed'; end if;
  stamp:=agent.updated_at;
  select * into agent from public.update_platform_organization_member(agent.id,'Supervisor now','supervisor','{}',agent.updated_at,gen_random_uuid());
  if cardinality((select queue_ids from public.list_platform_organization_members_page(org,1,50) where id=agent.id))<>0 then raise exception 'Queue cleanup failed'; end if;
  begin
    perform public.update_platform_organization_member(agent.id,'Stale update','agent','{}',stamp,gen_random_uuid());
    raise exception 'Stale update was accepted';
  exception when serialization_failure then null; end;
  perform public.remove_platform_organization_member(owner_b.id,owner_b.updated_at,gen_random_uuid());
  begin
    perform public.remove_platform_organization_member(owner_a.id,owner_a.updated_at,gen_random_uuid());
    raise exception 'Last accepted Owner was removed';
  exception when raise_exception then
    if sqlerrm<>'Cannot delete the last owner of an organization' then raise; end if;
  end;
  perform public.remove_platform_organization_member(pending.id,pending.updated_at,gen_random_uuid());
  perform public.remove_platform_organization_member(agent.id,agent.updated_at,gen_random_uuid());
  reset role;
  if (select count(*) from auth.users)<>auth_count or
     (select md5(string_agg(id::text||coalesce(email,'')||coalesce(encrypted_password,''),',' order by id)) from auth.users)<>auth_digest
    then raise exception 'Auth identities or credentials changed'; end if;
  if exists(select 1 from pg_proc where oid in (
     'public.list_platform_organization_members_page(uuid,integer,integer,text)'::regprocedure,
     'public.create_platform_organization_member_invitation(uuid,text,text,public.role,uuid)'::regprocedure,
     'public.update_platform_organization_member(uuid,text,public.role,uuid[],timestamptz,uuid)'::regprocedure,
     'public.remove_platform_organization_member(uuid,timestamptz,uuid)'::regprocedure)
     and (has_function_privilege('anon',oid,'execute') or not has_function_privilege('authenticated',oid,'execute')))
    then raise exception 'Public RPC grants are incorrect'; end if;
  if has_function_privilege('authenticated','public.mutate_platform_organization_member(text,uuid,uuid,text,text,public.role,uuid[],timestamptz,uuid,boolean)','execute')
    then raise exception 'Private mutation is exposed'; end if;
end;
$verify$;
select 'PASS: staging memberships, role/queue cleanup, retries, stale/last-owner/duplicate protection, Auth preservation and RPC grants' as verification;
rollback;
