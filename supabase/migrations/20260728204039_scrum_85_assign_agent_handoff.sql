drop function if exists "public"."commit_chatbot_flow_execution"(p_run_id uuid, p_expected_lock_version bigint, p_message_id uuid, p_current_node_id text, p_status text, p_waiting_for text, p_variables jsonb, p_error jsonb, p_outgoing_texts text[], p_outgoing_messages jsonb);

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.commit_chatbot_flow_execution(p_run_id uuid, p_expected_lock_version bigint, p_message_id uuid, p_current_node_id text, p_status text, p_waiting_for text, p_variables jsonb, p_error jsonb, p_outgoing_texts text[], p_outgoing_messages jsonb DEFAULT '[]'::jsonb, p_handoff_agent_id uuid DEFAULT NULL::uuid)
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
  elsif p_handoff_agent_id is not null then
    raise exception using
      errcode = '23514',
      message = 'only handed-off chatbot runs may specify a handoff agent';
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
    update public.conversations as conversation
    set assigned_agent_id = handoff_agent.id
    where conversation.id = target_run.conversation_id;
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

CREATE OR REPLACE FUNCTION public.prepare_chatbot_flow_execution(p_message_id uuid, p_flow_version_id uuid DEFAULT NULL::uuid, p_agent_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(outcome text, run_id uuid, run_lock_version bigint, run_is_new boolean, run_status text, run_current_node_id text, run_waiting_for text, run_variables jsonb, flow_definition jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  incoming public.messages;
  active_run public.chatbot_flow_runs;
  target_version public.chatbot_flow_versions;
  target_agent public.agents;
  target_conversation public.conversations;
  previous_message public.messages;
  has_active_run boolean := false;
begin
  select * into incoming
  from public.messages as message
  where message.id = p_message_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'incoming chatbot message not found';
  end if;

  if incoming.direction <> 'incoming'::public.direction then
    raise exception using
      errcode = '23514',
      message = 'chatbot execution requires an incoming message';
  end if;

  select * into target_conversation
  from public.conversations as conversation
  where conversation.id = incoming.conversation_id
  for update;

  select * into active_run
  from public.chatbot_flow_runs as run
  where run.conversation_id = incoming.conversation_id
    and run.status in ('running', 'waiting')
  for update;

  has_active_run := found;

  if target_conversation.assigned_agent_id is not null then
    if has_active_run then
      update public.chatbot_flow_runs as run
      set
        status = 'handed_off',
        waiting_for = null,
        expires_at = null,
        ended_at = now()
      where run.id = active_run.id;
    end if;

    return query select
      'not_started'::text,
      null::uuid,
      null::bigint,
      false,
      null::text,
      null::text,
      null::text,
      null::jsonb,
      null::jsonb;
    return;
  end if;

  if has_active_run
    and active_run.status = 'waiting'
    and active_run.expires_at is not null
    and active_run.expires_at <= now()
  then
    update public.chatbot_flow_runs as run
    set
      status = 'expired',
      waiting_for = null,
      expires_at = null,
      ended_at = now()
    where run.id = active_run.id;

    has_active_run := false;
  end if;

  if has_active_run then
    if active_run.last_processed_message_id = incoming.id then
      return query select
        'duplicate'::text,
        active_run.id,
        active_run.lock_version,
        false,
        active_run.status,
        active_run.current_node_id,
        active_run.waiting_for,
        active_run.variables,
        null::jsonb;
      return;
    end if;

    if active_run.last_processed_message_id is not null then
      select * into previous_message
      from public.messages as message
      where message.id = active_run.last_processed_message_id;

      if found and (
        previous_message.created_at > incoming.created_at
        or (
          previous_message.created_at = incoming.created_at
          and previous_message.id >= incoming.id
        )
      ) then
        return query select
          'stale'::text,
          active_run.id,
          active_run.lock_version,
          false,
          active_run.status,
          active_run.current_node_id,
          active_run.waiting_for,
          active_run.variables,
          null::jsonb;
        return;
      end if;
    end if;

    select * into target_version
    from public.chatbot_flow_versions as version
    where version.id = active_run.flow_version_id;

    return query select
      'ready'::text,
      active_run.id,
      active_run.lock_version,
      false,
      active_run.status,
      active_run.current_node_id,
      active_run.waiting_for,
      active_run.variables,
      target_version.definition;
    return;
  end if;

  if p_flow_version_id is null or p_agent_id is null then
    return query select
      'not_started'::text,
      null::uuid,
      null::bigint,
      false,
      null::text,
      null::text,
      null::text,
      null::jsonb,
      null::jsonb;
    return;
  end if;

  select * into target_version
  from public.chatbot_flow_versions as version
  where version.id = p_flow_version_id
    and version.organization_id = incoming.organization_id
    and version.status = 'published';

  if not found then
    raise exception using
      errcode = '23514',
      message = 'chatbot execution requires a published flow version from the same organization';
  end if;

  select * into target_agent
  from public.agents as agent
  where agent.id = p_agent_id
    and agent.organization_id = incoming.organization_id
    and agent.ai = true;

  if not found then
    raise exception using
      errcode = '23514',
      message = 'chatbot execution requires an AI agent from the same organization';
  end if;

  insert into public.chatbot_flow_runs (
    organization_id,
    conversation_id,
    flow_version_id,
    agent_id,
    current_node_id
  ) values (
    incoming.organization_id,
    incoming.conversation_id,
    target_version.id,
    target_agent.id,
    target_version.definition->>'start_node_id'
  )
  returning * into active_run;

  return query select
    'ready'::text,
    active_run.id,
    active_run.lock_version,
    true,
    active_run.status,
    active_run.current_node_id,
    active_run.waiting_for,
    active_run.variables,
    target_version.definition;
end;
$function$
;

revoke execute on function public.commit_chatbot_flow_execution(
  uuid,
  bigint,
  uuid,
  text,
  text,
  text,
  jsonb,
  jsonb,
  text[],
  jsonb,
  uuid
) from public, anon, authenticated;

grant execute on function public.commit_chatbot_flow_execution(
  uuid,
  bigint,
  uuid,
  text,
  text,
  text,
  jsonb,
  jsonb,
  text[],
  jsonb,
  uuid
) to service_role;

