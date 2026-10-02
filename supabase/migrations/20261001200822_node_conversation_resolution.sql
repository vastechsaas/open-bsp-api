drop policy "tenant_bridge_conversation_read" on "public"."chatbot_node_conversations";

alter table "public"."chatbot_node_operations" drop constraint "chatbot_node_operations_action_check";

drop function if exists "public"."record_node_chatbot_handoff"(p_organization_id uuid, p_organization_address text, p_recipient text, p_source_wamid text, p_node_conversation_id text, p_event_id uuid, p_agent_id uuid, p_routing_queue_id uuid);

alter table "public"."chatbot_node_conversations" add column "closed_at" timestamp with time zone;

alter table "public"."chatbot_node_conversations" add column "last_inbound_wamid" text;

alter table "public"."chatbot_node_conversations" add column "lifecycle_enabled" boolean not null default false;

alter table "public"."chatbot_node_conversations" add column "ownership_revision" text not null default '0'::text;

alter table "public"."chatbot_node_conversations" add column "pending_request_id" uuid;

alter table "public"."chatbot_node_conversations" add column "resolved_by" uuid;

alter table "public"."chatbot_node_conversations" add column "state" text not null default 'human_owned'::text;

alter table "public"."chatbot_node_operations" add column "conversation_id" uuid;

alter table "public"."chatbot_node_conversations" add constraint "chatbot_node_conversations_ownership_revision_check" CHECK ((ownership_revision ~ '^[0-9]+$'::text)) not valid;

alter table "public"."chatbot_node_conversations" validate constraint "chatbot_node_conversations_ownership_revision_check";

alter table "public"."chatbot_node_conversations" add constraint "chatbot_node_conversations_state_check" CHECK ((state = ANY (ARRAY['human_owned'::text, 'closed'::text, 'bot_ready'::text, 'bot_active'::text]))) not valid;

alter table "public"."chatbot_node_conversations" validate constraint "chatbot_node_conversations_state_check";

alter table "public"."chatbot_node_operations" add constraint "chatbot_node_operations_conversation_id_fkey" FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE not valid;

alter table "public"."chatbot_node_operations" validate constraint "chatbot_node_operations_conversation_id_fkey";

alter table "public"."chatbot_node_operations" add constraint "chatbot_node_operations_action_check" CHECK ((action = ANY (ARRAY['activate'::text, 'deactivate'::text, 'suspend'::text, 'restore'::text, 'resume'::text, 'resolve-and-close'::text]))) not valid;

alter table "public"."chatbot_node_operations" validate constraint "chatbot_node_operations_action_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.apply_node_conversation_lifecycle(p_organization_id uuid, p_address text, p_node_conversation_id text, p_recipient text, p_revision text, p_state text, p_last_inbound_wamid text, p_source_wamid text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  mapping public.chatbot_node_conversations;
  target public.conversations;
  operation public.chatbot_node_operations;
begin
  if p_revision !~ '^[0-9]+$' or p_state not in ('human_owned','closed','bot_ready','bot_active') then
    raise exception 'invalid conversation lifecycle' using errcode = '22023';
  end if;
  if not public.is_organization_active(p_organization_id) then
    raise exception 'organization is archived' using errcode = '42501';
  end if;
  if not public.is_node_managed_number(p_organization_id, p_address) then
    raise exception 'number is not managed by Node' using errcode = '23514';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_organization_id::text || ':' || p_address || ':' || p_recipient, 123));
  select * into mapping from public.chatbot_node_conversations where organization_id = p_organization_id
    and organization_address = p_address and node_conversation_id = p_node_conversation_id;
  if found then
    select * into target from public.conversations where organization_id = p_organization_id and id = mapping.conversation_id for update;
  else
    select c.* into target from public.conversations c join public.messages m on m.conversation_id = c.id
      where c.organization_id = p_organization_id and c.organization_address = p_address and c.contact_address = p_recipient
        and m.organization_id = p_organization_id and m.direction = 'incoming' and m.external_id = coalesce(p_source_wamid, p_last_inbound_wamid)
      for update of c;
    if not found then raise exception 'customer message has not arrived' using errcode = '40001'; end if;
    insert into public.chatbot_node_conversations(organization_id, organization_address, node_conversation_id, conversation_id)
      values(p_organization_id, p_address, p_node_conversation_id, target.id) returning * into mapping;
  end if;
  if target.contact_address is distinct from p_recipient then raise exception 'conversation mapping mismatch' using errcode = '23514'; end if;
  if p_revision::numeric <= mapping.ownership_revision::numeric and mapping.lifecycle_enabled then return target.id; end if;
  -- Reopen and handoff events may arrive ahead of the original inbound webhook.
  if not exists(select 1 from public.messages where organization_id = p_organization_id and conversation_id = target.id
    and direction = 'incoming' and external_id = coalesce(p_source_wamid, p_last_inbound_wamid)) then
    raise exception 'customer message has not arrived' using errcode = '40001';
  end if;
  if p_request_id is not null then select * into operation from public.chatbot_node_operations where request_id = p_request_id
    and organization_id = p_organization_id and conversation_id = target.id; end if;
  update public.chatbot_node_conversations set lifecycle_enabled = true,
    ownership_revision = p_revision, state = p_state, human_owned = (p_state = 'human_owned'),
    pending_request_id = null,
    last_inbound_wamid = coalesce(last_inbound_wamid, p_last_inbound_wamid),
    resolved_by = case when p_state = 'closed' then nullif(operation.payload->>'actor_agent_id','')::uuid else resolved_by end,
    closed_at = case when p_state = 'closed' then now() else closed_at end
    where organization_id = p_organization_id and organization_address = p_address and node_conversation_id = p_node_conversation_id;
  if target.status = 'spam' then return target.id; end if;
  if p_state = 'closed' then
    -- Retain assignee so the agent can still read their closed history under RLS.
    update public.conversations set status = 'closed', extra = jsonb_build_object('node_support_resolution',
      jsonb_build_object('request_id', p_request_id, 'resolved_by', operation.payload->>'actor_agent_id', 'closed_at', now())) where id = target.id;
  elsif p_state in ('bot_ready','bot_active') then
    update public.conversations set status = 'active', assigned_agent_id = null, routing_queue_id = null, routed_at = null,
      extra = jsonb_build_object('paused', null) where id = target.id;
  else
    update public.conversations set status = 'active' where id = target.id;
  end if;
  return target.id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.begin_node_conversation_operation(p_organization_id uuid, p_conversation_id uuid, p_request_id uuid, p_action text, p_observed_last_inbound_wamid text, p_expected_revision text)
 RETURNS public.chatbot_node_operations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  target public.conversations;
  mapping public.chatbot_node_conversations;
  actor uuid;
  role public.role;
  latest_wamid text;
  operation public.chatbot_node_operations;
  body jsonb;
begin
  if auth.uid() is null or p_action not in ('resolve-and-close','resume') then
    raise exception 'authenticated conversation action required' using errcode = '42501'; end if;
  select * into target from public.conversations where organization_id = p_organization_id and id = p_conversation_id for update;
  actor := public.get_current_human_agent_id(p_organization_id);
  role := public.get_request_organization_role(p_organization_id);
  if target.id is null or actor is null or role not in ('owner','admin','supervisor','agent')
    or (role = 'agent' and (p_action = 'resume' or target.assigned_agent_id is distinct from actor)) then
    raise exception 'conversation action is not permitted' using errcode = '42501'; end if;
  body := jsonb_build_object('observed_last_inbound_wamid',p_observed_last_inbound_wamid,
    'expected_revision',p_expected_revision,'actor_agent_id',actor);
  select * into operation from public.chatbot_node_operations where request_id = p_request_id;
  if found then
    if operation.organization_id <> p_organization_id or operation.conversation_id is distinct from p_conversation_id
      or operation.action <> p_action or operation.payload - 'node_conversation_id' <> body then
      raise exception 'request ID cannot be reused with different data' using errcode = '23514'; end if;
    return operation;
  end if;
  select * into mapping from public.chatbot_node_conversations where organization_id = p_organization_id and conversation_id = p_conversation_id for update;
  if not found or not mapping.human_owned or target.status <> 'active' or not public.is_organization_active(p_organization_id) then
    raise exception 'conversation is not in active human support' using errcode = '23514'; end if;
  if p_expected_revision !~ '^[0-9]+$' or p_expected_revision::numeric < mapping.ownership_revision::numeric then
    raise exception 'conversation ownership changed' using errcode = '40001'; end if;
  latest_wamid := mapping.last_inbound_wamid;
  if latest_wamid is null then
    select external_id into latest_wamid from public.messages where organization_id = p_organization_id and conversation_id = p_conversation_id
      and direction = 'incoming' and external_id is not null order by created_at desc, id desc limit 1;
  end if;
  if latest_wamid is distinct from p_observed_last_inbound_wamid then
    raise exception 'A new customer message arrived—review it before closing.' using errcode = '40001'; end if;
  if exists(select 1 from public.messages m join public.agents a on a.id = m.agent_id where m.conversation_id = target.id
    and m.direction = 'outgoing' and not a.ai and m.status ? 'pending' and not m.status ?| array['sent','delivered','read','failed']) then
    raise exception 'Wait for pending human messages to finish sending.' using errcode = '23514'; end if;
  if exists(select 1 from public.chatbot_node_operations where organization_id = p_organization_id
    and organization_address = mapping.organization_address and status not in ('succeeded','failed')
    and (conversation_id is null or conversation_id = target.id)) then
    raise exception 'conversation has an unresolved bridge operation' using errcode = '23514'; end if;
  insert into public.chatbot_node_operations(request_id,organization_id,organization_address,conversation_id,action,phase,payload)
    values(p_request_id,p_organization_id,mapping.organization_address,target.id,p_action,p_action,
      body || jsonb_build_object('node_conversation_id',mapping.node_conversation_id)) returning * into operation;
  update public.chatbot_node_conversations set pending_request_id = p_request_id, lifecycle_enabled = true,
    last_inbound_wamid = latest_wamid where organization_id = p_organization_id and conversation_id = target.id;
  return operation;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.guard_node_human_message()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare target public.conversations;
begin
  if new.direction <> 'outgoing' or not new.status ? 'pending' or new.content = '{}'::jsonb
    or not exists(select 1 from public.agents where id = new.agent_id and not ai) then return new; end if;
  select * into target from public.conversations where id = new.conversation_id for update;
  if exists(select 1 from public.chatbot_node_conversations where conversation_id = target.id and lifecycle_enabled
    and (not human_owned or pending_request_id is not null or target.status = 'closed')) then
    raise exception 'Human sending is unavailable while closing or while the chatbot owns this conversation.' using errcode = '42501'; end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_node_chatbot_handoff(p_organization_id uuid, p_organization_address text, p_recipient text, p_source_wamid text, p_node_conversation_id text, p_event_id uuid, p_agent_id uuid DEFAULT NULL::uuid, p_routing_queue_id uuid DEFAULT NULL::uuid, p_revision text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  target public.conversations;
  existing_receipt public.chatbot_node_handoff_receipts;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text, 117));
  select * into existing_receipt from public.chatbot_node_handoff_receipts where event_id = p_event_id;
  if found then
    if existing_receipt.organization_id <> p_organization_id then
      raise exception 'handoff event belongs to another organization' using errcode = '42501';
    end if;
    return existing_receipt.conversation_id;
  end if;
  if not exists (select 1 from public.organization_lifecycle where organization_id = p_organization_id and status = 'active') then
    raise exception 'organization is archived' using errcode = '42501';
  end if;
  if not exists (select 1 from public.chatbot_node_bridges where organization_id = p_organization_id
    and organization_address = p_organization_address and engine in ('transitioning', 'node')) then
    raise exception 'number is not managed by Node' using errcode = '23514';
  end if;
  -- The exact source message must have arrived; never infer a conversation
  -- from a different number or an older conversation for the same customer.
  select c.* into target from public.conversations c join public.messages m on m.conversation_id = c.id
    where c.organization_id = p_organization_id and c.organization_address = p_organization_address
      and c.contact_address = p_recipient and m.organization_id = p_organization_id
      and m.external_id = p_source_wamid and m.direction = 'incoming' for update of c;
  if not found then raise exception 'source customer message has not arrived' using errcode = '40001'; end if;
  if exists(select 1 from public.chatbot_node_conversations where organization_id = p_organization_id and conversation_id = target.id
    and lifecycle_enabled and (p_revision is null or p_revision::numeric < ownership_revision::numeric
      or (p_revision::numeric = ownership_revision::numeric and not human_owned))) then
    insert into public.chatbot_node_handoff_receipts(event_id,organization_id,conversation_id) values(p_event_id,p_organization_id,target.id);
    return target.id;
  end if;
  update public.conversations set status = 'active' where id = target.id and status = 'closed';
  if (p_agent_id is null) = (p_routing_queue_id is null) then
    raise exception 'exactly one handoff target is required' using errcode = '23514';
  end if;
  if p_routing_queue_id is not null then
    perform public.route_conversation_to_queue(target.id, p_routing_queue_id);
  else
    if not exists (select 1 from public.agents a where a.organization_id = p_organization_id
      and a.id = p_agent_id and not a.ai and a.user_id is not null
      and coalesce(a.extra->'invitation'->>'status', 'accepted') = 'accepted') then
      raise exception 'handoff requires an active tenant human agent' using errcode = '23514';
    end if;
    -- Reuse assignment constraints; clear old queue so a valid tenant agent
    -- isn't incorrectly rejected as a member of a previous routing queue.
    update public.conversations set routing_queue_id = null, assigned_agent_id = p_agent_id where id = target.id;
  end if;
  insert into public.chatbot_node_conversations(organization_id, organization_address, node_conversation_id, conversation_id, ownership_revision, lifecycle_enabled)
    values (p_organization_id, p_organization_address, p_node_conversation_id, target.id, coalesce(p_revision,'0'), p_revision is not null)
    on conflict (organization_id, organization_address, node_conversation_id)
    do update set human_owned = true, state = 'human_owned', ownership_revision = coalesce(p_revision,chatbot_node_conversations.ownership_revision),
      lifecycle_enabled = chatbot_node_conversations.lifecycle_enabled or p_revision is not null;
  insert into public.chatbot_node_handoff_receipts(event_id, organization_id, conversation_id)
    values(p_event_id, p_organization_id, target.id);
  return target.id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.track_node_customer_message()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.direction <> 'incoming' or new.external_id is null or new.content = '{}'::jsonb then return new; end if;
  perform 1 from public.conversations where id = new.conversation_id for update;
  update public.chatbot_node_conversations set last_inbound_wamid = new.external_id where organization_id = new.organization_id
    and conversation_id = new.conversation_id;
  if exists(select 1 from public.chatbot_node_conversations where conversation_id = new.conversation_id and lifecycle_enabled
    and not human_owned and pending_request_id is null) then
    update public.conversations set status = 'active', assigned_agent_id = null, routing_queue_id = null, routed_at = null
      where id = new.conversation_id and status = 'closed';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.before_insert_on_messages()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  -- If conversation_id is already provided, proceed as is
  if new.conversation_id is not null then
    return new;
  end if;

  -- Look up conversation_id from conversation table
  -- Node's durable conversation mapping survives closure; never split history.
  perform pg_advisory_xact_lock(hashtextextended(new.organization_id::text || ':' || new.organization_address || ':' || coalesce(new.contact_address,''), 123));
  select c.id into new.conversation_id from public.conversations c
    join public.chatbot_node_conversations mapping on mapping.conversation_id = c.id and mapping.organization_id = c.organization_id
    where c.organization_id = new.organization_id and c.organization_address = new.organization_address
      and c.contact_address is not distinct from new.contact_address and c.group_address is not distinct from new.group_address
      and mapping.lifecycle_enabled order by c.created_at desc, c.id desc limit 1;
  if new.conversation_id is not null then return new; end if;
  select id into new.conversation_id
  from public.conversations
  where organization_id = new.organization_id and organization_address = new.organization_address
    and contact_address is not distinct from new.contact_address
    and group_address is not distinct from new.group_address
    and status = 'active'
  order by created_at desc
  limit 1;

  -- Create conversation if it doesn't exist
  if new.conversation_id is null then
    insert into public.conversations (
      organization_id,
      organization_address,
      contact_address,
      group_address,
      service
    ) values (
      new.organization_id,
      new.organization_address,
      new.contact_address,
      new.group_address,
      new.service
    )
    returning id into new.conversation_id;
  end if;

  return new;
end;
$function$
;

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
  if operation.conversation_id is not null then
    perform public.apply_node_conversation_lifecycle(operation.organization_id, operation.organization_address,
      operation.payload->>'node_conversation_id', (select contact_address from public.conversations where id = operation.conversation_id),
      p_result->>'revision',p_result->>'state',p_result->>'last_inbound_wamid',p_result->>'last_inbound_wamid',operation.request_id);
    update public.chatbot_node_operations set status = 'succeeded', result = p_result, next_attempt_at = null, last_error = null
      where request_id = p_request_id returning * into operation;
    update public.chatbot_node_conversations set pending_request_id = null where conversation_id = operation.conversation_id and pending_request_id = p_request_id;
    return operation;
  end if;
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


  create policy "tenant_bridge_conversation_read"
  on "public"."chatbot_node_conversations"
  as permissive
  for select
  to authenticated
using (((organization_id IN ( SELECT public.get_authorized_orgs('supervisor'::public.role) AS get_authorized_orgs)) OR public.agent_can_read_conversation(organization_id, conversation_id)));


CREATE TRIGGER node_customer_message_track AFTER INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.track_node_customer_message();

CREATE TRIGGER node_human_message_guard BEFORE INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.guard_node_human_message();

-- migra does not emit routine ACLs. Mirror the schema-source privileges;
-- unrelated table REVOKE noise from the generated diff was removed.
revoke all on function public.apply_node_conversation_lifecycle(uuid,text,text,text,text,text,text,text,uuid) from public, anon, authenticated;
grant execute on function public.apply_node_conversation_lifecycle(uuid,text,text,text,text,text,text,text,uuid) to service_role;
revoke all on function public.begin_node_conversation_operation(uuid,uuid,uuid,text,text,text) from public,anon;
grant execute on function public.begin_node_conversation_operation(uuid,uuid,uuid,text,text,text) to authenticated;
revoke all on function public.record_node_chatbot_handoff(uuid,text,text,text,text,uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.record_node_chatbot_handoff(uuid,text,text,text,text,uuid,uuid,uuid,text) to service_role;

-- Generated follow-up diff: race fence and direct-status guard.
set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.guard_node_conversation_status()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if current_user in ('authenticated','anon') and new.status is distinct from old.status
    and exists(select 1 from public.chatbot_node_conversations where conversation_id = old.id and lifecycle_enabled) then
    raise exception 'Use Resolve & close or Return to chatbot for this conversation.' using errcode = '42501';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.apply_node_conversation_lifecycle(p_organization_id uuid, p_address text, p_node_conversation_id text, p_recipient text, p_revision text, p_state text, p_last_inbound_wamid text, p_source_wamid text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  mapping public.chatbot_node_conversations;
  target public.conversations;
  operation public.chatbot_node_operations;
begin
  if p_revision !~ '^[0-9]+$' or p_state not in ('human_owned','closed','bot_ready','bot_active') then
    raise exception 'invalid conversation lifecycle' using errcode = '22023';
  end if;
  if not public.is_organization_active(p_organization_id) then
    raise exception 'organization is archived' using errcode = '42501';
  end if;
  if not public.is_node_managed_number(p_organization_id, p_address) then
    raise exception 'number is not managed by Node' using errcode = '23514';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_organization_id::text || ':' || p_address || ':' || p_recipient, 123));
  select * into mapping from public.chatbot_node_conversations where organization_id = p_organization_id
    and organization_address = p_address and node_conversation_id = p_node_conversation_id;
  if found then
    select * into target from public.conversations where organization_id = p_organization_id and id = mapping.conversation_id for update;
  else
    select c.* into target from public.conversations c join public.messages m on m.conversation_id = c.id
      where c.organization_id = p_organization_id and c.organization_address = p_address and c.contact_address = p_recipient
        and m.organization_id = p_organization_id and m.direction = 'incoming' and m.external_id = coalesce(p_source_wamid, p_last_inbound_wamid)
      for update of c;
    if not found then raise exception 'customer message has not arrived' using errcode = '40001'; end if;
    insert into public.chatbot_node_conversations(organization_id, organization_address, node_conversation_id, conversation_id)
      values(p_organization_id, p_address, p_node_conversation_id, target.id) returning * into mapping;
  end if;
  if target.contact_address is distinct from p_recipient then raise exception 'conversation mapping mismatch' using errcode = '23514'; end if;
  if p_revision::numeric <= mapping.ownership_revision::numeric and mapping.lifecycle_enabled then return target.id; end if;
  -- Reopen and handoff events may arrive ahead of the original inbound webhook.
  if not exists(select 1 from public.messages where organization_id = p_organization_id and conversation_id = target.id
    and direction = 'incoming' and external_id = coalesce(p_source_wamid, p_last_inbound_wamid)) then
    raise exception 'customer message has not arrived' using errcode = '40001';
  end if;
  -- The inbound webhook may beat the Node reopen event. Never hide that message
  -- by applying a close snapshot which only observed an older customer message.
  if p_state = 'closed' and mapping.last_inbound_wamid is not null
    and mapping.last_inbound_wamid is distinct from p_last_inbound_wamid then
    raise exception 'A new customer message arrived—review it before closing.' using errcode = '40001';
  end if;
  if p_request_id is not null then select * into operation from public.chatbot_node_operations where request_id = p_request_id
    and organization_id = p_organization_id and conversation_id = target.id; end if;
  update public.chatbot_node_conversations set lifecycle_enabled = true,
    ownership_revision = p_revision, state = p_state, human_owned = (p_state = 'human_owned'),
    pending_request_id = null,
    last_inbound_wamid = coalesce(last_inbound_wamid, p_last_inbound_wamid),
    resolved_by = case when p_state = 'closed' then nullif(operation.payload->>'actor_agent_id','')::uuid else resolved_by end,
    closed_at = case when p_state = 'closed' then now() else closed_at end
    where organization_id = p_organization_id and organization_address = p_address and node_conversation_id = p_node_conversation_id;
  if target.status = 'spam' then return target.id; end if;
  if p_state = 'closed' then
    -- Retain assignee so the agent can still read their closed history under RLS.
    update public.conversations set status = 'closed', extra = jsonb_build_object('node_support_resolution',
      jsonb_build_object('request_id', p_request_id, 'resolved_by', operation.payload->>'actor_agent_id', 'closed_at', now())) where id = target.id;
  elsif p_state in ('bot_ready','bot_active') then
    update public.conversations set status = 'active', assigned_agent_id = null, routing_queue_id = null, routed_at = null,
      extra = jsonb_build_object('paused', null) where id = target.id;
  else
    update public.conversations set status = 'active' where id = target.id;
  end if;
  return target.id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.before_insert_on_messages()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  -- If conversation_id is already provided, proceed as is
  if new.conversation_id is not null then
    return new;
  end if;

  -- Look up conversation_id from conversation table
  -- Node's durable conversation mapping survives closure; never split history.
  perform pg_advisory_xact_lock(hashtextextended(new.organization_id::text || ':' || new.organization_address || ':' || coalesce(new.contact_address,''), 123));
  select c.id into new.conversation_id from public.conversations c
    join public.chatbot_node_conversations mapping on mapping.conversation_id = c.id and mapping.organization_id = c.organization_id
    where c.organization_id = new.organization_id and c.organization_address = new.organization_address
      and c.contact_address is not distinct from new.contact_address and c.group_address is not distinct from new.group_address
      and mapping.lifecycle_enabled order by c.created_at desc, c.id desc limit 1;
  if new.conversation_id is not null then return new; end if;
  select id into new.conversation_id
  from public.conversations
  where organization_id = new.organization_id and organization_address = new.organization_address
    and contact_address is not distinct from new.contact_address
    and group_address is not distinct from new.group_address
    and status = 'active'
  order by created_at desc
  limit 1;

  -- Create conversation if it doesn't exist
  if new.conversation_id is null then
    insert into public.conversations (
      organization_id,
      organization_address,
      contact_address,
      group_address,
      service
    ) values (
      new.organization_id,
      new.organization_address,
      new.contact_address,
      new.group_address,
      new.service
    )
    returning id into new.conversation_id;
  end if;

  return new;
end;
$function$
;

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
  if operation.conversation_id is not null then
    perform public.apply_node_conversation_lifecycle(operation.organization_id, operation.organization_address,
      operation.payload->>'node_conversation_id', (select contact_address from public.conversations where id = operation.conversation_id),
      p_result->>'revision',p_result->>'state',p_result->>'last_inbound_wamid',p_result->>'last_inbound_wamid',operation.request_id);
    update public.chatbot_node_operations set status = 'succeeded', result = p_result, next_attempt_at = null, last_error = null
      where request_id = p_request_id returning * into operation;
    if operation.action = 'resolve-and-close' then
      -- Resolution attribution survives even if reconciliation already sees a
      -- newer reopened/human-owned revision. Do not change its ownership/status.
      update public.chatbot_node_conversations set resolved_by = (operation.payload->>'actor_agent_id')::uuid,
        closed_at = coalesce(closed_at, operation.created_at) where conversation_id = operation.conversation_id;
    end if;
    update public.chatbot_node_conversations set pending_request_id = null where conversation_id = operation.conversation_id and pending_request_id = p_request_id;
    return operation;
  end if;
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

CREATE OR REPLACE FUNCTION public.record_node_chatbot_handoff(p_organization_id uuid, p_organization_address text, p_recipient text, p_source_wamid text, p_node_conversation_id text, p_event_id uuid, p_agent_id uuid DEFAULT NULL::uuid, p_routing_queue_id uuid DEFAULT NULL::uuid, p_revision text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  target public.conversations;
  existing_receipt public.chatbot_node_handoff_receipts;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text, 117));
  select * into existing_receipt from public.chatbot_node_handoff_receipts where event_id = p_event_id;
  if found then
    if existing_receipt.organization_id <> p_organization_id then
      raise exception 'handoff event belongs to another organization' using errcode = '42501';
    end if;
    return existing_receipt.conversation_id;
  end if;
  if not exists (select 1 from public.organization_lifecycle where organization_id = p_organization_id and status = 'active') then
    raise exception 'organization is archived' using errcode = '42501';
  end if;
  if not exists (select 1 from public.chatbot_node_bridges where organization_id = p_organization_id
    and organization_address = p_organization_address and engine in ('transitioning', 'node')) then
    raise exception 'number is not managed by Node' using errcode = '23514';
  end if;
  -- The exact source message must have arrived; never infer a conversation
  -- from a different number or an older conversation for the same customer.
  select c.* into target from public.conversations c join public.messages m on m.conversation_id = c.id
    where c.organization_id = p_organization_id and c.organization_address = p_organization_address
      and c.contact_address = p_recipient and m.organization_id = p_organization_id
      and m.external_id = p_source_wamid and m.direction = 'incoming' for update of c;
  if not found then raise exception 'source customer message has not arrived' using errcode = '40001'; end if;
  if exists(select 1 from public.chatbot_node_conversations where organization_id = p_organization_id and conversation_id = target.id
    and lifecycle_enabled and (p_revision is null or p_revision::numeric < ownership_revision::numeric
      or (p_revision::numeric = ownership_revision::numeric and not human_owned))) then
    insert into public.chatbot_node_handoff_receipts(event_id,organization_id,conversation_id) values(p_event_id,p_organization_id,target.id);
    return target.id;
  end if;
  update public.conversations set status = 'active' where id = target.id and status = 'closed';
  if (p_agent_id is null) = (p_routing_queue_id is null) then
    raise exception 'exactly one handoff target is required' using errcode = '23514';
  end if;
  if p_routing_queue_id is not null then
    perform public.route_conversation_to_queue(target.id, p_routing_queue_id);
  else
    if not exists (select 1 from public.agents a where a.organization_id = p_organization_id
      and a.id = p_agent_id and not a.ai and a.user_id is not null
      and coalesce(a.extra->'invitation'->>'status', 'accepted') = 'accepted') then
      raise exception 'handoff requires an active tenant human agent' using errcode = '23514';
    end if;
    -- Reuse assignment constraints; clear old queue so a valid tenant agent
    -- isn't incorrectly rejected as a member of a previous routing queue.
    update public.conversations set routing_queue_id = null, assigned_agent_id = p_agent_id where id = target.id;
  end if;
  insert into public.chatbot_node_conversations(organization_id, organization_address, node_conversation_id, conversation_id, ownership_revision, lifecycle_enabled)
    values (p_organization_id, p_organization_address, p_node_conversation_id, target.id, coalesce(p_revision,'0'), p_revision is not null)
    on conflict (organization_id, organization_address, node_conversation_id)
    do update set human_owned = true, state = 'human_owned', ownership_revision = coalesce(p_revision,chatbot_node_conversations.ownership_revision),
      lifecycle_enabled = chatbot_node_conversations.lifecycle_enabled or p_revision is not null;
  insert into public.chatbot_node_handoff_receipts(event_id, organization_id, conversation_id)
    values(p_event_id, p_organization_id, target.id);
  return target.id;
end;
$function$
;

CREATE TRIGGER node_conversation_status_guard BEFORE UPDATE OF status ON public.conversations FOR EACH ROW EXECUTE FUNCTION public.guard_node_conversation_status();
