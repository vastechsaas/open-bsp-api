create function public.protect_published_chatbot_flow_version() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status = 'published' then
    raise exception using
      errcode = '23514',
      message = 'published chatbot flow versions are immutable';
  end if;

  return new;
end;
$$;

create trigger protect_published_chatbot_flow_version
before update
on public.chatbot_flow_versions
for each row
execute function public.protect_published_chatbot_flow_version();

create function public.validate_chatbot_flow_run() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  version_status text;
  agent_is_ai boolean;
  conversation_organization_id uuid;
  message_conversation_id uuid;
  message_direction public.direction;
begin
  if tg_op = 'UPDATE' and (
    new.organization_id <> old.organization_id
    or new.conversation_id <> old.conversation_id
    or new.flow_version_id <> old.flow_version_id
    or new.agent_id <> old.agent_id
  ) then
    raise exception using
      errcode = '23514',
      message = 'chatbot flow run identity is immutable';
  end if;

  select version.status
  into version_status
  from public.chatbot_flow_versions as version
  where version.organization_id = new.organization_id
    and version.id = new.flow_version_id;

  if version_status is distinct from 'published' then
    raise exception using
      errcode = '23514',
      message = 'chatbot flow runs require a published flow version';
  end if;

  select agent.ai
  into agent_is_ai
  from public.agents as agent
  where agent.organization_id = new.organization_id
    and agent.id = new.agent_id;

  if agent_is_ai is distinct from true then
    raise exception using
      errcode = '23514',
      message = 'chatbot flow runs require an AI agent from the same organization';
  end if;

  select conversation.organization_id
  into conversation_organization_id
  from public.conversations as conversation
  where conversation.id = new.conversation_id;

  if conversation_organization_id is distinct from new.organization_id then
    raise exception using
      errcode = '23514',
      message = 'chatbot flow run conversation must belong to the same organization';
  end if;

  if new.last_processed_message_id is not null then
    select message.conversation_id, message.direction
    into message_conversation_id, message_direction
    from public.messages as message
    where message.id = new.last_processed_message_id;

    if message_conversation_id is distinct from new.conversation_id then
      raise exception using
        errcode = '23514',
        message = 'last processed message must belong to the chatbot flow run conversation';
    end if;

    if message_direction is distinct from 'incoming'::public.direction then
      raise exception using
        errcode = '23514',
        message = 'last processed message must be incoming';
    end if;
  end if;

  return new;
end;
$$;

create trigger validate_chatbot_flow_run
before insert or update
on public.chatbot_flow_runs
for each row
execute function public.validate_chatbot_flow_run();

create function public.prepare_chatbot_flow_execution(
  p_message_id uuid,
  p_flow_version_id uuid default null,
  p_agent_id uuid default null
) returns table (
  outcome text,
  run_id uuid,
  run_lock_version bigint,
  run_is_new boolean,
  run_status text,
  run_current_node_id text,
  run_waiting_for text,
  run_variables jsonb,
  flow_definition jsonb
)
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  incoming public.messages;
  active_run public.chatbot_flow_runs;
  target_version public.chatbot_flow_versions;
  target_agent public.agents;
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

  perform 1
  from public.conversations as conversation
  where conversation.id = incoming.conversation_id
  for update;

  select * into active_run
  from public.chatbot_flow_runs as run
  where run.conversation_id = incoming.conversation_id
    and run.status in ('running', 'waiting')
  for update;

  has_active_run := found;

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
$$;

revoke execute on function public.prepare_chatbot_flow_execution(
  uuid,
  uuid,
  uuid
) from public, anon, authenticated;
grant execute on function public.prepare_chatbot_flow_execution(
  uuid,
  uuid,
  uuid
) to service_role;

create function public.commit_chatbot_flow_execution(
  p_run_id uuid,
  p_expected_lock_version bigint,
  p_message_id uuid,
  p_current_node_id text,
  p_status text,
  p_waiting_for text,
  p_variables jsonb,
  p_error jsonb,
  p_outgoing_texts text[]
) returns table (
  outcome text,
  run_lock_version bigint,
  message_ids uuid[]
)
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  target_run public.chatbot_flow_runs;
  incoming public.messages;
  previous_message public.messages;
  target_conversation public.conversations;
  outgoing_text text;
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

  if p_status not in ('waiting', 'completed', 'failed') then
    raise exception using
      errcode = '23514',
      message = 'chatbot execution can commit only waiting, completed, or failed';
  end if;

  if jsonb_typeof(p_variables) is distinct from 'object' then
    raise exception using
      errcode = '23514',
      message = 'committed chatbot variables must be a JSON object';
  end if;

  if p_status = 'waiting' and p_waiting_for is distinct from 'free_text' then
    raise exception using
      errcode = '23514',
      message = 'MVP waiting runs must wait for free text';
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

  select * into target_conversation
  from public.conversations as conversation
  where conversation.id = target_run.conversation_id;

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
      when p_status in ('completed', 'failed') then now()
      else null
    end
  where run.id = target_run.id
  returning * into target_run;

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

  return query select
    'committed'::text,
    target_run.lock_version,
    inserted_message_ids;
end;
$$;

revoke execute on function public.commit_chatbot_flow_execution(
  uuid,
  bigint,
  uuid,
  text,
  text,
  text,
  jsonb,
  jsonb,
  text[]
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
  text[]
) to service_role;
