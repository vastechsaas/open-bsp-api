-- Called only by authenticated integration handlers, never directly by clients.
create function public.resolve_node_conversation_episode(
  p_organization_id uuid, p_address text, p_recipient text,
  p_node_conversation_id text, p_episode_number integer, p_previous_node_conversation_id text default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  mapping public.chatbot_node_conversations;
  predecessor public.chatbot_node_conversations;
  target public.conversations;
begin
  if p_node_conversation_id is null or p_episode_number is null or p_recipient is null or p_address is null
    or p_node_conversation_id !~ '^[0-9]+$' or p_episode_number < 1
    or (p_episode_number > 1 and p_previous_node_conversation_id is null)
    or (p_episode_number = 1 and p_previous_node_conversation_id is not null) then
    raise exception 'invalid Node episode context' using errcode='22023'; end if;
  if not public.is_organization_active(p_organization_id) or not public.is_node_managed_number(p_organization_id,p_address) then
    raise exception 'tenant or Node binding unavailable' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_organization_id::text || ':' || p_address || ':' || p_recipient,123));
  select * into mapping from public.chatbot_node_conversations where organization_id=p_organization_id
    and organization_address=p_address and node_conversation_id=p_node_conversation_id for update;
  if found then
    select * into target from public.conversations where organization_id=p_organization_id and id=mapping.conversation_id;
    if target.contact_address is distinct from p_recipient or
      (mapping.episode_number is not null and (mapping.episode_number<>p_episode_number
        or mapping.previous_node_conversation_id is distinct from p_previous_node_conversation_id)) then
      raise exception 'episode mapping mismatch' using errcode='23514'; end if;
    update public.chatbot_node_conversations set episode_number=p_episode_number,
      previous_node_conversation_id=p_previous_node_conversation_id where organization_id=p_organization_id
      and organization_address=p_address and node_conversation_id=p_node_conversation_id;
    return target.id;
  end if;
  if p_previous_node_conversation_id is not null then
    select * into predecessor from public.chatbot_node_conversations where organization_id=p_organization_id
      and organization_address=p_address and node_conversation_id=p_previous_node_conversation_id for update;
    if not found or predecessor.state<>'closed' then
      raise exception 'previous episode closure has not arrived' using errcode='40001'; end if;
    select * into target from public.conversations where organization_id=p_organization_id and id=predecessor.conversation_id;
    if target.contact_address is distinct from p_recipient or coalesce(predecessor.episode_number,1)<>p_episode_number-1 then
      raise exception 'episode predecessor mismatch' using errcode='23514'; end if;
    update public.chatbot_node_conversations set episode_number=coalesce(episode_number,1)
      where organization_id=p_organization_id and organization_address=p_address and node_conversation_id=p_previous_node_conversation_id;
    target.id := null;
  else
    if exists(select 1 from public.chatbot_node_conversations m join public.conversations c on c.id=m.conversation_id
      where m.organization_id=p_organization_id and m.organization_address=p_address and c.contact_address=p_recipient
      and m.episode_number is not null) then
      raise exception 'episode predecessor is required' using errcode='23514'; end if;
    -- Adopt the current legacy thread when enrolling a tenant; never move messages.
    select * into target from public.conversations c where c.organization_id=p_organization_id
      and c.organization_address=p_address and c.contact_address=p_recipient and c.group_address is null
      and c.status='active' and not exists(select 1 from public.chatbot_node_conversations m
        where m.organization_id=p_organization_id and m.conversation_id=c.id)
      order by c.created_at desc,c.id desc limit 1 for update;
  end if;
  if target.id is null then
    insert into public.conversations(organization_id,organization_address,contact_address,service)
      values(p_organization_id,p_address,p_recipient,'whatsapp') returning * into target;
  end if;
  insert into public.chatbot_node_conversations(organization_id,organization_address,node_conversation_id,conversation_id,
    human_owned,lifecycle_enabled,state,episode_number,previous_node_conversation_id)
    values(p_organization_id,p_address,p_node_conversation_id,target.id,false,true,'bot_ready',p_episode_number,p_previous_node_conversation_id);
  return target.id;
end;
$$;
revoke all on function public.resolve_node_conversation_episode(uuid,text,text,text,integer,text) from public,anon,authenticated;
grant execute on function public.resolve_node_conversation_episode(uuid,text,text,text,integer,text) to service_role;

-- History is shared across support agents, not across customers or tenants.
-- Keep ordinary inbox/message RLS and all mutation permissions unchanged.
-- Only the scoped read RPCs below can use this internal authorization helper.
create function public.authorize_previous_chat_context(
  p_organization_id uuid, p_conversation_id uuid
) returns public.conversations
language plpgsql stable security definer set search_path = '' as $$
declare
  target public.conversations;
  request_role public.role;
begin
  if auth.uid() is null then
    raise exception 'organization is not accessible' using errcode='42501';
  end if;
  request_role := public.get_request_organization_role(p_organization_id);
  if request_role is null then
    raise exception 'organization is not accessible' using errcode='42501';
  end if;
  select * into target from public.conversations c
    where c.organization_id=p_organization_id and c.id=p_conversation_id;
  if not found or target.group_address is not null or target.contact_address is null
    or (request_role='agent'::public.role
      and not public.agent_can_read_conversation(p_organization_id,p_conversation_id)) then
    raise exception 'conversation is not accessible' using errcode='42501';
  end if;
  return target;
end;
$$;
revoke all on function public.authorize_previous_chat_context(uuid,uuid) from public,anon,authenticated;

create function public.list_previous_conversations_page(
  p_organization_id uuid, p_conversation_id uuid, p_page integer default 1,
  p_page_size integer default 10, p_search text default null
) returns table(id uuid,name text,status text,created_at timestamptz,updated_at timestamptz,total_count bigint)
language plpgsql stable security definer set search_path = '' as $$
declare target public.conversations;
begin
  target := public.authorize_previous_chat_context(p_organization_id,p_conversation_id);
  return query select c.id,c.name,c.status,c.created_at,c.updated_at,count(*) over()
    from public.conversations c where c.organization_id=p_organization_id and c.id<>target.id
    and c.service=target.service and c.organization_address=target.organization_address
    and c.contact_address=target.contact_address and c.group_address is null
    and (nullif(btrim(p_search),'') is null or c.name ilike '%' || btrim(p_search) || '%')
    order by c.created_at desc,c.id desc limit greatest(1,least(coalesce(p_page_size,10),50))
    offset (greatest(1,coalesce(p_page,1))-1)*greatest(1,least(coalesce(p_page_size,10),50));
end;
$$;
revoke all on function public.list_previous_conversations_page(uuid,uuid,integer,integer,text) from public,anon;
grant execute on function public.list_previous_conversations_page(uuid,uuid,integer,integer,text) to authenticated;

create function public.list_previous_conversation_messages(
  p_organization_id uuid, p_conversation_id uuid, p_previous_conversation_id uuid,
  p_before_timestamp timestamptz default null, p_before_id uuid default null,
  p_page_size integer default 30
) returns setof public.messages
language plpgsql stable security definer set search_path = '' as $$
declare target public.conversations;
begin
  -- Recheck the current conversation and membership on every message page.
  target := public.authorize_previous_chat_context(p_organization_id,p_conversation_id);
  if not exists(select 1 from public.conversations c
    where c.organization_id=p_organization_id and c.id=p_previous_conversation_id
      and c.id<>target.id and c.group_address is null
      and c.service=target.service and c.organization_address=target.organization_address
      and c.contact_address=target.contact_address) then
    raise exception 'previous conversation is not accessible' using errcode='42501';
  end if;
  if (p_before_timestamp is null) <> (p_before_id is null) then
    raise exception 'both history cursor values are required' using errcode='22023';
  end if;
  return query select m.* from public.messages m
    where m.organization_id=p_organization_id and m.conversation_id=p_previous_conversation_id
      and (p_before_timestamp is null or (m.timestamp,m.id)<(p_before_timestamp,p_before_id))
    order by m.timestamp desc,m.id desc
    limit greatest(1,least(coalesce(p_page_size,30),50));
end;
$$;
revoke all on function public.list_previous_conversation_messages(uuid,uuid,uuid,timestamptz,uuid,integer) from public,anon;
grant execute on function public.list_previous_conversation_messages(uuid,uuid,uuid,timestamptz,uuid,integer) to authenticated;
