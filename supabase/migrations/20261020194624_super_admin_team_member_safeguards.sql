CREATE OR REPLACE FUNCTION public.guard_team_queue_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare org_id uuid; member_id uuid;
begin
  org_id:=case when tg_op='DELETE' then old.organization_id else new.organization_id end;
  member_id:=case when tg_op='DELETE' then old.agent_id else new.agent_id end;
  perform public.lock_organization_team(org_id);
  if tg_op='DELETE' then
    if exists(select 1 from public.conversations where organization_id=org_id
      and assigned_agent_id=member_id and status='active' and routing_queue_id=old.routing_queue_id) then
      raise exception 'TEAM_MEMBER_ACTIVE_WORK' using errcode='23514';
    end if;
  else
    perform public.validate_routing_queue_agent_ids(org_id,array[member_id]);
  end if;
  return case when tg_op='DELETE' then old else new end;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.touch_team_queue_revision()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  update public.agents set updated_at=clock_timestamp()
  where organization_id=case when tg_op='DELETE' then old.organization_id else new.organization_id end
    and id=case when tg_op='DELETE' then old.agent_id else new.agent_id end;
  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.mutate_platform_organization_member(p_action text, p_organization_id uuid, p_member_id uuid, p_name text, p_email text, p_role public.role, p_queue_ids uuid[], p_expected_updated_at timestamp with time zone, p_request_id uuid, p_legacy boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid:=public.require_platform_admin();
  member public.agents; previous_state jsonb; after_state jsonb; event public.platform_admin_action_events;
  org_id uuid:=p_organization_id; org_name text; normalized_name text:=btrim(coalesce(p_name,''));
  normalized_email text:=lower(btrim(coalesce(p_email,''))); queues uuid[]; previous_queues uuid[];
  action_type text:=(case when p_legacy then 'organization_agent.' else 'organization_member.' end)||p_action;
  request_body jsonb;
begin
  if p_request_id is null or p_action not in ('invite','update','remove') then
    raise exception 'request id and valid action are required' using errcode='22023';
  end if;
  select coalesce(array_agg(distinct q order by q),array[]::uuid[]) into queues from unnest(coalesce(p_queue_ids,array[]::uuid[]))q;
  request_body:=jsonb_build_object('action',p_action,'organization_id',p_organization_id,'member_id',p_member_id,
    'name',normalized_name,'email',normalized_email,'role',p_role,'queues',queues,
    'expected_updated_at',case when p_legacy then null else p_expected_updated_at end);
  perform pg_advisory_xact_lock(hashtextextended(actor::text||':'||p_request_id::text,0));
  select * into event from public.platform_admin_action_events where platform_admin_user_id=actor and request_id=p_request_id;
  if found then
    if event.action_type<>action_type or (p_member_id is not null and event.target_id<>p_member_id::text)
      or (p_organization_id is not null and event.organization_id<>p_organization_id)
      or (event.after_state ? '_request' and event.after_state->'_request'<>request_body) then
      raise exception 'request id was already used for a different platform action' using errcode='22023';
    end if;
    if p_action='remove' then return jsonb_build_object('removed',true); end if;
    select * into member from public.agents where agents.id=event.target_id::uuid;
    return to_jsonb(member);
  end if;
  if p_action<>'invite' then
    select organization_id into org_id from public.agents where id=p_member_id;
    if not found then raise exception 'Agent not found' using errcode='P0002'; end if;
  end if;
  perform public.lock_organization_team(org_id);
  select name into org_name from public.organizations where id=org_id;
  if not found then raise exception 'organization not found' using errcode='P0002'; end if;
  if p_action<>'invite' then
    select * into member from public.agents where id=p_member_id for update;
    if not found then raise exception 'Agent not found' using errcode='P0002'; end if;
    if p_legacy and (member.ai or member.extra->>'role'<>'agent'
      or coalesce(member.extra->'invitation'->>'status','accepted') not in ('pending','accepted')) then
      raise exception 'target must be a pending or accepted human Agent' using errcode='22023';
    end if;
    if member.ai or member.extra->>'role' not in ('owner','supervisor','agent')
      or coalesce(member.extra->'invitation'->>'status','accepted') not in ('pending','accepted') then
      raise exception 'TEAM_MEMBER_READ_ONLY' using errcode='42501';
    end if;
    if not p_legacy and (p_expected_updated_at is null or member.updated_at<>p_expected_updated_at) then
      raise exception 'TEAM_MEMBER_STALE' using errcode='40001';
    end if;
    previous_state:=public.get_platform_organization_agent_audit_state(member.id);
  end if;
  if p_action<>'remove' then
    if p_role is null or p_role not in ('owner','supervisor','agent') then
      raise exception 'TEAM_MEMBER_READ_ONLY' using errcode='42501';
    end if;
    if char_length(normalized_name) not between 1 and 120 then
      raise exception 'Agent name must contain between 1 and 120 characters' using errcode='22023';
    end if;
  end if;
  if p_action='invite' then
    if char_length(normalized_email)>320 or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
      raise exception 'valid email is required' using errcode='22023';
    end if;
    if exists(select 1 from public.agents a left join auth.users u on u.id=a.user_id
      where a.organization_id=org_id and not a.ai
      and lower(coalesce(nullif(a.extra->'invitation'->>'email',''),u.email,''))=normalized_email) then
      raise exception 'an active membership or invitation already exists for this email' using errcode='23505';
    end if;
    insert into public.agents(organization_id,name,ai,extra) values(org_id,normalized_name,false,
      jsonb_build_object('role',p_role,'invitation',jsonb_build_object('organization_name',org_name,'email',normalized_email,'status','pending')))
      returning * into member;
  elsif p_action='update' then
    if cardinality(queues)>0 and coalesce(member.extra->'invitation'->>'status','accepted')='pending' then
      raise exception 'pending Agents cannot be assigned to routing queues' using errcode='22023';
    end if;
    if cardinality(queues)>0 and p_role<>'agent' then
      raise exception 'TEAM_MEMBER_QUEUES_REQUIRE_AGENT' using errcode='22023';
    end if;
    if exists(select 1 from unnest(queues)q left join public.routing_queues r on r.id=q and r.organization_id=org_id and r.status='active' where r.id is null) then
      raise exception 'routing queues must be active and belong to the Agent organization' using errcode='22023';
    end if;
    select coalesce(array_agg(routing_queue_id),array[]::uuid[]) into previous_queues from public.routing_queue_members where organization_id=org_id and agent_id=member.id;
    if exists(select 1 from public.conversations where organization_id=org_id and assigned_agent_id=member.id and status='active'
      and routing_queue_id=any(previous_queues) and not routing_queue_id=any(queues)) then
      raise exception 'TEAM_MEMBER_ACTIVE_WORK' using errcode='23514';
    end if;
    update public.agents set name=normalized_name,extra=jsonb_build_object('role',p_role) where id=member.id returning * into member;
    if coalesce(member.extra->'invitation'->>'status','accepted')='accepted' then
      delete from public.routing_queue_members where organization_id=org_id and agent_id=member.id
        and not routing_queue_id=any(queues);
      insert into public.routing_queue_members(organization_id,routing_queue_id,agent_id)
        select org_id,q,member.id from unnest(queues)q on conflict do nothing;
    end if;
    select * into member from public.agents where id=member.id;
  else
    delete from public.agents where id=member.id;
  end if;
  after_state:=case when p_action='remove' then jsonb_build_object('removed',true,'member',previous_state)
    else public.get_platform_organization_agent_audit_state(member.id) end;
  insert into public.platform_admin_action_events(platform_admin_user_id,organization_id,action_type,target_type,target_id,request_id,before_state,after_state)
    values(actor,org_id,action_type,case when p_legacy then 'organization_agent' else 'organization_member' end,
      member.id::text,p_request_id,previous_state,after_state||jsonb_build_object('_request',request_body));
  perform realtime.send(jsonb_build_object('module','team_members'),'module-permissions','module-permissions:'||org_id::text,true);
  return case when p_action='remove' then jsonb_build_object('removed',true) else to_jsonb(member) end;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.prevent_last_owner_deletion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  owner_count int;
begin
  -- Skip check if org is being deleted (cascade delete)
  perform public.lock_organization_team(old.organization_id);
  if not exists (select 1 from public.organizations where id=old.organization_id) then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if old.extra->>'role' = 'owner'
    and coalesce(old.extra->'invitation'->>'status','accepted')='accepted' then
    select count(*) into owner_count
    from public.agents
    where organization_id = old.organization_id
      and extra->>'role' = 'owner'
      and (
        extra->>'invitation' is null
        or extra->'invitation'->>'status' = 'accepted'
      )
      and id <> old.id;

    if owner_count = 0 then
      raise exception 'Cannot delete the last owner of an organization';
    end if;
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$function$
;

CREATE TRIGGER aa_guard_team_queue_change BEFORE INSERT OR DELETE ON public.routing_queue_members FOR EACH ROW EXECUTE FUNCTION public.guard_team_queue_change();

CREATE TRIGGER touch_team_queue_revision AFTER INSERT OR DELETE ON public.routing_queue_members FOR EACH ROW EXECUTE FUNCTION public.touch_team_queue_revision();



revoke all on function public.guard_team_queue_change(), public.touch_team_queue_revision() from public, anon, authenticated;
