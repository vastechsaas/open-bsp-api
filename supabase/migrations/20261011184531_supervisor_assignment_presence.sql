set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.get_my_assignment_availability(p_organization_id uuid)
 RETURNS TABLE(available boolean, last_heartbeat_at timestamp with time zone, eligible boolean, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_agent_id uuid;
begin
  if coalesce(public.get_request_organization_role(p_organization_id)::text, '') not in ('agent', 'supervisor') then
    raise exception using errcode = '42501', message = 'accepted Agent or Supervisor role required';
  end if;
  v_agent_id := public.get_current_human_agent_id(p_organization_id);
  return query
  select coalesce(p.available, false), p.last_heartbeat_at,
    coalesce(p.available and p.last_heartbeat_at >= clock_timestamp() - interval '2 minutes', false),
    p.updated_at
  from (select 1) seed
  left join public.agent_assignment_presence p
    on p.organization_id = p_organization_id and p.agent_id = v_agent_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.heartbeat_my_assignment_availability(p_organization_id uuid)
 RETURNS TABLE(available boolean, last_heartbeat_at timestamp with time zone, eligible boolean, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_agent_id uuid; state public.agent_assignment_presence;
begin
  if coalesce(public.get_request_organization_role(p_organization_id)::text, '') not in ('agent', 'supervisor') then
    raise exception using errcode = '42501', message = 'accepted Agent or Supervisor role required';
  end if;
  v_agent_id := public.get_current_human_agent_id(p_organization_id);
  update public.agent_assignment_presence p
  set last_heartbeat_at = clock_timestamp(), updated_at = clock_timestamp()
  where p.organization_id = p_organization_id and p.agent_id = v_agent_id and p.available
  returning * into state;
  if not found then raise exception using errcode = '23514', message = 'Agent is unavailable'; end if;
  perform public.process_auto_assignment_backlog(p_organization_id, null, 100, 'agent_available');
  return query select state.available, state.last_heartbeat_at, true, state.updated_at;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_my_assignment_availability(p_organization_id uuid, p_available boolean)
 RETURNS TABLE(available boolean, last_heartbeat_at timestamp with time zone, eligible boolean, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_agent_id uuid; state public.agent_assignment_presence;
begin
  if coalesce(public.get_request_organization_role(p_organization_id)::text, '') not in ('agent', 'supervisor')
    or p_available is null then
    raise exception using errcode = '42501', message = 'accepted Agent or Supervisor role required';
  end if;
  v_agent_id := public.get_current_human_agent_id(p_organization_id);
  insert into public.agent_assignment_presence (
    organization_id, agent_id, available, last_heartbeat_at, updated_at
  ) values (
    p_organization_id, v_agent_id, p_available,
    case when p_available then clock_timestamp() else null end, clock_timestamp()
  ) on conflict (organization_id, agent_id) do update
    set available = excluded.available,
        last_heartbeat_at = excluded.last_heartbeat_at,
        updated_at = excluded.updated_at
  returning * into state;
  if p_available then
    perform public.process_auto_assignment_backlog(p_organization_id, null, 100, 'agent_available');
  end if;
  return query select state.available, state.last_heartbeat_at,
    state.available and state.last_heartbeat_at >= clock_timestamp() - interval '2 minutes', state.updated_at;
end;
$function$
;


