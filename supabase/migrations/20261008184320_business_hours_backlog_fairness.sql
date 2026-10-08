-- Generated with supabase db diff --use-pg-schema; retain only the business-hours
-- backlog fairness change. Unrelated baseline drift/ACL revoke noise was removed.
set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.process_auto_assignment_backlog(p_organization_id uuid DEFAULT NULL::uuid, p_routing_queue_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 100, p_source text DEFAULT 'recovery'::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare candidate record; processed integer := 0; result public.conversations;
begin
  for candidate in
    select c.id
    from public.conversations c
    join public.routing_queues q
      on q.organization_id = c.organization_id and q.id = c.routing_queue_id
    join public.organization_automation_settings settings
      on settings.organization_id = c.organization_id
    join public.organization_lifecycle lifecycle
      on lifecycle.organization_id = c.organization_id
      and lifecycle.status = 'active'
    join public.organizations org on org.id=c.organization_id
    where c.status = 'active' and c.assigned_agent_id is null
      and settings.auto_assign_conversations
      and q.status = 'active' and q.assignment_strategy = 'round_robin'
      -- Filter before LIMIT: a closed team's old requests must not starve an
      -- open team's backlog. Do not perform presence-count queries per row.
      and (org.extra->'business_hours'->>'enabled'='false'
        or public.business_hours_schedule_open(coalesce(
          nullif(org.extra->'business_hours'->'queue_overrides'->q.id::text,'null'::jsonb),
          org.extra->'business_hours'),clock_timestamp()))
      and (p_organization_id is null or c.organization_id = p_organization_id)
      and (p_routing_queue_id is null or c.routing_queue_id = p_routing_queue_id)
    order by coalesce(c.routed_at, c.created_at), c.id
    limit least(greatest(coalesce(p_limit, 100), 1), 100)
  loop
    result := public.try_auto_assign_conversation(candidate.id, p_source);
    if result.assigned_agent_id is not null then processed := processed + 1; end if;
  end loop;
  return processed;
end;
$function$
;
