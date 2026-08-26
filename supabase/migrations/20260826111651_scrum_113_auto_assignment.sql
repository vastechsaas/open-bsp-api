







































































































































































drop function if exists "public"."list_platform_routing_queues_page"(p_organization_id uuid, p_page integer, p_page_size integer, p_search text, p_status text);

drop function if exists "public"."list_routing_queues_page"(p_organization_id uuid, p_page integer, p_page_size integer, p_search text);


  create table "public"."agent_assignment_presence" (
    "organization_id" uuid not null,
    "agent_id" uuid not null,
    "available" boolean not null default false,
    "last_heartbeat_at" timestamp with time zone,
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."agent_assignment_presence" enable row level security;


  create table "public"."conversation_assignment_events" (
    "organization_id" uuid not null,
    "id" uuid not null default gen_random_uuid(),
    "conversation_id" uuid not null,
    "routing_queue_id" uuid,
    "routing_queue_name" text,
    "previous_agent_id" uuid,
    "previous_agent_name" text,
    "assigned_agent_id" uuid,
    "assigned_agent_name" text,
    "actor_agent_id" uuid,
    "strategy" text not null,
    "source" text not null,
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."conversation_assignment_events" enable row level security;


  create table "public"."routing_queue_assignment_state" (
    "organization_id" uuid not null,
    "routing_queue_id" uuid not null,
    "last_assigned_agent_id" uuid,
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."routing_queue_assignment_state" enable row level security;

alter table "public"."organization_automation_settings" add column "auto_assign_conversations" boolean not null default false;

alter table "public"."routing_queues" add column "assignment_strategy" text not null default 'manual'::text;

CREATE INDEX agent_assignment_presence_eligible_idx ON public.agent_assignment_presence USING btree (organization_id, last_heartbeat_at DESC, agent_id) WHERE (available = true);

CREATE UNIQUE INDEX agent_assignment_presence_pkey ON public.agent_assignment_presence USING btree (organization_id, agent_id);

CREATE INDEX conversation_assignment_events_conversation_time_idx ON public.conversation_assignment_events USING btree (organization_id, conversation_id, created_at, id);

CREATE UNIQUE INDEX conversation_assignment_events_pkey ON public.conversation_assignment_events USING btree (id);

CREATE UNIQUE INDEX routing_queue_assignment_state_pkey ON public.routing_queue_assignment_state USING btree (organization_id, routing_queue_id);

alter table "public"."agent_assignment_presence" add constraint "agent_assignment_presence_pkey" PRIMARY KEY using index "agent_assignment_presence_pkey";

alter table "public"."conversation_assignment_events" add constraint "conversation_assignment_events_pkey" PRIMARY KEY using index "conversation_assignment_events_pkey";

alter table "public"."routing_queue_assignment_state" add constraint "routing_queue_assignment_state_pkey" PRIMARY KEY using index "routing_queue_assignment_state_pkey";

alter table "public"."agent_assignment_presence" add constraint "agent_assignment_presence_organization_id_agent_id_fkey" FOREIGN KEY (organization_id, agent_id) REFERENCES public.agents(organization_id, id) ON DELETE CASCADE not valid;

alter table "public"."agent_assignment_presence" validate constraint "agent_assignment_presence_organization_id_agent_id_fkey";

alter table "public"."conversation_assignment_events" add constraint "conversation_assignment_event_organization_id_actor_agent__fkey" FOREIGN KEY (organization_id, actor_agent_id) REFERENCES public.agents(organization_id, id) ON DELETE SET NULL (actor_agent_id) not valid;

alter table "public"."conversation_assignment_events" validate constraint "conversation_assignment_event_organization_id_actor_agent__fkey";

alter table "public"."conversation_assignment_events" add constraint "conversation_assignment_event_organization_id_assigned_age_fkey" FOREIGN KEY (organization_id, assigned_agent_id) REFERENCES public.agents(organization_id, id) ON DELETE SET NULL (assigned_agent_id) not valid;

alter table "public"."conversation_assignment_events" validate constraint "conversation_assignment_event_organization_id_assigned_age_fkey";

alter table "public"."conversation_assignment_events" add constraint "conversation_assignment_event_organization_id_conversation_fkey" FOREIGN KEY (organization_id, conversation_id) REFERENCES public.conversations(organization_id, id) ON DELETE CASCADE not valid;

alter table "public"."conversation_assignment_events" validate constraint "conversation_assignment_event_organization_id_conversation_fkey";

alter table "public"."conversation_assignment_events" add constraint "conversation_assignment_event_organization_id_previous_age_fkey" FOREIGN KEY (organization_id, previous_agent_id) REFERENCES public.agents(organization_id, id) ON DELETE SET NULL (previous_agent_id) not valid;

alter table "public"."conversation_assignment_events" validate constraint "conversation_assignment_event_organization_id_previous_age_fkey";

alter table "public"."conversation_assignment_events" add constraint "conversation_assignment_event_organization_id_routing_queu_fkey" FOREIGN KEY (organization_id, routing_queue_id) REFERENCES public.routing_queues(organization_id, id) ON DELETE SET NULL (routing_queue_id) not valid;

alter table "public"."conversation_assignment_events" validate constraint "conversation_assignment_event_organization_id_routing_queu_fkey";

alter table "public"."conversation_assignment_events" add constraint "conversation_assignment_events_source_check" CHECK ((source = ANY (ARRAY['chatbot_handoff'::text, 'queue_transfer'::text, 'manual_unassignment'::text, 'automation_enabled'::text, 'agent_available'::text, 'recovery'::text]))) not valid;

alter table "public"."conversation_assignment_events" validate constraint "conversation_assignment_events_source_check";

alter table "public"."conversation_assignment_events" add constraint "conversation_assignment_events_strategy_check" CHECK ((strategy = 'round_robin'::text)) not valid;

alter table "public"."conversation_assignment_events" validate constraint "conversation_assignment_events_strategy_check";

alter table "public"."routing_queue_assignment_state" add constraint "routing_queue_assignment_stat_organization_id_last_assigne_fkey" FOREIGN KEY (organization_id, last_assigned_agent_id) REFERENCES public.agents(organization_id, id) ON DELETE SET NULL (last_assigned_agent_id) not valid;

alter table "public"."routing_queue_assignment_state" validate constraint "routing_queue_assignment_stat_organization_id_last_assigne_fkey";

alter table "public"."routing_queue_assignment_state" add constraint "routing_queue_assignment_stat_organization_id_routing_queu_fkey" FOREIGN KEY (organization_id, routing_queue_id) REFERENCES public.routing_queues(organization_id, id) ON DELETE CASCADE not valid;

alter table "public"."routing_queue_assignment_state" validate constraint "routing_queue_assignment_stat_organization_id_routing_queu_fkey";

alter table "public"."routing_queues" add constraint "routing_queues_assignment_strategy_check" CHECK ((assignment_strategy = ANY (ARRAY['manual'::text, 'round_robin'::text]))) not valid;

alter table "public"."routing_queues" validate constraint "routing_queues_assignment_strategy_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.get_my_assignment_availability(p_organization_id uuid)
 RETURNS TABLE(available boolean, last_heartbeat_at timestamp with time zone, eligible boolean, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_agent_id uuid;
begin
  if public.get_request_organization_role(p_organization_id) <> 'agent'::public.role then
    raise exception using errcode = '42501', message = 'accepted Agent role required';
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
  if public.get_request_organization_role(p_organization_id) <> 'agent'::public.role then
    raise exception using errcode = '42501', message = 'accepted Agent role required';
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
    where c.status = 'active' and c.assigned_agent_id is null
      and settings.auto_assign_conversations
      and q.status = 'active' and q.assignment_strategy = 'round_robin'
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

CREATE OR REPLACE FUNCTION public.set_my_assignment_availability(p_organization_id uuid, p_available boolean)
 RETURNS TABLE(available boolean, last_heartbeat_at timestamp with time zone, eligible boolean, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_agent_id uuid; state public.agent_assignment_presence;
begin
  if public.get_request_organization_role(p_organization_id) <> 'agent'::public.role
    or p_available is null then
    raise exception using errcode = '42501', message = 'accepted Agent role required';
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

CREATE OR REPLACE FUNCTION public.try_auto_assign_conversation(p_conversation_id uuid, p_source text DEFAULT 'recovery'::text)
 RETURNS public.conversations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  conversation_row public.conversations;
  queue_row public.routing_queues;
  selected_agent public.agents;
  last_agent_id uuid;
  assignment_time timestamptz := clock_timestamp();
  assignment_event_id uuid;
begin
  select c.* into conversation_row
  from public.conversations c
  where c.id = p_conversation_id
  for update;

  if not found or conversation_row.status <> 'active'
    or conversation_row.assigned_agent_id is not null
    or conversation_row.routing_queue_id is null then
    return conversation_row;
  end if;

  select q.* into queue_row
  from public.routing_queues q
  join public.organization_automation_settings settings
    on settings.organization_id = q.organization_id
   and settings.auto_assign_conversations
  where q.organization_id = conversation_row.organization_id
    and q.id = conversation_row.routing_queue_id
    and q.status = 'active'
    and q.assignment_strategy = 'round_robin';

  if not found then return conversation_row; end if;

  insert into public.routing_queue_assignment_state (
    organization_id, routing_queue_id
  ) values (conversation_row.organization_id, queue_row.id)
  on conflict (organization_id, routing_queue_id) do nothing;

  select state.last_assigned_agent_id into last_agent_id
  from public.routing_queue_assignment_state state
  where state.organization_id = conversation_row.organization_id
    and state.routing_queue_id = queue_row.id
  for update;

  with eligible as (
    select a.*, row_number() over (order by member.created_at, a.id) as position
    from public.routing_queue_members member
    join public.agents a
      on a.organization_id = member.organization_id and a.id = member.agent_id
    join public.agent_assignment_presence presence
      on presence.organization_id = a.organization_id and presence.agent_id = a.id
    where member.organization_id = conversation_row.organization_id
      and member.routing_queue_id = queue_row.id
      and a.ai = false and a.user_id is not null
      and a.extra->>'role' = 'agent'
      and coalesce(a.extra->'invitation'->>'status', 'accepted') = 'accepted'
      and presence.available
      and presence.last_heartbeat_at >= assignment_time - interval '2 minutes'
  ), cursor_position as (
    select position from eligible where id = last_agent_id
  )
  select e.organization_id, e.user_id, e.id, e.name, e.picture, e.ai,
         e.extra, e.created_at, e.updated_at
  into selected_agent
  from eligible e
  order by
    case when e.position > coalesce((select position from cursor_position), 0) then 0 else 1 end,
    e.position
  limit 1;

  if not found then return conversation_row; end if;

  update public.conversations c
  set assigned_agent_id = selected_agent.id
  where c.id = conversation_row.id
  returning * into conversation_row;

  update public.routing_queue_assignment_state state
  set last_assigned_agent_id = selected_agent.id, updated_at = assignment_time
  where state.organization_id = conversation_row.organization_id
    and state.routing_queue_id = queue_row.id;

  insert into public.conversation_assignment_events (
    organization_id, conversation_id, routing_queue_id, routing_queue_name,
    assigned_agent_id, assigned_agent_name, strategy, source, created_at
  ) values (
    conversation_row.organization_id, conversation_row.id, queue_row.id, queue_row.name,
    selected_agent.id, selected_agent.name, 'round_robin', p_source, assignment_time
  ) returning id into assignment_event_id;

  insert into public.messages (
    organization_id, conversation_id, direction, agent_id, service,
    organization_address, group_address, content, status, timestamp
  ) values (
    conversation_row.organization_id, conversation_row.id, 'internal', null,
    conversation_row.service, conversation_row.organization_address,
    conversation_row.group_address,
    jsonb_build_object(
      'version', '1', 'type', 'text', 'kind', 'assignment_event',
      'text', format('Automatically assigned to %s using Round Robin.', selected_agent.name),
      'assignment_event', jsonb_build_object(
        'id', assignment_event_id, 'agent_id', selected_agent.id,
        'agent_name', selected_agent.name, 'queue_id', queue_row.id,
        'queue_name', queue_row.name, 'strategy', 'round_robin', 'source', p_source
      )
    ), '{}'::jsonb, assignment_time
  );

  perform public.enqueue_user_notification(
    conversation_row.organization_id, selected_agent.id, null,
    conversation_row.id, 'conversation_assigned',
    format('automatic_assignment:%s', assignment_event_id),
    jsonb_build_object(
      'assignment_event_id', assignment_event_id,
      'assigned_agent_id', selected_agent.id,
      'routing_queue_id', queue_row.id,
      'routing_queue_name', queue_row.name,
      'strategy', 'round_robin'
    )
  );

  return conversation_row;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_organization_auto_assignment(p_organization_id uuid, p_enabled boolean)
 RETURNS public.organization_automation_settings
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare settings public.organization_automation_settings;
begin
  if public.get_request_organization_role(p_organization_id) not in (
    'owner'::public.role, 'admin'::public.role, 'supervisor'::public.role
  ) or p_enabled is null then
    raise exception using errcode = '42501', message = 'owner, admin, or supervisor role required';
  end if;
  update public.organization_automation_settings s
  set auto_assign_conversations = p_enabled, updated_at = now(),
      updated_by_user_id = auth.uid(), updated_by_scope = 'organization'
  where s.organization_id = p_organization_id returning * into settings;
  if p_enabled then perform public.process_auto_assignment_backlog(p_organization_id, null, 100, 'automation_enabled'); end if;
  return settings;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_platform_organization_auto_assignment(p_organization_id uuid, p_enabled boolean, p_request_id uuid)
 RETURNS public.organization_automation_settings
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare admin_user_id uuid; existing public.platform_admin_action_events;
  before_settings public.organization_automation_settings;
  after_settings public.organization_automation_settings;
begin
  admin_user_id := public.require_platform_admin();
  if p_enabled is null or p_request_id is null then
    raise exception using errcode = '22023', message = 'enabled state and request id are required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(admin_user_id::text || ':' || p_request_id::text, 0));
  select e.* into existing from public.platform_admin_action_events e
  where e.platform_admin_user_id = admin_user_id and e.request_id = p_request_id;
  if found then
    if existing.action_type <> 'organization_automation.update'
      or existing.organization_id <> p_organization_id
      or existing.target_id <> 'auto_assignment' then
      raise exception using errcode = '22023', message = 'request id already used';
    end if;
    select s.* into after_settings from public.organization_automation_settings s
    where s.organization_id = p_organization_id;
    return after_settings;
  end if;
  select s.* into before_settings from public.organization_automation_settings s
  where s.organization_id = p_organization_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'automation settings not found'; end if;
  update public.organization_automation_settings s
  set auto_assign_conversations = p_enabled, updated_at = now(),
      updated_by_user_id = admin_user_id, updated_by_scope = 'platform'
  where s.organization_id = p_organization_id returning * into after_settings;
  insert into public.platform_admin_action_events (
    platform_admin_user_id, organization_id, action_type, target_type,
    target_id, request_id, before_state, after_state
  ) values (
    admin_user_id, p_organization_id, 'organization_automation.update',
    'organization_automation', 'auto_assignment', p_request_id,
    to_jsonb(before_settings), to_jsonb(after_settings)
  );
  if p_enabled then perform public.process_auto_assignment_backlog(p_organization_id, null, 100, 'automation_enabled'); end if;
  return after_settings;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_platform_routing_queue_assignment_strategy(p_organization_id uuid, p_routing_queue_id uuid, p_strategy text, p_request_id uuid)
 RETURNS public.routing_queues
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare admin_user_id uuid; existing public.platform_admin_action_events;
  before_queue public.routing_queues; after_queue public.routing_queues;
begin
  admin_user_id := public.require_platform_admin();
  if p_strategy not in ('manual', 'round_robin') or p_request_id is null then
    raise exception using errcode = '22023', message = 'valid strategy and request id are required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(admin_user_id::text || ':' || p_request_id::text, 0));
  select e.* into existing from public.platform_admin_action_events e
  where e.platform_admin_user_id = admin_user_id and e.request_id = p_request_id;
  if found then
    if existing.action_type <> 'routing_queue.update'
      or existing.organization_id <> p_organization_id
      or existing.target_id <> p_routing_queue_id::text then
      raise exception using errcode = '22023', message = 'request id already used';
    end if;
    select q.* into after_queue from public.routing_queues q where q.id = p_routing_queue_id;
    return after_queue;
  end if;
  select q.* into before_queue from public.routing_queues q
  where q.organization_id = p_organization_id and q.id = p_routing_queue_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'routing queue not found'; end if;
  update public.routing_queues q set assignment_strategy = p_strategy
  where q.id = p_routing_queue_id returning * into after_queue;
  insert into public.platform_admin_action_events (
    platform_admin_user_id, organization_id, action_type, target_type,
    target_id, request_id, before_state, after_state
  ) values (
    admin_user_id, p_organization_id, 'routing_queue.update', 'routing_queue',
    p_routing_queue_id::text, p_request_id, to_jsonb(before_queue), to_jsonb(after_queue)
  );
  if p_strategy = 'round_robin' then perform public.process_auto_assignment_backlog(p_organization_id, p_routing_queue_id, 100, 'automation_enabled'); end if;
  return after_queue;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_routing_queue_assignment_strategy(p_routing_queue_id uuid, p_strategy text)
 RETURNS public.routing_queues
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare queue public.routing_queues;
begin
  if p_strategy not in ('manual', 'round_robin') then
    raise exception using errcode = '22023', message = 'invalid assignment strategy';
  end if;
  select q.* into queue from public.routing_queues q where q.id = p_routing_queue_id for update;
  if not found or public.get_request_organization_role(queue.organization_id) not in (
    'owner'::public.role, 'admin'::public.role, 'supervisor'::public.role
  ) then raise exception using errcode = '42501', message = 'queue management permission required'; end if;
  update public.routing_queues q set assignment_strategy = p_strategy where q.id = queue.id returning * into queue;
  if p_strategy = 'round_robin' then perform public.process_auto_assignment_backlog(queue.organization_id, queue.id, 100, 'automation_enabled'); end if;
  return queue;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.assign_conversation_to_me(p_conversation_id uuid)
 RETURNS public.conversations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  updated_conversation public.conversations;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'authentication required';
  end if;

  update public.conversations c
  set assigned_agent_id = a.id
  from public.agents a
  where c.id = p_conversation_id
    and c.assigned_agent_id is null
    and c.organization_id in (
      select public.get_authorized_orgs('agent')
    )
    and (
      public.get_request_organization_role(c.organization_id) <> 'agent'::public.role
      or c.status = 'active'
    )
    and a.organization_id = c.organization_id
    and a.user_id = auth.uid()
    and a.ai = false
    and (
      c.routing_queue_id is null
      or exists (
        select 1
        from public.routing_queue_members member
        where member.organization_id = c.organization_id
          and member.routing_queue_id = c.routing_queue_id
          and member.agent_id = a.id
      )
    )
  returning c.* into updated_conversation;

  if found then
    updated_conversation := public.try_auto_assign_conversation(
      updated_conversation.id,
      'manual_unassignment'
    );
    return updated_conversation;
  end if;

  if not exists (
    select 1
    from public.conversations
    where id = p_conversation_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'conversation not found';
  end if;

  if not exists (
    select 1
    from public.conversations
    where id = p_conversation_id
      and organization_id in (
        select public.get_authorized_orgs('agent')
      )
  ) then
    raise exception using
      errcode = '42501',
      message = 'conversation is not accessible to the authenticated user';
  end if;

  if exists (
    select 1
    from public.conversations c
    where c.id = p_conversation_id
      and public.get_request_organization_role(c.organization_id) = 'agent'::public.role
      and not public.agent_can_read_conversation(c.organization_id, c.id)
  ) then
    raise exception using
      errcode = '42501',
      message = 'conversation is not accessible to the authenticated user';
  end if;

  if not exists (
    select 1
    from public.agents a
    join public.conversations c
      on c.organization_id = a.organization_id
    where c.id = p_conversation_id
      and a.user_id = auth.uid()
      and a.ai = false
  ) then
    raise exception using
      errcode = '23514',
      message = 'authenticated user is not a human agent in the conversation organization';
  end if;

  raise exception using
    errcode = '23505',
    message = 'conversation is already assigned';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_routing_queue_audit_state(p_routing_queue_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'id', queue.id,
    'name', queue.name,
    'status', queue.status,
    'assignment_strategy', queue.assignment_strategy,
    'agent_ids', coalesce(
      (
        select jsonb_agg(member.agent_id order by member.agent_id)
        from public.routing_queue_members member
        where member.organization_id = queue.organization_id
          and member.routing_queue_id = queue.id
      ),
      '[]'::jsonb
    )
  )
  from public.routing_queues queue
  where queue.id = p_routing_queue_id;
$function$
;

CREATE OR REPLACE FUNCTION public.list_platform_routing_queues_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, organization_id uuid, name text, status text, assignment_strategy text, member_ids uuid[], member_names text[], member_pictures text[], member_count bigint, eligible_member_count bigint, created_at timestamp with time zone, updated_at timestamp with time zone, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  normalized_page integer := greatest(coalesce(p_page, 1), 1);
  normalized_page_size integer := least(greatest(coalesce(p_page_size, 10), 1), 50);
  normalized_search text := nullif(btrim(coalesce(p_search, '')), '');
  normalized_status text := nullif(lower(btrim(coalesce(p_status, ''))), '');
begin
  perform public.require_platform_admin();

  if not exists (
    select 1 from public.organizations organization
    where organization.id = p_organization_id
  ) then
    raise exception using errcode = 'P0002', message = 'organization not found';
  end if;

  if normalized_status is not null
    and normalized_status not in ('active', 'archived')
  then
    raise exception using
      errcode = '22023',
      message = 'routing queue status filter is invalid';
  end if;

  return query
  with filtered as (
    select queue.*
    from public.routing_queues queue
    where queue.organization_id = p_organization_id
      and (
        normalized_search is null
        or queue.name ilike '%' || normalized_search || '%'
      )
      and (normalized_status is null or queue.status = normalized_status)
  )
  select
    queue.id,
    queue.organization_id,
    queue.name,
    queue.status,
    queue.assignment_strategy,
    coalesce(members.member_ids, array[]::uuid[]),
    coalesce(members.member_names, array[]::text[]),
    coalesce(members.member_pictures, array[]::text[]),
    coalesce(members.member_count, 0),
    coalesce(members.eligible_member_count, 0),
    queue.created_at,
    queue.updated_at,
    count(*) over()
  from filtered queue
  left join lateral (
    select
      array_agg(agent.id order by lower(agent.name), agent.id) as member_ids,
      array_agg(agent.name order by lower(agent.name), agent.id) as member_names,
      array_agg(coalesce(agent.picture, '') order by lower(agent.name), agent.id)
        as member_pictures,
      count(*) as member_count
      , count(*) filter (
        where presence.available
          and presence.last_heartbeat_at >= clock_timestamp() - interval '2 minutes'
      ) as eligible_member_count
    from public.routing_queue_members member
    join public.agents agent
      on agent.organization_id = member.organization_id
      and agent.id = member.agent_id
    left join public.agent_assignment_presence presence
      on presence.organization_id = member.organization_id
      and presence.agent_id = member.agent_id
    where member.organization_id = queue.organization_id
      and member.routing_queue_id = queue.id
  ) members on true
  order by queue.name asc, queue.id asc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_routing_queues_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, organization_id uuid, name text, status text, assignment_strategy text, member_ids uuid[], member_count bigint, eligible_member_count bigint, created_at timestamp with time zone, updated_at timestamp with time zone, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  request_role public.role;
  normalized_page integer := greatest(coalesce(p_page, 1), 1);
  normalized_page_size integer := least(greatest(coalesce(p_page_size, 10), 1), 50);
  normalized_search text := nullif(btrim(coalesce(p_search, '')), '');
begin
  request_role := public.get_request_organization_role(p_organization_id);
  if request_role not in (
    'owner'::public.role,
    'admin'::public.role,
    'supervisor'::public.role
  ) then
    raise exception using
      errcode = '42501',
      message = 'owner, admin, or supervisor role required to manage routing queues';
  end if;

  return query
  with filtered as (
    select queue.*
    from public.routing_queues queue
    where queue.organization_id = p_organization_id
      and (
        normalized_search is null
        or queue.name ilike '%' || normalized_search || '%'
      )
  )
  select
    queue.id,
    queue.organization_id,
    queue.name,
    queue.status,
    queue.assignment_strategy,
    coalesce(members.member_ids, array[]::uuid[]),
    coalesce(members.member_count, 0),
    coalesce(members.eligible_member_count, 0),
    queue.created_at,
    queue.updated_at,
    count(*) over() as total_count
  from filtered queue
  left join lateral (
    select
      array_agg(member.agent_id order by member.agent_id) as member_ids,
      count(*) as member_count,
      count(*) filter (
        where presence.available
          and presence.last_heartbeat_at >= clock_timestamp() - interval '2 minutes'
      ) as eligible_member_count
    from public.routing_queue_members member
    left join public.agent_assignment_presence presence
      on presence.organization_id = member.organization_id
      and presence.agent_id = member.agent_id
    where member.organization_id = queue.organization_id
      and member.routing_queue_id = queue.id
  ) members on true
  order by queue.name asc, queue.id asc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.route_conversation_to_queue(p_conversation_id uuid, p_routing_queue_id uuid)
 RETURNS public.conversations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  target_conversation public.conversations;
  destination_queue public.routing_queues;
  previous_routing_queue_id uuid;
  previous_queue_name text;
  route_time timestamp with time zone := now();
begin
  select conversation.* into target_conversation
  from public.conversations conversation
  where conversation.id = p_conversation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'conversation not found';
  end if;

  if target_conversation.status <> 'active' then
    raise exception using
      errcode = '23514',
      message = 'only active conversations can be routed';
  end if;

  select queue.* into destination_queue
  from public.routing_queues queue
  where queue.id = p_routing_queue_id
    and queue.organization_id = target_conversation.organization_id
    and queue.status = 'active';

  if not found then
    raise exception using
      errcode = '23514',
      message = 'routing destination must be an active queue in the same organization';
  end if;

  previous_routing_queue_id := target_conversation.routing_queue_id;

  if previous_routing_queue_id is not null then
    select queue.name into previous_queue_name
    from public.routing_queues queue
    where queue.id = previous_routing_queue_id
      and queue.organization_id = target_conversation.organization_id;
  end if;

  update public.conversations conversation
  set routing_queue_id = p_routing_queue_id,
      routed_at = route_time,
      assigned_agent_id = null
  where conversation.id = p_conversation_id
  returning * into target_conversation;

  insert into public.conversation_routing_events (
    organization_id,
    conversation_id,
    previous_routing_queue_id,
    previous_routing_queue_name,
    destination_routing_queue_id,
    destination_routing_queue_name,
    actor_agent_id,
    source,
    explanation,
    created_at
  ) values (
    target_conversation.organization_id,
    target_conversation.id,
    previous_routing_queue_id,
    previous_queue_name,
    destination_queue.id,
    destination_queue.name,
    null,
    'chatbot_handoff',
    null,
    route_time
  );

  target_conversation := public.try_auto_assign_conversation(
    target_conversation.id,
    'chatbot_handoff'
  );

  return target_conversation;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_conversation_agent_assignment(p_conversation_id uuid, p_agent_id uuid)
 RETURNS public.conversations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  target_conversation public.conversations;
  caller_role public.role;
  actor_agent_id uuid;
  previous_assigned_agent_id uuid;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'authentication required';
  end if;

  select c.* into target_conversation
  from public.conversations c
  where c.id = p_conversation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'conversation not found';
  end if;

  caller_role := public.get_request_organization_role(
    target_conversation.organization_id
  );
  actor_agent_id := public.get_current_human_agent_id(
    target_conversation.organization_id
  );
  previous_assigned_agent_id := target_conversation.assigned_agent_id;

  if caller_role not in (
    'owner'::public.role,
    'admin'::public.role,
    'supervisor'::public.role
  ) then
    raise exception using
      errcode = '42501',
      message = 'only owners, admins, and supervisors can manage Agent assignments';
  end if;

  if target_conversation.assigned_agent_id is not null
    and not exists (
      select 1
      from public.agents a
      where a.id = target_conversation.assigned_agent_id
        and a.organization_id = target_conversation.organization_id
        and a.ai = false
        and a.user_id is not null
        and a.extra->>'role' = 'agent'
        and (
          a.extra->'invitation' is null
          or a.extra->'invitation'->>'status' = 'accepted'
        )
    )
  then
    raise exception using
      errcode = '42501',
      message = 'conversations assigned to non-Agent users cannot be reassigned';
  end if;

  if p_agent_id is not null
    and not exists (
      select 1
      from public.agents a
      where a.id = p_agent_id
        and a.organization_id = target_conversation.organization_id
        and a.ai = false
        and a.user_id is not null
        and a.extra->>'role' = 'agent'
        and (
          a.extra->'invitation' is null
          or a.extra->'invitation'->>'status' = 'accepted'
        )
    )
  then
    raise exception using
      errcode = '23514',
      message = 'assignee must be an accepted Agent in the same organization';
  end if;

  if p_agent_id is not null
    and target_conversation.routing_queue_id is not null
    and not exists (
      select 1
      from public.routing_queue_members member
      where member.organization_id = target_conversation.organization_id
        and member.routing_queue_id = target_conversation.routing_queue_id
        and member.agent_id = p_agent_id
    )
  then
    raise exception using
      errcode = '23514',
      message = 'assignee must belong to the conversation routing queue';
  end if;

  update public.conversations
  set assigned_agent_id = p_agent_id
  where id = p_conversation_id
  returning * into target_conversation;

  if p_agent_id is null then
    target_conversation := public.try_auto_assign_conversation(
      target_conversation.id,
      'manual_unassignment'
    );
  end if;

  if p_agent_id is not null
    and p_agent_id is distinct from previous_assigned_agent_id
  then
    perform public.enqueue_user_notification(
      target_conversation.organization_id,
      p_agent_id,
      actor_agent_id,
      target_conversation.id,
      'conversation_assigned',
      format(
        'conversation_assignment:%s:%s:%s',
        target_conversation.id,
        p_agent_id,
        txid_current()
      ),
      jsonb_build_object(
        'previous_assigned_agent_id', previous_assigned_agent_id,
        'assigned_agent_id', p_agent_id
      )
    );
  end if;

  return target_conversation;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.transfer_conversation_to_queue_with_private_note(p_conversation_id uuid, p_target_routing_queue_id uuid, p_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  conversation_row public.conversations;
  updated_conversation public.conversations;
  destination_queue public.routing_queues;
  previous_queue_name text;
  author_agent_id uuid;
  request_role public.role;
  normalized_text text := btrim(coalesce(p_text, ''));
  transfer_time timestamp with time zone := now();
  note public.messages;
  routing_event public.conversation_routing_events;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'authentication required';
  end if;

  if normalized_text = '' then
    raise exception using
      errcode = '22023',
      message = 'queue transfer explanation is required';
  end if;

  select conversation.* into conversation_row
  from public.conversations conversation
  where conversation.id = p_conversation_id
  for update;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'conversation is not accessible to the authenticated user';
  end if;

  if conversation_row.status <> 'active' then
    raise exception using
      errcode = '22023',
      message = 'only active conversations can be transferred';
  end if;

  request_role := public.get_request_organization_role(
    conversation_row.organization_id
  );
  author_agent_id := public.get_current_human_agent_id(
    conversation_row.organization_id
  );

  if author_agent_id is null
    or (
      request_role = 'agent'::public.role
      and conversation_row.assigned_agent_id is distinct from author_agent_id
    )
    or request_role not in (
      'owner'::public.role,
      'admin'::public.role,
      'supervisor'::public.role,
      'agent'::public.role
    )
  then
    raise exception using
      errcode = '42501',
      message = 'conversation queue transfer is not permitted';
  end if;

  select queue.* into destination_queue
  from public.routing_queues queue
  where queue.id = p_target_routing_queue_id
    and queue.organization_id = conversation_row.organization_id
    and queue.status = 'active'
  for key share;

  if not found then
    raise exception using
      errcode = '22023',
      message = 'destination must be an active queue in the same organization';
  end if;

  if conversation_row.routing_queue_id = destination_queue.id then
    raise exception using
      errcode = '22023',
      message = 'destination queue must be different from the current queue';
  end if;

  if conversation_row.routing_queue_id is not null then
    select queue.name into previous_queue_name
    from public.routing_queues queue
    where queue.id = conversation_row.routing_queue_id
      and queue.organization_id = conversation_row.organization_id;
  end if;

  insert into public.messages (
    organization_id,
    conversation_id,
    direction,
    agent_id,
    contact_address,
    service,
    organization_address,
    group_address,
    content,
    status
  ) values (
    conversation_row.organization_id,
    conversation_row.id,
    'internal'::public.direction,
    author_agent_id,
    conversation_row.contact_address,
    conversation_row.service,
    conversation_row.organization_address,
    conversation_row.group_address,
    jsonb_build_object(
      'version', '1',
      'type', 'text',
      'kind', 'private_note',
      'text', normalized_text,
      'mentioned_agent_ids', '[]'::jsonb,
      'routing_transfer', jsonb_build_object(
        'from_queue_id', conversation_row.routing_queue_id,
        'from_queue_name', previous_queue_name,
        'to_queue_id', destination_queue.id,
        'to_queue_name', destination_queue.name
      )
    ),
    '{}'::jsonb
  )
  returning * into note;

  insert into public.conversation_routing_events (
    organization_id,
    conversation_id,
    previous_routing_queue_id,
    previous_routing_queue_name,
    destination_routing_queue_id,
    destination_routing_queue_name,
    actor_agent_id,
    source,
    explanation,
    created_at
  ) values (
    conversation_row.organization_id,
    conversation_row.id,
    conversation_row.routing_queue_id,
    previous_queue_name,
    destination_queue.id,
    destination_queue.name,
    author_agent_id,
    'manual_transfer',
    normalized_text,
    transfer_time
  )
  returning * into routing_event;

  update public.conversations conversation
  set routing_queue_id = destination_queue.id,
      routed_at = transfer_time,
      assigned_agent_id = null
  where conversation.id = conversation_row.id
  returning * into updated_conversation;

  perform public.enqueue_user_notification(
    updated_conversation.organization_id,
    member.agent_id,
    author_agent_id,
    updated_conversation.id,
    'conversation_transferred_to_queue',
    format('conversation_queue_transfer:%s', routing_event.id),
    jsonb_build_object(
      'message_id', note.id,
      'routing_event_id', routing_event.id,
      'from_queue_id', conversation_row.routing_queue_id,
      'from_queue_name', previous_queue_name,
      'to_queue_id', destination_queue.id,
      'to_queue_name', destination_queue.name,
      'text', normalized_text
    )
  )
  from public.routing_queue_members member
  where member.organization_id = updated_conversation.organization_id
    and member.routing_queue_id = destination_queue.id
    and member.agent_id is distinct from author_agent_id;

  updated_conversation := public.try_auto_assign_conversation(
    updated_conversation.id,
    'queue_transfer'
  );

  return jsonb_build_object(
    'conversation', to_jsonb(updated_conversation),
    'note', to_jsonb(note),
    'routing_event', to_jsonb(routing_event)
  );
end;
$function$
;

grant select on table "public"."agent_assignment_presence" to "authenticated";

grant references on table "public"."agent_assignment_presence" to "service_role";

grant trigger on table "public"."agent_assignment_presence" to "service_role";

grant truncate on table "public"."agent_assignment_presence" to "service_role";

grant select on table "public"."conversation_assignment_events" to "authenticated";

grant references on table "public"."conversation_assignment_events" to "service_role";

grant trigger on table "public"."conversation_assignment_events" to "service_role";

grant truncate on table "public"."conversation_assignment_events" to "service_role";

grant references on table "public"."routing_queue_assignment_state" to "service_role";

grant trigger on table "public"."routing_queue_assignment_state" to "service_role";

grant truncate on table "public"."routing_queue_assignment_state" to "service_role";


  create policy "agents can read their assignment presence"
  on "public"."agent_assignment_presence"
  as permissive
  for select
  to authenticated
using (((agent_id = public.get_current_human_agent_id(organization_id)) OR (public.get_request_organization_role(organization_id) = ANY (ARRAY['owner'::public.role, 'admin'::public.role, 'supervisor'::public.role]))));



  create policy "authorized users can read assignment events"
  on "public"."conversation_assignment_events"
  as permissive
  for select
  to authenticated
using (((public.get_request_organization_role(organization_id) = ANY (ARRAY['owner'::public.role, 'admin'::public.role, 'supervisor'::public.role])) OR public.agent_can_read_conversation(organization_id, conversation_id)));


select cron.schedule(
  'auto-assignment-recovery-every-minute',
  '* * * * *',
  $$select public.process_auto_assignment_backlog(null, null, 100, 'recovery');$$
);
