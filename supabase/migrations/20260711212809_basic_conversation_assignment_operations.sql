set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.assign_conversation_to_me(
  p_conversation_id uuid
)
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
      select public.get_authorized_orgs('member')
    )
    and a.organization_id = c.organization_id
    and a.user_id = auth.uid()
    and a.ai = false
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
        select public.get_authorized_orgs('member')
      )
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

CREATE OR REPLACE FUNCTION public.unassign_conversation_from_me(
  p_conversation_id uuid
)
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
  set assigned_agent_id = null
  from public.agents a
  where c.id = p_conversation_id
    and c.assigned_agent_id = a.id
    and c.organization_id in (
      select public.get_authorized_orgs('member')
    )
    and a.organization_id = c.organization_id
    and a.user_id = auth.uid()
    and a.ai = false
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
        select public.get_authorized_orgs('member')
      )
  ) then
    raise exception using
      errcode = '42501',
      message = 'conversation is not accessible to the authenticated user';
  end if;

  if not exists (
    select 1
    from public.conversations c
    join public.agents a
      on a.organization_id = c.organization_id
     and a.id = c.assigned_agent_id
    where c.id = p_conversation_id
      and a.user_id = auth.uid()
      and a.ai = false
  ) then
    raise exception using
      errcode = '42501',
      message = 'conversation is not assigned to the authenticated human agent';
  end if;

  raise exception using
    errcode = '23514',
    message = 'conversation cannot be unassigned';
end;
$function$
;
