drop policy "members can create their orgs messages" on "public"."messages";

  create table "public"."message_mentions" (
    "organization_id" uuid not null,
    "message_id" uuid not null,
    "mentioned_agent_id" uuid not null,
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."message_mentions" enable row level security;

grant select on table "public"."message_mentions" to "authenticated";

grant all on table "public"."message_mentions" to "service_role";

CREATE INDEX message_mentions_message_id_idx ON public.message_mentions USING btree (message_id);

CREATE UNIQUE INDEX message_mentions_pkey ON public.message_mentions USING btree (message_id, mentioned_agent_id);

CREATE INDEX message_mentions_recipient_time_idx ON public.message_mentions USING btree (organization_id, mentioned_agent_id, created_at DESC, message_id);

CREATE UNIQUE INDEX messages_organization_id_id_key ON public.messages USING btree (organization_id, id);

alter table "public"."message_mentions" add constraint "message_mentions_pkey" PRIMARY KEY using index "message_mentions_pkey";

alter table "public"."message_mentions" add constraint "message_mentions_agent_fkey" FOREIGN KEY (organization_id, mentioned_agent_id) REFERENCES public.agents(organization_id, id) ON DELETE CASCADE not valid;

alter table "public"."message_mentions" validate constraint "message_mentions_agent_fkey";

alter table "public"."message_mentions" add constraint "message_mentions_message_fkey" FOREIGN KEY (organization_id, message_id) REFERENCES public.messages(organization_id, id) ON DELETE CASCADE not valid;

alter table "public"."message_mentions" validate constraint "message_mentions_message_fkey";

alter table "public"."messages" add constraint "messages_organization_id_id_key" UNIQUE using index "messages_organization_id_id_key";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.create_private_note(p_conversation_id uuid, p_text text, p_mentioned_agent_ids uuid[] DEFAULT ARRAY[]::uuid[])
 RETURNS public.messages
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  conversation_row public.conversations;
  author_agent_id uuid;
  request_role public.role;
  normalized_text text;
  normalized_mentions uuid[];
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
      message = 'private note text is required';
  end if;

  if array_position(p_mentioned_agent_ids, null) is not null then
    raise exception using
      errcode = '22023',
      message = 'mentioned agent ids cannot contain null';
  end if;

  select coalesce(array_agg(distinct mentioned_id order by mentioned_id), array[]::uuid[])
  into normalized_mentions
  from unnest(coalesce(p_mentioned_agent_ids, array[]::uuid[])) as mentioned(mentioned_id);

  select c.*
  into conversation_row
  from public.conversations c
  where c.id = p_conversation_id;

  if conversation_row.id is null then
    raise exception using
      errcode = '42501',
      message = 'conversation is not accessible to the authenticated user';
  end if;

  request_role := public.get_request_organization_role(conversation_row.organization_id);
  author_agent_id := public.get_current_human_agent_id(conversation_row.organization_id);

  if request_role is null or author_agent_id is null then
    raise exception using
      errcode = '42501',
      message = 'conversation is not accessible to the authenticated user';
  end if;

  if request_role = 'agent'::public.role then
    if not public.agent_can_read_conversation(
      conversation_row.organization_id,
      conversation_row.id
    ) then
      raise exception using
        errcode = '42501',
        message = 'conversation is not accessible to the authenticated user';
    end if;
  elsif not exists (
    select 1
    from public.get_authorized_orgs('member') as authorized_orgs(id)
    where authorized_orgs.id = conversation_row.organization_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'conversation is not accessible to the authenticated user';
  end if;

  if conversation_row.status <> 'active' then
    raise exception using
      errcode = '22023',
      message = 'private notes can only be added to active conversations';
  end if;

  if author_agent_id = any(normalized_mentions) then
    raise exception using
      errcode = '22023',
      message = 'authors cannot mention themselves';
  end if;

  if (
    select count(*)
    from public.agents target
    where target.organization_id = conversation_row.organization_id
      and target.id = any(normalized_mentions)
      and target.ai = false
      and target.user_id is not null
      and (
        target.extra->'invitation' is null
        or target.extra->'invitation'->>'status' = 'accepted'
      )
      and target.extra->>'role' in ('owner', 'admin', 'supervisor', 'member', 'agent')
  ) <> cardinality(normalized_mentions) then
    raise exception using
      errcode = '22023',
      message = 'mentions must target accepted humans in the same organization';
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
      'mentioned_agent_ids', to_jsonb(normalized_mentions)
    ),
    '{}'::jsonb
  )
  returning * into note;

  insert into public.message_mentions (
    organization_id,
    message_id,
    mentioned_agent_id,
    created_at
  )
  select
    note.organization_id,
    note.id,
    mentioned_id,
    note.created_at
  from unnest(normalized_mentions) as mentioned(mentioned_id);

  return note;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_mentionable_humans_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 50, p_search text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, name text, picture text, role public.role, total_count bigint)
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
  normalized_page_size := least(greatest(coalesce(p_page_size, 50), 1), 50);
  normalized_search := lower(btrim(coalesce(p_search, '')));

  return query
  select
    candidate.id,
    candidate.name,
    candidate.picture,
    (candidate.extra->>'role')::public.role,
    count(*) over() as total_count
  from public.agents candidate
  where candidate.organization_id = p_organization_id
    and candidate.id <> current_agent_id
    and candidate.ai = false
    and candidate.user_id is not null
    and (
      candidate.extra->'invitation' is null
      or candidate.extra->'invitation'->>'status' = 'accepted'
    )
    and candidate.extra->>'role' in ('owner', 'admin', 'supervisor', 'member', 'agent')
    and (
      normalized_search = ''
      or lower(candidate.name) like '%' || normalized_search || '%'
    )
  order by lower(candidate.name), candidate.id
  offset (normalized_page - 1) * normalized_page_size
  limit normalized_page_size;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_mentioned_conversations_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 25, p_search text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, id uuid, service public.service, organization_address text, contact_address text, group_address text, name text, assigned_agent_id uuid, extra jsonb, status text, created_at timestamp with time zone, updated_at timestamp with time zone, preview_message jsonb, latest_mention_at timestamp with time zone, total_count bigint)
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
              c.assigned_agent_id is null
              or c.assigned_agent_id = public.get_current_human_agent_id(p_organization_id)
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

CREATE OR REPLACE FUNCTION public.get_conversation_queue_conversations(p_organization_id uuid, p_queue_key text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
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

CREATE OR REPLACE FUNCTION public.get_conversation_queues(p_organization_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(key text, label text, "order" integer, enabled boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  request_role public.role;
begin
  if p_organization_id is not null
    and not exists (
      select 1
      from public.get_authorized_orgs('agent') as authorized_orgs(id)
      where authorized_orgs.id = p_organization_id
    )
  then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  request_role := case
    when p_organization_id is null then null
    else public.get_request_organization_role(p_organization_id)
  end;

  if request_role = 'agent'::public.role then
    return query
    select q.key, q.label, q.sort_order as "order", q.enabled
    from (
      values
        ('pending', 'Pending', 1, true),
        ('assigned', 'Assigned', 2, true),
        ('mentioned', 'Mentioned', 3, true),
        ('spam', 'Spam', 4, true),
        ('closed', 'Closed', 5, true),
        ('expired', 'Expired', 6, true)
    ) as q(key, label, sort_order, enabled)
    order by q.sort_order;
    return;
  end if;

  return query
  select
    q.key,
    q.label,
    q.sort_order as "order",
    q.enabled
  from (
    values
      ('all_active', 'All (active)', 1, true),
      ('assigned', 'Assigned', 2, true),
      ('pending', 'Pending', 3, true),
      ('mentioned', 'Mentioned', 4, true),
      ('spam', 'Spam', 5, true),
      ('closed', 'Closed', 6, true),
      ('expired', 'Expired', 7, true)
  ) as q(key, label, sort_order, enabled)
  order by q.sort_order;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.notify_webhook()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  webhook_record record;
  headers jsonb;
begin
  if tg_table_name = 'messages' then
    if new.direction = 'internal'::public.direction
      and new.content->>'kind' = 'private_note'
    then
      return new;
    end if;
  end if;

  -- loop through all matching webhooks
  for webhook_record in
    select w.url, w.token
    from public.webhooks w
    where new.organization_id = w.organization_id
      and w.table_name = tg_table_name::public.webhook_table
      and lower(tg_op)::public.webhook_operation = any(w.operations)
    limit 3
  loop
    -- prepare headers
    headers := case
      when webhook_record.token is not null then
        jsonb_build_object(
          'content-type', 'application/json',
          'authorization', 'Bearer ' || webhook_record.token
        )
      else
        jsonb_build_object(
          'content-type', 'application/json'
        )
      end;

    -- send webhook notification
    perform net.http_post(
      url := webhook_record.url,
      body := jsonb_build_object(
        'data', to_jsonb(new),
        'entity', tg_table_name,
        'action', lower(tg_op)
      ),
      headers := headers
    );
  end loop;

  return new;
end;
$function$
;

grant references on table "public"."message_mentions" to "anon";

grant trigger on table "public"."message_mentions" to "anon";

grant truncate on table "public"."message_mentions" to "anon";

grant references on table "public"."message_mentions" to "authenticated";

grant trigger on table "public"."message_mentions" to "authenticated";

grant truncate on table "public"."message_mentions" to "authenticated";

grant references on table "public"."message_mentions" to "service_role";

grant trigger on table "public"."message_mentions" to "service_role";

grant truncate on table "public"."message_mentions" to "service_role";


  create policy "agents can read their own message mentions"
  on "public"."message_mentions"
  as permissive
  for select
  to authenticated
using (((public.get_request_organization_role(organization_id) = 'agent'::public.role) AND (mentioned_agent_id = public.get_current_human_agent_id(organization_id))));



  create policy "members can read their orgs message mentions"
  on "public"."message_mentions"
  as permissive
  for select
  to authenticated
using ((organization_id IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)));



  create policy "members can create their orgs messages"
  on "public"."messages"
  as permissive
  for insert
  to authenticated, anon
with check (((organization_id IN ( SELECT public.get_authorized_orgs('member'::public.role) AS get_authorized_orgs)) AND (NOT ((direction = 'internal'::public.direction) AND ((content ->> 'kind'::text) = 'private_note'::text)))));

revoke execute on function public.create_private_note(uuid, text, uuid[])
from public;

grant execute on function public.create_private_note(uuid, text, uuid[])
to authenticated;

revoke execute on function public.list_mentionable_humans_page(
  uuid,
  integer,
  integer,
  text
) from public;

grant execute on function public.list_mentionable_humans_page(
  uuid,
  integer,
  integer,
  text
) to authenticated;

revoke execute on function public.list_mentioned_conversations_page(
  uuid,
  integer,
  integer,
  text
) from public;

grant execute on function public.list_mentioned_conversations_page(
  uuid,
  integer,
  integer,
  text
) to authenticated;
