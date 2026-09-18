set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.complete_node_chatbot_operation(p_request_id uuid, p_phase text, p_result jsonb)
 RETURNS public.chatbot_node_operations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  operation public.chatbot_node_operations;
begin
  select * into operation from public.chatbot_node_operations where request_id = p_request_id for update;
  if not found then raise exception 'operation not found' using errcode = 'P0002'; end if;
  if operation.phase <> p_phase or operation.status = 'succeeded' then return operation; end if;
  if operation.status not in ('in_flight', 'reconciling') then raise exception 'operation is not outstanding' using errcode = '23514'; end if;
  if p_phase = 'prepare' then
    if p_result->>'flow_id' is null or p_result->>'version_id' is null then raise exception 'invalid remote version' using errcode = '23514'; end if;
    update public.chatbot_node_operations set phase = 'activate', status = 'pending', attempts = 0,
      result = p_result, next_attempt_at = null, last_error = null where request_id = p_request_id returning * into operation;
    return operation;
  end if;
  update public.chatbot_node_operations set status = 'succeeded', result = p_result,
    next_attempt_at = null, last_error = null where request_id = p_request_id returning * into operation;
  update public.chatbot_node_bridges set
    engine = case when p_phase = 'deactivate' or (p_phase = 'restore' and p_result->>'enabled' = 'false') then 'disabled' else 'node' end,
    sync_status = case when p_phase = 'deactivate' or (p_phase = 'restore' and p_result->>'enabled' = 'false') then 'disabled' when p_phase = 'suspend' then 'suspended' else 'active' end,
    node_flow_id = case when p_phase = 'activate' then p_result->>'flow_id' else node_flow_id end,
    node_version_id = case when p_phase = 'activate' then p_result->>'version_id' else node_version_id end,
    flow_id = case when p_phase = 'activate' then (operation.payload->>'source_flow_id')::uuid else flow_id end,
    flow_version_id = case when p_phase = 'activate' then (operation.payload->>'source_version_id')::uuid else flow_version_id end,
    definition_hash = case when p_phase = 'activate' then operation.payload->>'definition_hash' else definition_hash end,
    last_error = null, updated_at = now()
    where organization_id = operation.organization_id and organization_address = operation.organization_address;
  if p_phase = 'resume' then
    update public.chatbot_node_conversations set human_owned = false where organization_id = operation.organization_id
      and organization_address = operation.organization_address and node_conversation_id = operation.payload->>'node_conversation_id';
  end if;
  return operation;
end;
$function$
;

-- Cron is deliberately managed in migrations, not the declarative schema diff.
select cron.schedule(
  'node-chatbot-bridge-every-minute', '* * * * *',
  $$select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'edge_functions_url') || '/node-chatbot-bridge-worker',
    headers := jsonb_build_object('content-type', 'application/json',
      'authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'edge_functions_token')),
    body := '{}'::jsonb, timeout_milliseconds := 1000
  )$$
);

