drop trigger if exists "broadcast_conversation_queue_state_trigger" on "public"."conversations";

drop trigger if exists "enforce_human_conversation_assignee" on "public"."conversations";

drop policy "agents can update assigned conversations" on "public"."conversations";

drop function if exists "public"."agent_conversation_update_rules"(p_id uuid, p_organization_id uuid, p_service public.service, p_organization_address text, p_contact_address text, p_group_address text, p_assigned_agent_id uuid);

drop function if exists "public"."commit_chatbot_flow_execution"(p_run_id uuid, p_expected_lock_version bigint, p_message_id uuid, p_current_node_id text, p_status text, p_waiting_for text, p_variables jsonb, p_error jsonb, p_outgoing_texts text[], p_outgoing_messages jsonb, p_handoff_agent_id uuid);

drop function if exists "public"."get_conversation_queue_conversations"(p_organization_id uuid, p_queue_key text, p_limit integer, p_offset integer);

drop function if exists "public"."list_mentioned_conversations_page"(p_organization_id uuid, p_page integer, p_page_size integer, p_search text);


  create table "public"."routing_queue_members" (
    "organization_id" uuid not null,
    "routing_queue_id" uuid not null,
    "agent_id" uuid not null,
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."routing_queue_members" enable row level security;


  create table "public"."routing_queues" (
    "organization_id" uuid not null,
    "id" uuid not null default gen_random_uuid(),
    "name" text not null,
    "status" text not null default 'active'::text,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."routing_queues" enable row level security;

alter table "public"."conversations" add column "routed_at" timestamp with time zone;

alter table "public"."conversations" add column "routing_queue_id" uuid;

CREATE INDEX conversations_routing_queue_state_idx ON public.conversations USING btree (organization_id, routing_queue_id, status, assigned_agent_id, routed_at);

CREATE INDEX routing_queue_members_agent_idx ON public.routing_queue_members USING btree (organization_id, agent_id, routing_queue_id);

CREATE UNIQUE INDEX routing_queue_members_pkey ON public.routing_queue_members USING btree (organization_id, routing_queue_id, agent_id);

CREATE UNIQUE INDEX routing_queues_organization_id_id_key ON public.routing_queues USING btree (organization_id, id);

CREATE UNIQUE INDEX routing_queues_organization_name_key ON public.routing_queues USING btree (organization_id, lower(name));

CREATE INDEX routing_queues_organization_status_name_idx ON public.routing_queues USING btree (organization_id, status, name, id);

CREATE UNIQUE INDEX routing_queues_pkey ON public.routing_queues USING btree (id);

alter table "public"."routing_queue_members" add constraint "routing_queue_members_pkey" PRIMARY KEY using index "routing_queue_members_pkey";

alter table "public"."routing_queues" add constraint "routing_queues_pkey" PRIMARY KEY using index "routing_queues_pkey";

alter table "public"."conversations" add constraint "conversations_organization_id_routing_queue_id_fkey" FOREIGN KEY (organization_id, routing_queue_id) REFERENCES public.routing_queues(organization_id, id) ON DELETE RESTRICT not valid;

alter table "public"."conversations" validate constraint "conversations_organization_id_routing_queue_id_fkey";

alter table "public"."routing_queue_members" add constraint "routing_queue_members_agent_fkey" FOREIGN KEY (organization_id, agent_id) REFERENCES public.agents(organization_id, id) ON DELETE CASCADE not valid;

alter table "public"."routing_queue_members" validate constraint "routing_queue_members_agent_fkey";

alter table "public"."routing_queue_members" add constraint "routing_queue_members_queue_fkey" FOREIGN KEY (organization_id, routing_queue_id) REFERENCES public.routing_queues(organization_id, id) ON DELETE CASCADE not valid;

alter table "public"."routing_queue_members" validate constraint "routing_queue_members_queue_fkey";

alter table "public"."routing_queues" add constraint "routing_queues_name_check" CHECK (((char_length(btrim(name)) >= 1) AND (char_length(btrim(name)) <= 80))) not valid;

alter table "public"."routing_queues" validate constraint "routing_queues_name_check";

alter table "public"."routing_queues" add constraint "routing_queues_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."routing_queues" validate constraint "routing_queues_organization_id_fkey";

alter table "public"."routing_queues" add constraint "routing_queues_organization_id_id_key" UNIQUE using index "routing_queues_organization_id_id_key";

alter table "public"."routing_queues" add constraint "routing_queues_status_check" CHECK ((status = ANY (ARRAY['active'::text, 'archived'::text]))) not valid;

alter table "public"."routing_queues" validate constraint "routing_queues_status_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.agent_conversation_update_rules(p_id uuid, p_organization_id uuid, p_service public.service, p_organization_address text, p_contact_address text, p_group_address text, p_assigned_agent_id uuid, p_routing_queue_id uuid, p_routed_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1
    from public.conversations c
    where c.id = p_id
      and c.organization_id = p_organization_id
      and c.service = p_service
      and c.organization_address = p_organization_address
      and c.contact_address is not distinct from p_contact_address
      and c.group_address is not distinct from p_group_address
      and c.assigned_agent_id = p_assigned_agent_id
      and c.routing_queue_id is not distinct from p_routing_queue_id
      and c.routed_at is not distinct from p_routed_at
      and c.assigned_agent_id = public.get_current_human_agent_id(p_organization_id)
  );
$function$
;

CREATE OR REPLACE FUNCTION public.commit_chatbot_flow_execution(p_run_id uuid, p_expected_lock_version bigint, p_message_id uuid, p_current_node_id text, p_status text, p_waiting_for text, p_variables jsonb, p_error jsonb, p_outgoing_texts text[], p_outgoing_messages jsonb DEFAULT '[]'::jsonb, p_handoff_agent_id uuid DEFAULT NULL::uuid, p_handoff_routing_queue_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(outcome text, run_lock_version bigint, message_ids uuid[])
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  target_run public.chatbot_flow_runs;
  incoming public.messages;
  previous_message public.messages;
  target_conversation public.conversations;
  handoff_agent public.agents;
  handoff_queue public.routing_queues;
  outgoing_text text;
  outgoing_message jsonb;
  inserted_message_id uuid;
  inserted_message_ids uuid[] := array[]::uuid[];
begin
  select * into target_run
  from public.chatbot_flow_runs as run
  where run.id = p_run_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'chatbot flow run not found';
  end if;

  if target_run.lock_version <> p_expected_lock_version then
    return query select
      'conflict'::text,
      target_run.lock_version,
      inserted_message_ids;
    return;
  end if;

  if target_run.status not in ('running', 'waiting') then
    return query select
      'conflict'::text,
      target_run.lock_version,
      inserted_message_ids;
    return;
  end if;

  select * into incoming
  from public.messages as message
  where message.id = p_message_id;

  if not found
    or incoming.conversation_id <> target_run.conversation_id
    or incoming.direction <> 'incoming'::public.direction
  then
    raise exception using
      errcode = '23514',
      message = 'commit message must be incoming and belong to the run conversation';
  end if;

  if target_run.last_processed_message_id = incoming.id then
    return query select
      'duplicate'::text,
      target_run.lock_version,
      inserted_message_ids;
    return;
  end if;

  if target_run.last_processed_message_id is not null then
    select * into previous_message
    from public.messages as message
    where message.id = target_run.last_processed_message_id;

    if found and (
      previous_message.created_at > incoming.created_at
      or (
        previous_message.created_at = incoming.created_at
        and previous_message.id >= incoming.id
      )
    ) then
      return query select
        'stale'::text,
        target_run.lock_version,
        inserted_message_ids;
      return;
    end if;
  end if;

  if p_current_node_id is null or length(btrim(p_current_node_id)) = 0 then
    raise exception using
      errcode = '23514',
      message = 'committed chatbot node ID cannot be blank';
  end if;

  if p_status not in ('waiting', 'completed', 'failed', 'handed_off') then
    raise exception using
      errcode = '23514',
      message = 'chatbot execution can commit only waiting, completed, failed, or handed_off';
  end if;

  if jsonb_typeof(p_variables) is distinct from 'object' then
    raise exception using
      errcode = '23514',
      message = 'committed chatbot variables must be a JSON object';
  end if;

  if p_status = 'waiting'
    and p_waiting_for not in ('free_text', 'button', 'list_selection')
  then
    raise exception using
      errcode = '23514',
      message = 'waiting chatbot runs require a supported input type';
  end if;

  if p_status <> 'waiting' and p_waiting_for is not null then
    raise exception using
      errcode = '23514',
      message = 'terminal chatbot runs cannot wait for input';
  end if;

  if p_status = 'failed' and jsonb_typeof(p_error) is distinct from 'object' then
    raise exception using
      errcode = '23514',
      message = 'failed chatbot executions require an error object';
  end if;

  if p_status <> 'failed' and p_error is not null then
    raise exception using
      errcode = '23514',
      message = 'successful chatbot executions cannot store an error';
  end if;

  if p_status = 'handed_off' then
    if (p_handoff_agent_id is null) = (p_handoff_routing_queue_id is null) then
      raise exception using
        errcode = '23514',
        message = 'chatbot handoff requires exactly one Agent or routing queue destination';
    end if;

    if p_handoff_agent_id is not null then
      select * into handoff_agent
      from public.agents as agent
      where agent.organization_id = target_run.organization_id
        and agent.id = p_handoff_agent_id
        and agent.ai = false
        and agent.user_id is not null
        and coalesce(
          agent.extra->'invitation'->>'status',
          'accepted'
        ) = 'accepted';

      if not found then
        raise exception using
          errcode = '23514',
          message = 'chatbot handoff requires an active human agent from the same organization';
      end if;
    else
      select * into handoff_queue
      from public.routing_queues as queue
      where queue.organization_id = target_run.organization_id
        and queue.id = p_handoff_routing_queue_id
        and queue.status = 'active';

      if not found then
        raise exception using
          errcode = '23514',
          message = 'chatbot handoff requires an active routing queue from the same organization';
      end if;
    end if;
  elsif p_handoff_agent_id is not null
    or p_handoff_routing_queue_id is not null
  then
    raise exception using
      errcode = '23514',
      message = 'only handed-off chatbot runs may specify a handoff destination';
  end if;

  foreach outgoing_text in array coalesce(p_outgoing_texts, array[]::text[])
  loop
    if outgoing_text is null
      or length(btrim(outgoing_text)) = 0
      or length(outgoing_text) > 4096
    then
      raise exception using
        errcode = '23514',
        message = 'outgoing chatbot text must contain 1 to 4096 characters';
    end if;
  end loop;

  if jsonb_typeof(coalesce(p_outgoing_messages, '[]'::jsonb)) <> 'array' then
    raise exception using
      errcode = '23514',
      message = 'outgoing chatbot messages must be a JSON array';
  end if;

  for outgoing_message in
    select value
    from jsonb_array_elements(coalesce(p_outgoing_messages, '[]'::jsonb))
  loop
    if jsonb_typeof(outgoing_message) <> 'object'
      or outgoing_message->>'type' not in ('text', 'interactive')
      or (
        outgoing_message->>'type' = 'text'
        and (
          outgoing_message->>'text' is null
          or length(btrim(outgoing_message->>'text')) = 0
          or length(outgoing_message->>'text') > 4096
        )
      )
      or (
        outgoing_message->>'type' = 'interactive'
        and (
          jsonb_typeof(outgoing_message->'interactive') <> 'object'
          or outgoing_message->'interactive'->>'type' not in ('button', 'list')
          or outgoing_message->'interactive'->'body'->>'text' is null
          or length(btrim(outgoing_message->'interactive'->'body'->>'text')) = 0
          or jsonb_typeof(outgoing_message->'interactive'->'action') <> 'object'
        )
      )
    then
      raise exception using
        errcode = '23514',
        message = 'outgoing chatbot message has an invalid shape';
    end if;
  end loop;

  select * into target_conversation
  from public.conversations as conversation
  where conversation.id = target_run.conversation_id
  for update;

  update public.chatbot_flow_runs as run
  set
    current_node_id = p_current_node_id,
    status = p_status,
    waiting_for = p_waiting_for,
    variables = p_variables,
    lock_version = run.lock_version + 1,
    last_processed_message_id = incoming.id,
    error = p_error,
    expires_at = case
      when p_status = 'waiting' then now() + interval '1 hour'
      else null
    end,
    ended_at = case
      when p_status in ('completed', 'failed', 'handed_off') then now()
      else null
    end
  where run.id = target_run.id
  returning * into target_run;

  if p_status = 'handed_off' then
    if handoff_queue.id is not null then
      perform public.route_conversation_to_queue(
        target_run.conversation_id,
        handoff_queue.id
      );
    else
      update public.conversations as conversation
      set assigned_agent_id = handoff_agent.id
      where conversation.id = target_run.conversation_id;
    end if;
  end if;

  foreach outgoing_text in array coalesce(p_outgoing_texts, array[]::text[])
  loop
    insert into public.messages (
      organization_id,
      conversation_id,
      direction,
      agent_id,
      service,
      organization_address,
      contact_address,
      group_address,
      content
    ) values (
      target_run.organization_id,
      target_run.conversation_id,
      'outgoing'::public.direction,
      target_run.agent_id,
      target_conversation.service,
      target_conversation.organization_address,
      target_conversation.contact_address,
      target_conversation.group_address,
      jsonb_build_object(
        'version', '1',
        'type', 'text',
        'kind', 'text',
        'text', outgoing_text
      )
    )
    returning id into inserted_message_id;

    inserted_message_ids := array_append(
      inserted_message_ids,
      inserted_message_id
    );
  end loop;

  for outgoing_message in
    select value
    from jsonb_array_elements(coalesce(p_outgoing_messages, '[]'::jsonb))
  loop
    insert into public.messages (
      organization_id,
      conversation_id,
      direction,
      agent_id,
      service,
      organization_address,
      contact_address,
      group_address,
      content
    ) values (
      target_run.organization_id,
      target_run.conversation_id,
      'outgoing'::public.direction,
      target_run.agent_id,
      target_conversation.service,
      target_conversation.organization_address,
      target_conversation.contact_address,
      target_conversation.group_address,
      case outgoing_message->>'type'
        when 'text' then jsonb_build_object(
          'version', '1',
          'type', 'text',
          'kind', 'text',
          'text', outgoing_message->>'text'
        )
        else jsonb_build_object(
          'version', '1',
          'type', 'data',
          'kind', 'interactive',
          'data', outgoing_message->'interactive'
        )
      end
    )
    returning id into inserted_message_id;

    inserted_message_ids := array_append(
      inserted_message_ids,
      inserted_message_id
    );
  end loop;

  return query select
    'committed'::text,
    target_run.lock_version,
    inserted_message_ids;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_routing_queue(p_organization_id uuid, p_name text, p_agent_ids uuid[] DEFAULT ARRAY[]::uuid[])
 RETURNS public.routing_queues
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  request_role public.role;
  normalized_name text := btrim(coalesce(p_name, ''));
  created_queue public.routing_queues;
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

  if char_length(normalized_name) not between 1 and 80 then
    raise exception using
      errcode = '22023',
      message = 'routing queue name must contain between 1 and 80 characters';
  end if;

  perform public.validate_routing_queue_agent_ids(p_organization_id, p_agent_ids);

  insert into public.routing_queues (organization_id, name)
  values (p_organization_id, normalized_name)
  returning * into created_queue;

  perform public.replace_routing_queue_members(
    created_queue.organization_id,
    created_queue.id,
    p_agent_ids
  );

  return created_queue;
exception
  when unique_violation then
    raise exception using
      errcode = '23505',
      message = 'routing queue name already exists in this organization';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_conversation_queue_conversations(p_organization_id uuid, p_queue_key text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_routing_queue_id uuid DEFAULT NULL::uuid)
 RETURNS SETOF public.conversations
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  normalized_limit integer;
  normalized_offset integer;
  request_role public.role;
  current_agent_id uuid;
begin
  if p_organization_id is null then
    raise exception using
      errcode = '22004',
      message = 'organization id is required';
  end if;

  if p_queue_key is null or p_queue_key not in (
    'all_active',
    'assigned',
    'pending',
    'mentioned',
    'spam',
    'closed',
    'expired'
  ) then
    raise exception using
      errcode = '22023',
      message = 'invalid conversation queue key';
  end if;

  if not exists (
    select 1
    from public.get_authorized_orgs('agent') as authorized_orgs(id)
    where authorized_orgs.id = p_organization_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  request_role := public.get_request_organization_role(p_organization_id);
  current_agent_id := public.get_current_human_agent_id(p_organization_id);

  if p_routing_queue_id is not null
    and not exists (
      select 1
      from public.routing_queues queue
      where queue.organization_id = p_organization_id
        and queue.id = p_routing_queue_id
        and (
          request_role <> 'agent'::public.role
          or exists (
            select 1
            from public.routing_queue_members member
            where member.organization_id = queue.organization_id
              and member.routing_queue_id = queue.id
              and member.agent_id = current_agent_id
          )
        )
    )
  then
    raise exception using
      errcode = '42501',
      message = 'routing queue is not accessible to the authenticated user';
  end if;

  if request_role = 'agent'::public.role
    and p_queue_key = 'all_active'
  then
    raise exception using
      errcode = '42501',
      message = 'conversation queue is not available to Agent users';
  end if;

  normalized_limit := least(greatest(coalesce(p_limit, 50), 1), 500);
  normalized_offset := greatest(coalesce(p_offset, 0), 0);

  return query
  select c.*
  from public.conversations c
  left join lateral (
    select max(m.timestamp) as latest_incoming_at
    from public.messages m
    where m.organization_id = c.organization_id
      and m.conversation_id = c.id
      and m.direction = 'incoming'::public.direction
  ) incoming on true
  left join lateral (
    select max(mention.created_at) as latest_mention_at
    from public.message_mentions mention
    join public.messages message
      on message.organization_id = mention.organization_id
      and message.id = mention.message_id
    where mention.organization_id = c.organization_id
      and mention.mentioned_agent_id = current_agent_id
      and message.conversation_id = c.id
  ) mentioned on true
  where c.organization_id = p_organization_id
    and (
      p_queue_key = 'mentioned'
      or p_routing_queue_id is null
      or c.routing_queue_id = p_routing_queue_id
    )
    and (
      (
        p_queue_key = 'all_active'
        and c.status = 'active'
      )
      or (
        p_queue_key = 'assigned'
        and c.status = 'active'
        and c.assigned_agent_id is not null
        and (
          request_role <> 'agent'::public.role
          or c.assigned_agent_id = current_agent_id
        )
      )
      or (
        p_queue_key = 'pending'
        and c.status = 'active'
        and c.assigned_agent_id is null
      )
      or (
        p_queue_key = 'mentioned'
        and mentioned.latest_mention_at is not null
      )
      or (
        p_queue_key = 'spam'
        and c.status = 'spam'
        and (
          request_role <> 'agent'::public.role
          or c.assigned_agent_id = current_agent_id
        )
      )
      or (
        p_queue_key = 'closed'
        and c.status = 'closed'
        and (
          request_role <> 'agent'::public.role
          or c.assigned_agent_id = current_agent_id
        )
      )
      or (
        p_queue_key = 'expired'
        and c.status = 'active'
        and incoming.latest_incoming_at <= now() - interval '24 hours'
        and (
          request_role <> 'agent'::public.role
          or c.assigned_agent_id is null
          or c.assigned_agent_id = current_agent_id
        )
      )
    )
  order by
    case
      when p_queue_key = 'mentioned' then mentioned.latest_mention_at
    end desc,
    c.updated_at desc,
    c.id desc
  limit normalized_limit
  offset normalized_offset;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_routing_queue_options(p_organization_id uuid)
 RETURNS TABLE(id uuid, name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  request_role public.role;
  current_agent_id uuid;
begin
  request_role := public.get_request_organization_role(p_organization_id);
  if request_role is null then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  current_agent_id := public.get_current_human_agent_id(p_organization_id);

  return query
  select queue.id, queue.name
  from public.routing_queues queue
  where queue.organization_id = p_organization_id
    and queue.status = 'active'
    and (
      request_role <> 'agent'::public.role
      or exists (
        select 1
        from public.routing_queue_members member
        where member.organization_id = queue.organization_id
          and member.routing_queue_id = queue.id
          and member.agent_id = current_agent_id
      )
    )
  order by queue.name asc, queue.id asc;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_routing_queues_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, organization_id uuid, name text, status text, member_ids uuid[], member_count bigint, created_at timestamp with time zone, updated_at timestamp with time zone, total_count bigint)
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
    coalesce(members.member_ids, array[]::uuid[]),
    coalesce(members.member_count, 0),
    queue.created_at,
    queue.updated_at,
    count(*) over() as total_count
  from filtered queue
  left join lateral (
    select
      array_agg(member.agent_id order by member.agent_id) as member_ids,
      count(*) as member_count
    from public.routing_queue_members member
    where member.organization_id = queue.organization_id
      and member.routing_queue_id = queue.id
  ) members on true
  order by queue.name asc, queue.id asc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.replace_routing_queue_members(p_organization_id uuid, p_routing_queue_id uuid, p_agent_ids uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  normalized_ids uuid[];
begin
  normalized_ids := public.validate_routing_queue_agent_ids(
    p_organization_id,
    p_agent_ids
  );

  delete from public.routing_queue_members member
  where member.organization_id = p_organization_id
    and member.routing_queue_id = p_routing_queue_id
    and member.agent_id <> all(normalized_ids);

  insert into public.routing_queue_members (
    organization_id,
    routing_queue_id,
    agent_id
  )
  select p_organization_id, p_routing_queue_id, agent_id
  from unnest(normalized_ids) as requested(agent_id)
  on conflict do nothing;
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

  if not exists (
    select 1
    from public.routing_queues queue
    where queue.id = p_routing_queue_id
      and queue.organization_id = target_conversation.organization_id
      and queue.status = 'active'
  ) then
    raise exception using
      errcode = '23514',
      message = 'routing destination must be an active queue in the same organization';
  end if;

  update public.conversations conversation
  set routing_queue_id = p_routing_queue_id,
      routed_at = now(),
      assigned_agent_id = null
  where conversation.id = p_conversation_id
  returning * into target_conversation;

  return target_conversation;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_routing_queue(p_routing_queue_id uuid, p_name text, p_status text, p_agent_ids uuid[] DEFAULT ARRAY[]::uuid[])
 RETURNS public.routing_queues
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  existing_queue public.routing_queues;
  request_role public.role;
  normalized_name text := btrim(coalesce(p_name, ''));
  updated_queue public.routing_queues;
begin
  select queue.* into existing_queue
  from public.routing_queues queue
  where queue.id = p_routing_queue_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'routing queue not found';
  end if;

  request_role := public.get_request_organization_role(existing_queue.organization_id);
  if request_role not in (
    'owner'::public.role,
    'admin'::public.role,
    'supervisor'::public.role
  ) then
    raise exception using
      errcode = '42501',
      message = 'owner, admin, or supervisor role required to manage routing queues';
  end if;

  if char_length(normalized_name) not between 1 and 80 then
    raise exception using
      errcode = '22023',
      message = 'routing queue name must contain between 1 and 80 characters';
  end if;

  if p_status not in ('active', 'archived') then
    raise exception using
      errcode = '22023',
      message = 'routing queue status must be active or archived';
  end if;

  perform public.validate_routing_queue_agent_ids(
    existing_queue.organization_id,
    p_agent_ids
  );

  update public.routing_queues queue
  set name = normalized_name,
      status = p_status
  where queue.id = p_routing_queue_id
  returning * into updated_queue;

  perform public.replace_routing_queue_members(
    updated_queue.organization_id,
    updated_queue.id,
    p_agent_ids
  );

  return updated_queue;
exception
  when unique_violation then
    raise exception using
      errcode = '23505',
      message = 'routing queue name already exists in this organization';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.validate_routing_queue_agent_ids(p_organization_id uuid, p_agent_ids uuid[])
 RETURNS uuid[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  normalized_ids uuid[];
begin
  select coalesce(array_agg(distinct agent_id order by agent_id), array[]::uuid[])
  into normalized_ids
  from unnest(coalesce(p_agent_ids, array[]::uuid[])) as requested(agent_id)
  where agent_id is not null;

  if exists (
    select 1
    from unnest(normalized_ids) as requested(agent_id)
    where not exists (
      select 1
      from public.agents agent
      where agent.organization_id = p_organization_id
        and agent.id = requested.agent_id
        and agent.ai = false
        and agent.user_id is not null
        and agent.extra->>'role' = 'agent'
        and coalesce(agent.extra->'invitation'->>'status', 'accepted') = 'accepted'
    )
  ) then
    raise exception using
      errcode = '22023',
      message = 'routing queue members must be accepted human Agents in the same organization';
  end if;

  return normalized_ids;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.agent_can_read_conversation(p_organization_id uuid, p_conversation_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select public.get_request_organization_role(p_organization_id) = 'agent'::public.role
    and exists (
      select 1
      from public.conversations c
      where c.id = p_conversation_id
        and c.organization_id = p_organization_id
        and (
          (
            c.status = 'active'
            and (
              c.assigned_agent_id = public.get_current_human_agent_id(p_organization_id)
              or (
                c.assigned_agent_id is null
                and (
                  c.routing_queue_id is null
                  or exists (
                    select 1
                    from public.routing_queue_members queue_member
                    where queue_member.organization_id = c.organization_id
                      and queue_member.routing_queue_id = c.routing_queue_id
                      and queue_member.agent_id = public.get_current_human_agent_id(
                        p_organization_id
                      )
                  )
                )
              )
            )
          )
          or (
            c.status in ('spam', 'closed')
            and c.assigned_agent_id = public.get_current_human_agent_id(p_organization_id)
          )
          or exists (
            select 1
            from public.message_mentions mention
            join public.messages message
              on message.organization_id = mention.organization_id
              and message.id = mention.message_id
            where mention.organization_id = p_organization_id
              and mention.mentioned_agent_id = public.get_current_human_agent_id(
                p_organization_id
              )
              and message.conversation_id = p_conversation_id
          )
        )
    );
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

CREATE OR REPLACE FUNCTION public.broadcast_conversation_queue_state()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform realtime.send(
    jsonb_build_object(
      'organization_id', new.organization_id,
      'conversation_id', new.id,
      'assigned_agent_id', new.assigned_agent_id,
      'routing_queue_id', new.routing_queue_id,
      'routed_at', new.routed_at,
      'status', new.status,
      'updated_at', new.updated_at
    ),
    'conversation_state_changed',
    'conversation-queue:' || new.organization_id::text,
    true
  );

  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.enforce_human_conversation_assignee()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if new.assigned_agent_id is null then
    return new;
  end if;

  if not exists (
    select 1
    from public.agents
    where id = new.assigned_agent_id
      and organization_id = new.organization_id
      and ai = false
      and user_id is not null
  ) then
    raise exception 'Conversation assignee must be a human agent in the same organization'
      using errcode = '23514';
  end if;

  if new.routing_queue_id is not null
    and not exists (
      select 1
      from public.routing_queue_members member
      where member.organization_id = new.organization_id
        and member.routing_queue_id = new.routing_queue_id
        and member.agent_id = new.assigned_agent_id
    )
  then
    raise exception 'Conversation assignee must belong to its routing queue'
      using errcode = '23514';
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_mentioned_conversations_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 25, p_search text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, id uuid, service public.service, organization_address text, contact_address text, group_address text, name text, assigned_agent_id uuid, routing_queue_id uuid, routed_at timestamp with time zone, extra jsonb, status text, created_at timestamp with time zone, updated_at timestamp with time zone, preview_message jsonb, latest_mention_at timestamp with time zone, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  current_agent_id uuid;
  normalized_page integer;
  normalized_page_size integer;
  normalized_search text;
begin
  if not exists (
    select 1
    from public.get_authorized_orgs('agent') as authorized_orgs(id)
    where authorized_orgs.id = p_organization_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  current_agent_id := public.get_current_human_agent_id(p_organization_id);
  if current_agent_id is null then
    raise exception using
      errcode = '42501',
      message = 'accepted human membership is required';
  end if;

  normalized_page := greatest(coalesce(p_page, 1), 1);
  normalized_page_size := least(greatest(coalesce(p_page_size, 25), 1), 50);
  normalized_search := lower(btrim(coalesce(p_search, '')));

  return query
  with latest_mentions as materialized (
    select
      message.conversation_id,
      max(mention.created_at) as latest_mention_at
    from public.message_mentions mention
    join public.messages message
      on message.organization_id = mention.organization_id
      and message.id = mention.message_id
    where mention.organization_id = p_organization_id
      and mention.mentioned_agent_id = current_agent_id
    group by message.conversation_id
  )
  select
    conversation.organization_id,
    conversation.id,
    conversation.service,
    conversation.organization_address,
    conversation.contact_address,
    conversation.group_address,
    conversation.name,
    conversation.assigned_agent_id,
    conversation.routing_queue_id,
    conversation.routed_at,
    conversation.extra,
    conversation.status,
    conversation.created_at,
    conversation.updated_at,
    preview.message,
    mention.latest_mention_at,
    count(*) over() as total_count
  from latest_mentions mention
  join public.conversations conversation
    on conversation.organization_id = p_organization_id
    and conversation.id = mention.conversation_id
  left join lateral (
    select to_jsonb(message) as message
    from public.messages message
    where message.organization_id = conversation.organization_id
      and message.conversation_id = conversation.id
      and message.direction in (
        'incoming'::public.direction,
        'outgoing'::public.direction
      )
    order by message.timestamp desc, message.id desc
    limit 1
  ) preview on true
  where normalized_search = ''
    or lower(coalesce(conversation.name, '')) like '%' || normalized_search || '%'
    or lower(coalesce(conversation.contact_address, '')) like '%' || normalized_search || '%'
    or lower(coalesce(conversation.group_address, '')) like '%' || normalized_search || '%'
    or lower(conversation.organization_address) like '%' || normalized_search || '%'
  order by mention.latest_mention_at desc, conversation.id desc
  offset (normalized_page - 1) * normalized_page_size
  limit normalized_page_size;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.manage_contact_on_first_inbound()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  created_contact_id uuid;
  contact_name text;
begin
  -- A Meta user_id_update marks the old address with replaced_by_bsuid.
  -- Reuse that Contact before deciding this is a genuinely new customer.
  if nullif(btrim(new.extra->>'bsuid'), '') is not null then
    select address.contact_id
    into created_contact_id
    from public.contacts_addresses as address
    where address.organization_id = new.organization_id
      and address.service = 'whatsapp'::public.service
      and address.address <> new.address
      and address.contact_id is not null
      and address.extra->>'replaced_by_bsuid' = new.extra->>'bsuid'
    order by address.updated_at desc
    limit 1;
  end if;

  if created_contact_id is null then
    contact_name := coalesce(
      nullif(btrim(new.extra->>'name'), ''),
      nullif(btrim(new.extra->>'username'), ''),
      nullif(btrim(new.extra->>'phone_number'), ''),
      new.address
    );

    insert into public.contacts (organization_id, name)
    values (new.organization_id, contact_name)
    returning id into created_contact_id;
  end if;

  if tg_op = 'UPDATE' then
    new.contact_id := created_contact_id;
    return new;
  end if;

  update public.contacts_addresses
  set contact_id = created_contact_id
  where organization_id = new.organization_id
    and address = new.address
    and contact_id is null;

  return new;
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

  return target_conversation;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.transfer_conversation_with_private_note(p_conversation_id uuid, p_target_agent_id uuid, p_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  conversation_row public.conversations;
  updated_conversation public.conversations;
  author_agent_id uuid;
  request_role public.role;
  normalized_text text;
  note public.messages;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'authentication required';
  end if;

  normalized_text := btrim(coalesce(p_text, ''));
  if normalized_text = '' then
    raise exception using
      errcode = '22023',
      message = 'transfer note text is required';
  end if;

  select c.*
  into conversation_row
  from public.conversations c
  where c.id = p_conversation_id
  for update;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'conversation is not accessible to the authenticated user';
  end if;

  request_role := public.get_request_organization_role(
    conversation_row.organization_id
  );
  author_agent_id := public.get_current_human_agent_id(
    conversation_row.organization_id
  );

  if request_role is distinct from 'agent'::public.role
    or author_agent_id is null
  then
    raise exception using
      errcode = '42501',
      message = 'only the assigned Agent can transfer this conversation';
  end if;

  if conversation_row.status <> 'active' then
    raise exception using
      errcode = '22023',
      message = 'only active conversations can be transferred';
  end if;

  if conversation_row.assigned_agent_id is distinct from author_agent_id then
    raise exception using
      errcode = '42501',
      message = 'conversation is not assigned to the authenticated Agent';
  end if;

  if p_target_agent_id is null or p_target_agent_id = author_agent_id then
    raise exception using
      errcode = '22023',
      message = 'transfer target must be another accepted Agent';
  end if;

  if not exists (
    select 1
    from public.agents target
    where target.id = p_target_agent_id
      and target.organization_id = conversation_row.organization_id
      and target.ai = false
      and target.user_id is not null
      and target.extra->>'role' = 'agent'
      and (
        target.extra->'invitation' is null
        or target.extra->'invitation'->>'status' = 'accepted'
      )
  ) then
    raise exception using
      errcode = '22023',
      message = 'transfer target must be another accepted Agent';
  end if;

  if conversation_row.routing_queue_id is not null
    and not exists (
      select 1
      from public.routing_queue_members member
      where member.organization_id = conversation_row.organization_id
        and member.routing_queue_id = conversation_row.routing_queue_id
        and member.agent_id = p_target_agent_id
    )
  then
    raise exception using
      errcode = '22023',
      message = 'transfer target must belong to the conversation routing queue';
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
      'mentioned_agent_ids', jsonb_build_array(p_target_agent_id),
      'transfer', jsonb_build_object(
        'from_agent_id', author_agent_id,
        'to_agent_id', p_target_agent_id
      )
    ),
    '{}'::jsonb
  )
  returning * into note;

  insert into public.message_mentions (
    organization_id,
    message_id,
    mentioned_agent_id,
    created_at
  ) values (
    note.organization_id,
    note.id,
    p_target_agent_id,
    note.created_at
  );

  update public.conversations c
  set assigned_agent_id = p_target_agent_id
  where c.id = conversation_row.id
    and c.status = 'active'
    and c.assigned_agent_id = author_agent_id
  returning c.* into updated_conversation;

  if not found then
    raise exception using
      errcode = '23505',
      message = 'conversation assignment changed before transfer completed';
  end if;

  return jsonb_build_object(
    'conversation', to_jsonb(updated_conversation),
    'note', to_jsonb(note)
  );
end;
$function$
;

grant references on table "public"."routing_queue_members" to "anon";

grant trigger on table "public"."routing_queue_members" to "anon";

grant truncate on table "public"."routing_queue_members" to "anon";

grant references on table "public"."routing_queue_members" to "authenticated";

grant trigger on table "public"."routing_queue_members" to "authenticated";

grant truncate on table "public"."routing_queue_members" to "authenticated";

grant references on table "public"."routing_queue_members" to "service_role";

grant trigger on table "public"."routing_queue_members" to "service_role";

grant truncate on table "public"."routing_queue_members" to "service_role";

grant references on table "public"."routing_queues" to "anon";

grant trigger on table "public"."routing_queues" to "anon";

grant truncate on table "public"."routing_queues" to "anon";

grant references on table "public"."routing_queues" to "authenticated";

grant trigger on table "public"."routing_queues" to "authenticated";

grant truncate on table "public"."routing_queues" to "authenticated";

grant references on table "public"."routing_queues" to "service_role";

grant trigger on table "public"."routing_queues" to "service_role";

grant truncate on table "public"."routing_queues" to "service_role";


  create policy "agents can read their routing queue memberships"
  on "public"."routing_queue_members"
  as permissive
  for select
  to authenticated
using (((public.get_request_organization_role(organization_id) = 'agent'::public.role) AND (agent_id = public.get_current_human_agent_id(organization_id))));



  create policy "managers can read organization routing queue members"
  on "public"."routing_queue_members"
  as permissive
  for select
  to authenticated
using ((public.get_request_organization_role(organization_id) = ANY (ARRAY['owner'::public.role, 'admin'::public.role, 'supervisor'::public.role])));



  create policy "agents can read their active routing queues"
  on "public"."routing_queues"
  as permissive
  for select
  to authenticated
using (((status = 'active'::text) AND (public.get_request_organization_role(organization_id) = 'agent'::public.role) AND (EXISTS ( SELECT 1
   FROM public.routing_queue_members member
  WHERE ((member.organization_id = routing_queues.organization_id) AND (member.routing_queue_id = routing_queues.id) AND (member.agent_id = public.get_current_human_agent_id(member.organization_id)))))));



  create policy "managers can read organization routing queues"
  on "public"."routing_queues"
  as permissive
  for select
  to authenticated
using ((public.get_request_organization_role(organization_id) = ANY (ARRAY['owner'::public.role, 'admin'::public.role, 'supervisor'::public.role])));



  create policy "agents can update assigned conversations"
  on "public"."conversations"
  as permissive
  for update
  to authenticated
using (public.agent_owns_conversation(organization_id, id))
with check (((public.get_request_organization_role(organization_id) = 'agent'::public.role) AND public.agent_conversation_update_rules(id, organization_id, service, organization_address, contact_address, group_address, assigned_agent_id, routing_queue_id, routed_at)));


CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.routing_queues FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');

CREATE TRIGGER broadcast_conversation_queue_state_trigger AFTER UPDATE OF assigned_agent_id, routing_queue_id, status ON public.conversations FOR EACH ROW WHEN (((old.assigned_agent_id IS DISTINCT FROM new.assigned_agent_id) OR (old.routing_queue_id IS DISTINCT FROM new.routing_queue_id) OR (old.status IS DISTINCT FROM new.status))) EXECUTE FUNCTION public.broadcast_conversation_queue_state();

CREATE TRIGGER enforce_human_conversation_assignee BEFORE INSERT OR UPDATE OF assigned_agent_id, routing_queue_id, organization_id ON public.conversations FOR EACH ROW EXECUTE FUNCTION public.enforce_human_conversation_assignee();

revoke execute on function public.validate_routing_queue_agent_ids(uuid, uuid[]) from public;
revoke execute on function public.replace_routing_queue_members(uuid, uuid, uuid[]) from public;
revoke execute on function public.route_conversation_to_queue(uuid, uuid) from public;
revoke execute on function public.list_routing_queues_page(uuid, integer, integer, text) from public;
revoke execute on function public.list_routing_queue_options(uuid) from public;
revoke execute on function public.create_routing_queue(uuid, text, uuid[]) from public;
revoke execute on function public.update_routing_queue(uuid, text, text, uuid[]) from public;

grant execute on function public.list_routing_queues_page(uuid, integer, integer, text) to authenticated;
grant execute on function public.list_routing_queue_options(uuid) to authenticated;
grant execute on function public.create_routing_queue(uuid, text, uuid[]) to authenticated;
grant execute on function public.update_routing_queue(uuid, text, text, uuid[]) to authenticated;

revoke execute on function public.commit_chatbot_flow_execution(uuid, bigint, uuid, text, text, text, jsonb, jsonb, text[], jsonb, uuid, uuid) from public, anon, authenticated;
grant execute on function public.commit_chatbot_flow_execution(uuid, bigint, uuid, text, text, text, jsonb, jsonb, text[], jsonb, uuid, uuid) to service_role;

revoke execute on function public.list_mentioned_conversations_page(uuid, integer, integer, text) from public;
grant execute on function public.list_mentioned_conversations_page(uuid, integer, integer, text) to authenticated;

revoke execute on function public.get_conversation_queue_conversations(uuid, text, integer, integer, uuid) from public;
grant execute on function public.get_conversation_queue_conversations(uuid, text, integer, integer, uuid) to authenticated;

