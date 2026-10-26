create function public.get_platform_organization_setup(p_provisioning_id uuid)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare parent public.organization_provisioning; people jsonb; ready boolean; failed boolean; next_status text;
begin
  perform public.require_platform_admin();
  select * into parent from public.organization_provisioning where id=p_provisioning_id for update;
  if not found then raise exception 'ONBOARDING_NOT_FOUND' using errcode='P0002'; end if;
  if parent.setup_version=1 then return jsonb_build_object('version',1,'provisioning',to_jsonb(parent)); end if;
  select jsonb_agg(jsonb_build_object('member_id',p.member_id,'client_key',p.client_key,'mode',p.mode,'name',p.name,'email',p.email,'role',p.role,
    'request_id',p.request_id,'expected_updated_at',p.expected_updated_at,'operation_id',o.id,
    'status',case
      when a.id is null or a.extra->>'role' is distinct from p.role::text or
        (a.user_id is null and (a.updated_at<>p.expected_updated_at or lower(a.extra->'invitation'->>'email') is distinct from p.email)) then 'failed'
      when p.mode='pending' then 'pending_membership'
      when o.status='completed' then 'completed'
      when o.status='revoked' then 'failed'
      when o.lease_until>clock_timestamp() then 'processing'
      when coalesce(o.failure_code,p.failure_code) is not null then 'failed'
      when o.delivery_accepted_at is not null then 'invitation_sent'
      else 'queued' end,
    'failure_code',case when a.id is null or a.extra->>'role' is distinct from p.role::text or
      (a.user_id is null and (a.updated_at<>p.expected_updated_at or lower(a.extra->'invitation'->>'email') is distinct from p.email)) then 'TEAM_MEMBER_STALE'
      when o.status='revoked' then 'ONBOARDING_REVOKED'
      when o.status='completed' or o.delivery_accepted_at is not null then null else coalesce(o.failure_code,p.failure_code) end,
    'invitation_sent_at',o.delivery_accepted_at) order by p.ordinal)
  into people from public.organization_provisioning_people p
  left join public.agents a on a.id=p.member_id and a.organization_id=parent.organization_id
  left join lateral (select op.* from public.platform_user_onboarding op where op.member_id=p.member_id
    and op.organization_id=parent.organization_id and op.request_id=p.request_id order by op.created_at desc limit 1) o on true
  where p.provisioning_id=parent.id;
  ready:=not exists(select 1 from jsonb_array_elements(people) person where person->>'status' not in ('pending_membership','invitation_sent','completed'));
  failed:=exists(select 1 from jsonb_array_elements(people) person where person->>'status'='failed');
  next_status:=case when ready then 'completed' when failed then 'failed' else 'pending_invitation' end;
  if parent.status<>next_status then
    update public.organization_provisioning set status=next_status,
      last_error=case when failed then 'ACCOUNT_SETUP_REQUIRES_ATTENTION' else null end,
      completed_at=case when ready then clock_timestamp() else null end where id=parent.id returning * into parent;
  end if;
  return jsonb_build_object('version',2,'provisioning_id',parent.id,'organization_id',parent.organization_id,
    'organization_name',parent.organization_name,'status',case when ready then 'completed' when failed then 'partial' else 'processing' end,
    'people',people,'has_remaining_work',not ready);
end;
$$;

create function public.begin_platform_organization_setup(p_request_id uuid,p_payload jsonb)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare actor uuid; parent public.organization_provisioning; canonical jsonb; member jsonb; members jsonb:='[]'; modes jsonb:='[]'; existing_modes jsonb;
  owner jsonb; i integer:=0; agent public.agents; person jsonb;
begin
  actor:=public.require_platform_admin();
  if p_request_id is null or jsonb_typeof(p_payload) is distinct from 'object' or
    exists(select 1 from jsonb_object_keys(p_payload) k where k not in ('organization_name','owner','members','max_agent_seats','storage_quota_gb','auto_assign')) then
    raise exception 'ONBOARDING_INVALID_REQUEST' using errcode='22023'; end if;
  owner:=p_payload->'owner';
  if jsonb_typeof(owner) is distinct from 'object' or
    exists(select 1 from jsonb_object_keys(owner) k where k not in ('name','email','mode')) or
    coalesce(owner->>'mode','invitation') not in ('pending','invitation','direct') or
    jsonb_typeof(p_payload->'members') is distinct from 'array' or jsonb_array_length(p_payload->'members')>50 then
    raise exception 'ONBOARDING_INVALID_REQUEST' using errcode='22023'; end if;
  modes:=jsonb_build_array(jsonb_build_object('client_key','owner','mode',coalesce(owner->>'mode','invitation')));
  for member in select value from jsonb_array_elements(p_payload->'members') loop
    if jsonb_typeof(member) is distinct from 'object' or exists(select 1 from jsonb_object_keys(member) k where k not in ('client_key','name','email','role','mode')) or
      coalesce(member->>'role','') not in ('owner','supervisor','agent') or coalesce(member->>'mode','invitation') not in ('pending','invitation','direct') or
      member->>'client_key' is null or char_length(member->>'client_key') not between 1 and 64 or member->>'client_key'='owner' then
      raise exception 'ONBOARDING_INVALID_REQUEST' using errcode='22023'; end if;
    members:=members||jsonb_build_array(jsonb_build_object('name',btrim(member->>'name'),'email',lower(btrim(member->>'email')),'role',member->>'role'));
    modes:=modes||jsonb_build_array(jsonb_build_object('client_key',member->>'client_key','mode',coalesce(member->>'mode','invitation')));
  end loop;
  if (select count(distinct m->>'client_key') from jsonb_array_elements(modes) m)<>jsonb_array_length(modes) then
    raise exception 'ONBOARDING_INVALID_REQUEST' using errcode='22023'; end if;
  canonical:=jsonb_build_object('organization_name',btrim(p_payload->>'organization_name'),
    'owner',jsonb_build_object('name',btrim(owner->>'name'),'email',lower(btrim(owner->>'email'))), 'members',members,
    'max_agent_seats',p_payload->'max_agent_seats','storage_quota_gb',coalesce((p_payload->>'storage_quota_gb')::integer,25),
    'auto_assign',coalesce((p_payload->>'auto_assign')::boolean,false));
  perform pg_advisory_xact_lock(hashtextextended(actor::text||':'||p_request_id::text,0));
  select * into parent from public.organization_provisioning where platform_admin_user_id=actor and request_id=p_request_id for update;
  if found then
    select jsonb_agg(jsonb_build_object('client_key',p.client_key,'mode',p.mode) order by p.ordinal) into existing_modes
      from public.organization_provisioning_people p where provisioning_id=parent.id;
    if parent.setup_version<>2 or parent.request_payload is distinct from canonical or existing_modes is distinct from modes then
      raise exception 'ONBOARDING_REQUEST_REUSED' using errcode='22023'; end if;
    return public.get_platform_organization_setup(parent.id);
  end if;
  parent:=public.provision_platform_organization(p_request_id,canonical->>'organization_name',canonical->'owner'->>'name',canonical->'owner'->>'email',members,
    (canonical->>'max_agent_seats')::integer,(canonical->>'storage_quota_gb')::integer,(canonical->>'auto_assign')::boolean);
  for person in select value from jsonb_array_elements(modes) loop
    i:=i+1;
    select * into agent from public.agents where id=parent.invitation_agent_ids[i] and organization_id=parent.organization_id;
    insert into public.organization_provisioning_people(provisioning_id,member_id,client_key,ordinal,mode,name,email,role,expected_updated_at)
      values(parent.id,agent.id,person->>'client_key',i-1,person->>'mode',agent.name,lower(agent.extra->'invitation'->>'email'),
        (agent.extra->>'role')::public.role,agent.updated_at);
  end loop;
  update public.organization_provisioning set setup_version=2 where id=parent.id;
  return public.get_platform_organization_setup(parent.id);
end;
$$;

create function public.record_platform_provisioning_person_result(p_provisioning_id uuid,p_member_id uuid,p_failure_code text default null)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
begin
  perform public.require_platform_admin();
  if p_failure_code is not null and p_failure_code not in ('ONBOARDING_EMAIL_IN_USE','ONBOARDING_EMAIL_RESERVED','ONBOARDING_CAPACITY_REACHED',
    'ONBOARDING_BUSY','ONBOARDING_REVOKED','TEAM_MEMBER_STALE','AUTH_UNAVAILABLE','AUTH_REJECTED','PASSWORD_REENTRY_REQUIRED','WEAK_PASSWORD',
    'SMTP_FAILED','DELIVERY_UNKNOWN','FINALIZATION_FAILED','ONBOARDING_NOT_CONFIGURED','ONBOARDING_INVALID_REQUEST') then
    raise exception 'ONBOARDING_INVALID_REQUEST' using errcode='22023'; end if;
  update public.organization_provisioning_people set failure_code=p_failure_code
    where provisioning_id=p_provisioning_id and member_id=p_member_id;
  if not found then raise exception 'ONBOARDING_NOT_FOUND' using errcode='P0002'; end if;
  insert into public.organization_provisioning_events(provisioning_id,platform_admin_user_id,organization_id,event_type,details)
    select p.id,auth.uid(),p.organization_id,case when p_failure_code is null then 'retried' else 'failed' end,
      jsonb_build_object('member_id',p_member_id,'code',p_failure_code)
      from public.organization_provisioning p where p.id=p_provisioning_id;
  return public.get_platform_organization_setup(p_provisioning_id);
end;
$$;

revoke all on function public.get_platform_organization_setup(uuid), public.begin_platform_organization_setup(uuid,jsonb), public.record_platform_provisioning_person_result(uuid,uuid,text) from public,anon;
grant execute on function public.get_platform_organization_setup(uuid), public.begin_platform_organization_setup(uuid,jsonb), public.record_platform_provisioning_person_result(uuid,uuid,text) to authenticated;
