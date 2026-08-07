create function public.transfer_conversation_with_private_note(
  p_conversation_id uuid,
  p_target_agent_id uuid,
  p_text text
) returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $$
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
$$;

revoke execute on function public.transfer_conversation_with_private_note(
  uuid,
  uuid,
  text
) from public;

grant execute on function public.transfer_conversation_with_private_note(
  uuid,
  uuid,
  text
) to authenticated;
