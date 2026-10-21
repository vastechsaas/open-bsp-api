-- Rollback-only staging smoke: no Auth calls, passwords or emails.
begin;
do $$
declare actor uuid; org uuid:=gen_random_uuid(); request uuid:=gen_random_uuid(); op jsonb; member public.agents;
begin
  select user_id into actor from public.platform_admins where active order by created_at limit 1;
  if actor is null then raise exception 'Staging platform administrator is required'; end if;
  if has_function_privilege('anon','public.platform_onboarding_command(uuid,text,jsonb)','execute')
    or has_function_privilege('authenticated','public.platform_onboarding_command(uuid,text,jsonb)','execute') then
    raise exception 'Private onboarding RPC is exposed';
  end if;
  if has_table_privilege('authenticated','public.platform_user_onboarding','select') then
    raise exception 'Private ledger is exposed';
  end if;
  perform set_config('app.organization_provisioning','on',true);
  insert into public.organizations(id,name) values(org,'Phase 2 rollback-only staging smoke');
  perform set_config('request.jwt.claim.sub',actor::text,true);
  op:=public.platform_onboarding_command(actor,'begin',jsonb_build_object('organization_id',org,'request_id',request,
    'name','Disposable pending agent','email','phase2-'||org::text||'@example.test','role','agent','mode','invitation'));
  if op->>'status'<>'reserved' then raise exception 'Reservation failed'; end if;
  select * into member from public.agents where id=(op->>'member_id')::uuid;
  if member.user_id is not null or member.extra->'invitation'->>'status'<>'pending' then
    raise exception 'Reservation changed Auth or accepted membership';
  end if;
  if (public.platform_onboarding_command(actor,'begin',jsonb_build_object('organization_id',org,'request_id',request,
    'name','Disposable pending agent','email','phase2-'||org::text||'@example.test','role','agent','mode','invitation'))->>'id')<>op->>'id' then
    raise exception 'Stable retry produced another operation';
  end if;
  perform public.update_platform_organization_member(member.id,member.name,'supervisor','{}',member.updated_at,gen_random_uuid());
  if (select status from public.platform_user_onboarding where id=(op->>'id')::uuid)<>'revoked' then
    raise exception 'Role change did not invalidate setup';
  end if;
  if exists(select 1 from auth.users where id=(op->>'intended_user_id')::uuid) then
    raise exception 'Unexpected Auth account creation';
  end if;
end;
$$;
rollback;
select 'PASS: staging private access, pending reservation, stable retry and revocation; all data rolled back; no email or Auth account created' as result;
