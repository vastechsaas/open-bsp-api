
-- Generated schema diff; explicit function ACLs are mirrored from schema
-- sources because migra does not emit these new-function privileges.
set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.authorize_previous_chat_context(p_organization_id uuid, p_conversation_id uuid)
 RETURNS public.conversations
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.list_previous_conversation_messages(p_organization_id uuid, p_conversation_id uuid, p_previous_conversation_id uuid, p_before_timestamp timestamp with time zone DEFAULT NULL::timestamp with time zone, p_before_id uuid DEFAULT NULL::uuid, p_page_size integer DEFAULT 30)
 RETURNS SETOF public.messages
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.list_previous_conversations_page(p_organization_id uuid, p_conversation_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, name text, status text, created_at timestamp with time zone, updated_at timestamp with time zone, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

revoke all on function public.authorize_previous_chat_context(uuid,uuid) from public,anon,authenticated;
revoke all on function public.list_previous_conversation_messages(uuid,uuid,uuid,timestamptz,uuid,integer) from public,anon;
grant execute on function public.list_previous_conversation_messages(uuid,uuid,uuid,timestamptz,uuid,integer) to authenticated;


