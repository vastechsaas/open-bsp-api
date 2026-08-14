create table "public"."conversation_routing_events" (
    "id" uuid not null default gen_random_uuid(),
    "organization_id" uuid not null,
    "conversation_id" uuid not null,
    "previous_routing_queue_id" uuid,
    "previous_routing_queue_name" text,
    "destination_routing_queue_id" uuid not null,
    "destination_routing_queue_name" text not null,
    "actor_agent_id" uuid,
    "source" text not null,
    "explanation" text,
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."conversation_routing_events" enable row level security;

CREATE INDEX conversation_routing_events_conversation_time_idx ON public.conversation_routing_events USING btree (conversation_id, created_at DESC, id DESC);

CREATE INDEX conversation_routing_events_organization_time_idx ON public.conversation_routing_events USING btree (organization_id, created_at DESC, id DESC);

CREATE UNIQUE INDEX conversation_routing_events_pkey ON public.conversation_routing_events USING btree (id);

alter table "public"."conversation_routing_events" add constraint "conversation_routing_events_pkey" PRIMARY KEY using index "conversation_routing_events_pkey";

alter table "public"."conversation_routing_events" add constraint "conversation_routing_events_actor_fkey" FOREIGN KEY (actor_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL not valid;

alter table "public"."conversation_routing_events" validate constraint "conversation_routing_events_actor_fkey";

alter table "public"."conversation_routing_events" add constraint "conversation_routing_events_conversation_fkey" FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE not valid;

alter table "public"."conversation_routing_events" validate constraint "conversation_routing_events_conversation_fkey";

alter table "public"."conversation_routing_events" add constraint "conversation_routing_events_destination_name_check" CHECK (((char_length(btrim(destination_routing_queue_name)) >= 1) AND (char_length(btrim(destination_routing_queue_name)) <= 80))) not valid;

alter table "public"."conversation_routing_events" validate constraint "conversation_routing_events_destination_name_check";

alter table "public"."conversation_routing_events" add constraint "conversation_routing_events_explanation_check" CHECK ((((source = 'manual_transfer'::text) AND (NULLIF(btrim(explanation), ''::text) IS NOT NULL)) OR (source <> 'manual_transfer'::text))) not valid;

alter table "public"."conversation_routing_events" validate constraint "conversation_routing_events_explanation_check";

alter table "public"."conversation_routing_events" add constraint "conversation_routing_events_organization_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."conversation_routing_events" validate constraint "conversation_routing_events_organization_fkey";

alter table "public"."conversation_routing_events" add constraint "conversation_routing_events_previous_name_check" CHECK (((previous_routing_queue_name IS NULL) OR ((char_length(btrim(previous_routing_queue_name)) >= 1) AND (char_length(btrim(previous_routing_queue_name)) <= 80)))) not valid;

alter table "public"."conversation_routing_events" validate constraint "conversation_routing_events_previous_name_check";

alter table "public"."conversation_routing_events" add constraint "conversation_routing_events_source_check" CHECK ((source = ANY (ARRAY['legacy_backfill'::text, 'chatbot_handoff'::text, 'manual_transfer'::text]))) not valid;

alter table "public"."conversation_routing_events" validate constraint "conversation_routing_events_source_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.list_transferable_routing_queue_options(p_conversation_id uuid)
 RETURNS TABLE(id uuid, name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  conversation_row public.conversations;
  request_role public.role;
  author_agent_id uuid;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'authentication required';
  end if;

  select conversation.* into conversation_row
  from public.conversations conversation
  where conversation.id = p_conversation_id;

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

  return query
  select queue.id, queue.name
  from public.routing_queues queue
  where queue.organization_id = conversation_row.organization_id
    and queue.status = 'active'
    and queue.id is distinct from conversation_row.routing_queue_id
  order by lower(queue.name), queue.id;
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

  return jsonb_build_object(
    'conversation', to_jsonb(updated_conversation),
    'note', to_jsonb(note),
    'routing_event', to_jsonb(routing_event)
  );
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

  return target_conversation;
end;
$function$
;

grant delete on table "public"."conversation_routing_events" to "service_role";

grant insert on table "public"."conversation_routing_events" to "service_role";

grant references on table "public"."conversation_routing_events" to "service_role";

grant select on table "public"."conversation_routing_events" to "service_role";

grant trigger on table "public"."conversation_routing_events" to "service_role";

grant truncate on table "public"."conversation_routing_events" to "service_role";

grant update on table "public"."conversation_routing_events" to "service_role";





revoke execute on function public.list_transferable_routing_queue_options(uuid)
from public;

grant execute on function public.list_transferable_routing_queue_options(uuid)
to authenticated;

revoke execute on function public.transfer_conversation_to_queue_with_private_note(
  uuid,
  uuid,
  text
) from public;

grant execute on function public.transfer_conversation_to_queue_with_private_note(
  uuid,
  uuid,
  text
) to authenticated;

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
)
select
  conversation.organization_id,
  conversation.id,
  null,
  null,
  queue.id,
  queue.name,
  null,
  'legacy_backfill',
  null,
  coalesce(conversation.routed_at, conversation.updated_at, conversation.created_at)
from public.conversations conversation
join public.routing_queues queue
  on queue.organization_id = conversation.organization_id
  and queue.id = conversation.routing_queue_id
where conversation.routing_queue_id is not null;

