
alter table "public"."platform_admin_action_events" drop constraint "platform_admin_action_events_action_check";

alter table "public"."platform_admin_action_events" drop constraint "platform_admin_action_events_target_check";

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_action_check" CHECK ((action_type = ANY (ARRAY['routing_queue.create'::text, 'routing_queue.update'::text, 'organization_agent_capacity.update'::text, 'organization_agent.invite'::text, 'organization_agent.update'::text, 'organization_agent.remove'::text, 'organization_member.invite'::text, 'organization_member.update'::text, 'organization_member.remove'::text, 'organization_automation.update'::text, 'organization_module_permissions.update'::text, 'organization_media_storage.quota_update'::text, 'organization_media_storage.reconcile'::text, 'whatsapp.health_check'::text, 'whatsapp.profile_refresh'::text, 'whatsapp.template_sync'::text]))) not valid;

alter table "public"."platform_admin_action_events" validate constraint "platform_admin_action_events_action_check";

alter table "public"."platform_admin_action_events" add constraint "platform_admin_action_events_target_check" CHECK ((((target_type = 'routing_queue'::text) AND (action_type ~~ 'routing_queue.%'::text)) OR ((target_type = 'organization_agent_capacity'::text) AND (action_type = 'organization_agent_capacity.update'::text)) OR ((target_type = 'organization_agent'::text) AND (action_type ~~ 'organization_agent.%'::text)) OR ((target_type = 'organization_member'::text) AND (action_type ~~ 'organization_member.%'::text)) OR ((target_type = 'organization_automation'::text) AND (action_type = 'organization_automation.update'::text)) OR ((target_type = 'organization_media_storage'::text) AND (action_type ~~ 'organization_media_storage.%'::text)) OR ((target_type = 'organization_module_permissions'::text) AND (action_type = 'organization_module_permissions.update'::text)) OR ((target_type = 'whatsapp_account'::text) AND (action_type ~~ 'whatsapp.%'::text)))) not valid;

alter table "public"."platform_admin_action_events" validate constraint "platform_admin_action_events_target_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.assert_member_has_no_active_work(p_organization_id uuid, p_member_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.cleanup_team_member_role()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.create_platform_organization_member_invitation(p_organization_id uuid, p_name text, p_email text, p_role public.role, p_request_id uuid)
 RETURNS public.agents
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  return jsonb_populate_record(null::public.agents,public.mutate_platform_organization_member('invite',p_organization_id,null,p_name,p_email,p_role,null,null,p_request_id,false));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.guard_team_member_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if old.ai then return case when tg_op='DELETE' then old else new end; end if;
  if tg_op='DELETE' or new.extra->>'role' is distinct from old.extra->>'role' then
    perform public.lock_organization_team(old.organization_id);
    -- Cascaded organization purge keeps its existing semantics.
    if exists(select 1 from public.organizations where id=old.organization_id) then
      perform public.assert_member_has_no_active_work(old.organization_id,old.id);
    end if;
  end if;
  return case when tg_op='DELETE' then old else new end;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.guard_team_work_reservation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.list_platform_organization_members_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, id uuid, user_id uuid, name text, email text, picture text, role public.role, invitation_status text, queue_ids uuid[], queue_names text[], created_at timestamp with time zone, updated_at timestamp with time zone, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.lock_organization_team(p_organization_id uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select pg_advisory_xact_lock(hashtextextended('organization-team:' || p_organization_id::text, 0));
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
      delete from public.routing_queue_members where organization_id=org_id and agent_id=member.id;
      insert into public.routing_queue_members(organization_id,routing_queue_id,agent_id) select org_id,q,member.id from unnest(queues)q;
    end if;
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

CREATE OR REPLACE FUNCTION public.remove_platform_organization_member(p_member_id uuid, p_expected_updated_at timestamp with time zone, p_request_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform public.mutate_platform_organization_member('remove',null,p_member_id,null,null,null,null,p_expected_updated_at,p_request_id,false);
  return true;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_platform_organization_member(p_member_id uuid, p_name text, p_role public.role, p_routing_queue_ids uuid[], p_expected_updated_at timestamp with time zone, p_request_id uuid)
 RETURNS public.agents
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  return jsonb_populate_record(null::public.agents,public.mutate_platform_organization_member('update',null,p_member_id,p_name,null,p_role,p_routing_queue_ids,p_expected_updated_at,p_request_id,false));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_platform_organization_agent_invitation(p_organization_id uuid, p_name text, p_email text, p_request_id uuid)
 RETURNS public.agents
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  return jsonb_populate_record(null::public.agents,public.mutate_platform_organization_member(
    'invite',p_organization_id,null,p_name,p_email,'agent',null,null,p_request_id,true));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_platform_organization_agent_audit_state(p_agent_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'id', agent.id,
    'organization_id', agent.organization_id,
    'name', agent.name,
    'role', agent.extra->>'role',
    'email', coalesce(
      nullif(agent.extra->'invitation'->>'email', ''),
      auth_user.email
    ),
    'invitation_status', coalesce(
      agent.extra->'invitation'->>'status',
      'accepted'
    ),
    'queue_ids', coalesce(
      (
        select jsonb_agg(member.routing_queue_id order by member.routing_queue_id)
        from public.routing_queue_members member
        where member.organization_id = agent.organization_id
          and member.agent_id = agent.id
      ),
      '[]'::jsonb
    )
  )
  from public.agents agent
  left join auth.users auth_user on auth_user.id = agent.user_id
  where agent.id = p_agent_id;
$function$
;

CREATE OR REPLACE FUNCTION public.prevent_last_owner_deletion()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  owner_count int;
begin
  -- Skip check if org is being deleted (cascade delete)
  perform public.lock_organization_team(old.organization_id);
  if not exists (select 1 from public.organizations where id=old.organization_id) then
    return old;
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

  return old;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.remove_platform_organization_agent(p_agent_id uuid, p_request_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform public.mutate_platform_organization_member(
    'remove',null,p_agent_id,null,null,null,null,null,p_request_id,true);
  return true;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_platform_organization_agent(p_agent_id uuid, p_name text, p_routing_queue_ids uuid[] DEFAULT ARRAY[]::uuid[], p_request_id uuid DEFAULT NULL::uuid)
 RETURNS public.agents
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  return jsonb_populate_record(null::public.agents,public.mutate_platform_organization_member(
    'update',null,p_agent_id,p_name,null,'agent',p_routing_queue_ids,null,p_request_id,true));
end;
$function$
;

CREATE TRIGGER aa_guard_team_member_change BEFORE DELETE OR UPDATE OF extra ON public.agents FOR EACH ROW EXECUTE FUNCTION public.guard_team_member_change();

CREATE TRIGGER cleanup_team_member_role AFTER UPDATE OF extra ON public.agents FOR EACH ROW EXECUTE FUNCTION public.cleanup_team_member_role();

CREATE TRIGGER aa_guard_team_lifecycle BEFORE INSERT OR UPDATE OF status ON public.chatbot_node_operations FOR EACH ROW WHEN ((new.status <> ALL (ARRAY['succeeded'::text, 'failed'::text]))) EXECUTE FUNCTION public.guard_team_work_reservation();

CREATE TRIGGER aa_guard_team_assignment BEFORE INSERT OR UPDATE OF assigned_agent_id, routing_queue_id ON public.conversations FOR EACH ROW EXECUTE FUNCTION public.guard_team_work_reservation();

CREATE TRIGGER aa_guard_team_human_send BEFORE INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.guard_team_work_reservation();

-- Function ACLs are synchronized from the schema source; migra omits them.
revoke all on function public.lock_organization_team(uuid), public.assert_member_has_no_active_work(uuid,uuid),
 public.guard_team_member_change(),public.cleanup_team_member_role(),public.guard_team_work_reservation(),
 public.mutate_platform_organization_member(text,uuid,uuid,text,text,public.role,uuid[],timestamptz,uuid,boolean) from public,anon,authenticated;
revoke all on function public.list_platform_organization_members_page(uuid,integer,integer,text),
 public.create_platform_organization_member_invitation(uuid,text,text,public.role,uuid),
 public.update_platform_organization_member(uuid,text,public.role,uuid[],timestamptz,uuid),
 public.remove_platform_organization_member(uuid,timestamptz,uuid) from public,anon;
grant execute on function public.list_platform_organization_members_page(uuid,integer,integer,text),
 public.create_platform_organization_member_invitation(uuid,text,text,public.role,uuid),
 public.update_platform_organization_member(uuid,text,public.role,uuid[],timestamptz,uuid),
 public.remove_platform_organization_member(uuid,timestamptz,uuid) to authenticated;
