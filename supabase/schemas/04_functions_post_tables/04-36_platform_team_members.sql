-- One short transaction lock fences membership changes against new assignments,
-- human sends and lifecycle reservations. No network work is done under it.
create function public.lock_organization_team(p_organization_id uuid) returns void
language sql volatile security definer set search_path = '' as $$
  select pg_advisory_xact_lock(hashtextextended('organization-team:' || p_organization_id::text, 0));
$$;

create function public.assert_member_has_no_active_work(p_organization_id uuid, p_member_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if exists(select 1 from public.conversations where organization_id=p_organization_id
      and assigned_agent_id=p_member_id and status='active')
    or exists(select 1 from public.chatbot_node_operations where organization_id=p_organization_id
      and payload->>'actor_agent_id'=p_member_id::text and status not in ('succeeded','failed'))
    or exists(select 1 from public.messages where organization_id=p_organization_id
      and agent_id=p_member_id and direction='outgoing' and status ? 'pending'
      and not status ?| array['sent','delivered','read','failed']) then
    raise exception 'TEAM_MEMBER_ACTIVE_WORK' using errcode='23514';
  end if;
end;
$$;

create function public.guard_team_member_change() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.ai then return case when tg_op='DELETE' then old else new end; end if;
  -- Do not disclose workload information to a caller whose proposed role
  -- change will fail the existing tenant RLS WITH CHECK policy.
  if tg_op='UPDATE' and new.extra->>'role' is distinct from old.extra->>'role'
    and current_setting('role',true) in ('authenticated','anon')
    and not public.is_platform_admin()
    and coalesce(public.get_request_organization_role(old.organization_id)::text,'')<>'owner' then
    return new;
  end if;
  if tg_op='DELETE' or new.extra->>'role' is distinct from old.extra->>'role' then
    perform public.lock_organization_team(old.organization_id);
    -- Cascaded organization purge keeps its existing semantics.
    if exists(select 1 from public.organizations where id=old.organization_id) then
      perform public.assert_member_has_no_active_work(old.organization_id,old.id);
    end if;
  end if;
  return case when tg_op='DELETE' then old else new end;
end;
$$;
create trigger aa_guard_team_member_change before delete or update of extra on public.agents
for each row execute function public.guard_team_member_change();

create function public.cleanup_team_member_role() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not new.ai and new.extra->>'role' is distinct from old.extra->>'role' then
    if new.extra->>'role'<>'agent' then
      delete from public.routing_queue_members where organization_id=new.organization_id and agent_id=new.id;
    end if;
    update public.agent_assignment_presence set available=false,last_heartbeat_at=null,updated_at=clock_timestamp()
      where organization_id=new.organization_id and agent_id=new.id;
  end if;
  return new;
end;
$$;
create trigger cleanup_team_member_role after update of extra on public.agents
for each row execute function public.cleanup_team_member_role();

-- The legacy moddatetime trigger uses the transaction start time. A member
-- revision must advance even for two edits within the same transaction.
create function public.set_team_member_revision() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at:=greatest(clock_timestamp(),old.updated_at+interval '1 microsecond');
  return new;
end;
$$;
create trigger zz_set_team_member_revision before update on public.agents
for each row when (not new.ai) execute function public.set_team_member_revision();

-- Queue edits from either administration screen share the same lock and stale
-- token. Revalidate eligibility after locking, not just in the queue editor.
create function public.guard_team_queue_change() returns trigger
language plpgsql security definer set search_path = '' as $$
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
$$;
create trigger aa_guard_team_queue_change before insert or delete on public.routing_queue_members
for each row execute function public.guard_team_queue_change();

create function public.touch_team_queue_revision() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.agents set updated_at=clock_timestamp()
  where organization_id=case when tg_op='DELETE' then old.organization_id else new.organization_id end
    and id=case when tg_op='DELETE' then old.agent_id else new.agent_id end;
  return null;
end;
$$;
create trigger touch_team_queue_revision after insert or delete on public.routing_queue_members
for each row execute function public.touch_team_queue_revision();

create function public.guard_team_work_reservation() returns trigger
language plpgsql security definer set search_path = '' as $$
declare actor public.agents; actor_id uuid;
begin
  if tg_table_name='conversations' then
    if new.assigned_agent_id is null then return new; end if;
    actor_id:=new.assigned_agent_id;
  elsif tg_table_name='messages' then
    if new.direction<>'outgoing' or new.agent_id is null or not new.status ? 'pending' then return new; end if;
    actor_id:=new.agent_id;
  else
    if new.action not in ('takeover','resolve-and-close','resume') or new.payload->>'actor_agent_id' is null then return new; end if;
    actor_id:=(new.payload->>'actor_agent_id')::uuid;
  end if;
  select * into actor from public.agents where id=actor_id;
  if tg_table_name='conversations' and actor.id is not null
    and actor.organization_id<>new.organization_id then
    raise exception 'Conversation assignee must be a human agent in the same organization' using errcode='23514';
  end if;
  if actor.ai then return new; end if;
  perform public.lock_organization_team(new.organization_id);
  select * into actor from public.agents where id=actor_id and organization_id=new.organization_id;
  if not found or actor.ai or actor.user_id is null
    or coalesce(actor.extra->'invitation'->>'status','accepted')<>'accepted' then
    raise exception 'TEAM_MEMBER_UNAVAILABLE' using errcode='23514';
  end if;
  if tg_table_name='chatbot_node_operations' then
    if new.action='resume' and actor.extra->>'role' not in ('owner','admin','supervisor') then
      raise exception 'TEAM_MEMBER_UNAVAILABLE' using errcode='42501';
    end if;
  end if;
  return new;
end;
$$;
create trigger aa_guard_team_assignment before insert or update of assigned_agent_id,routing_queue_id on public.conversations
for each row execute function public.guard_team_work_reservation();
create trigger aa_guard_team_human_send before insert on public.messages
for each row execute function public.guard_team_work_reservation();
create trigger aa_guard_team_lifecycle before insert or update of status on public.chatbot_node_operations
for each row when (new.status not in ('succeeded','failed')) execute function public.guard_team_work_reservation();

create function public.list_platform_organization_members_page(
  p_organization_id uuid,p_page integer default 1,p_page_size integer default 10,p_search text default null
) returns table(organization_id uuid,id uuid,user_id uuid,name text,email text,picture text,
  role public.role,invitation_status text,queue_ids uuid[],queue_names text[],
  created_at timestamptz,updated_at timestamptz,total_count bigint)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_platform_admin();
  if not exists(select 1 from public.organizations where organizations.id=p_organization_id) then
    raise exception 'organization not found' using errcode='P0002';
  end if;
  return query
  with members as (
    select a.*,coalesce(nullif(a.extra->'invitation'->>'email',''),u.email) resolved_email,
      coalesce(a.extra->'invitation'->>'status','accepted') membership_status
    from public.agents a left join auth.users u on u.id=a.user_id
    where a.organization_id=p_organization_id and not a.ai
      and a.extra->>'role' in ('owner','admin','supervisor','member','agent')
      and coalesce(a.extra->'invitation'->>'status','accepted') in ('pending','accepted')
  ), filtered as (
    select * from members m where nullif(btrim(p_search),'') is null
      or m.name ilike '%'||btrim(p_search)||'%' or m.resolved_email ilike '%'||btrim(p_search)||'%'
  )
  select m.organization_id,m.id,m.user_id,m.name,m.resolved_email,m.picture,(m.extra->>'role')::public.role,
    m.membership_status,coalesce(q.ids,array[]::uuid[]),coalesce(q.names,array[]::text[]),
    m.created_at,m.updated_at,count(*) over()
  from filtered m left join lateral (
    select array_agg(r.id order by lower(r.name),r.id) ids,array_agg(r.name order by lower(r.name),r.id) names
    from public.routing_queue_members qm join public.routing_queues r on r.id=qm.routing_queue_id
      and r.organization_id=qm.organization_id
    where qm.organization_id=m.organization_id and qm.agent_id=m.id
  )q on true order by lower(m.name),m.id
  limit least(greatest(coalesce(p_page_size,10),1),50)
  offset (greatest(coalesce(p_page,1),1)-1)*least(greatest(coalesce(p_page_size,10),1),50);
end;
$$;

-- Private mutation implementation also used by legacy Agent-only RPCs.
create function public.mutate_platform_organization_member(
  p_action text,p_organization_id uuid,p_member_id uuid,p_name text,p_email text,p_role public.role,
  p_queue_ids uuid[],p_expected_updated_at timestamptz,p_request_id uuid,p_legacy boolean
) returns jsonb language plpgsql volatile security definer set search_path = '' as $$
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
    select coalesce(array_agg(routing_queue_id),array[]::uuid[]) into previous_queues from public.routing_queue_members where organization_id=org_id and agent_id=member.id;
    if cardinality(queues)>0 and coalesce(member.extra->'invitation'->>'status','accepted')='pending' then
      raise exception 'pending Agents cannot be assigned to routing queues' using errcode='22023';
    end if;
    if cardinality(queues)>0 and p_role<>'agent' then
      raise exception 'TEAM_MEMBER_QUEUES_REQUIRE_AGENT' using errcode='22023';
    end if;
    if exists(select 1 from unnest(queues)q left join public.routing_queues r on r.id=q and r.organization_id=org_id
      where r.id is null or (r.status<>'active' and not q=any(previous_queues))) then
      raise exception 'routing queues must be active and belong to the Agent organization' using errcode='22023';
    end if;
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
$$;

create function public.create_platform_organization_member_invitation(p_organization_id uuid,p_name text,p_email text,p_role public.role,p_request_id uuid)
returns public.agents language plpgsql security definer set search_path = '' as $$
begin
  return jsonb_populate_record(null::public.agents,public.mutate_platform_organization_member('invite',p_organization_id,null,p_name,p_email,p_role,null,null,p_request_id,false));
end;
$$;
create function public.update_platform_organization_member(p_member_id uuid,p_name text,p_role public.role,p_routing_queue_ids uuid[],p_expected_updated_at timestamptz,p_request_id uuid)
returns public.agents language plpgsql security definer set search_path = '' as $$
begin
  return jsonb_populate_record(null::public.agents,public.mutate_platform_organization_member('update',null,p_member_id,p_name,null,p_role,p_routing_queue_ids,p_expected_updated_at,p_request_id,false));
end;
$$;
create function public.remove_platform_organization_member(p_member_id uuid,p_expected_updated_at timestamptz,p_request_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  perform public.mutate_platform_organization_member('remove',null,p_member_id,null,null,null,null,p_expected_updated_at,p_request_id,false);
  return true;
end;
$$;

revoke all on function public.lock_organization_team(uuid), public.assert_member_has_no_active_work(uuid,uuid),
 public.guard_team_member_change(),public.cleanup_team_member_role(),public.guard_team_work_reservation(),
 public.guard_team_queue_change(),public.touch_team_queue_revision(),public.set_team_member_revision(),
 public.mutate_platform_organization_member(text,uuid,uuid,text,text,public.role,uuid[],timestamptz,uuid,boolean) from public,anon,authenticated;
revoke all on function public.list_platform_organization_members_page(uuid,integer,integer,text),
 public.create_platform_organization_member_invitation(uuid,text,text,public.role,uuid),
 public.update_platform_organization_member(uuid,text,public.role,uuid[],timestamptz,uuid),
 public.remove_platform_organization_member(uuid,timestamptz,uuid) from public,anon;
grant execute on function public.list_platform_organization_members_page(uuid,integer,integer,text),
 public.create_platform_organization_member_invitation(uuid,text,text,public.role,uuid),
 public.update_platform_organization_member(uuid,text,public.role,uuid[],timestamptz,uuid),
 public.remove_platform_organization_member(uuid,timestamptz,uuid) to authenticated;
