-- Presentation eligibility only. Never use this predicate in message/conversation RLS.
create function public.is_support_inbox_visible(
  p_organization_id uuid, p_conversation_id uuid
) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.conversations c
    where c.organization_id = p_organization_id and c.id = p_conversation_id
      and (
        c.organization_id in (select public.get_authorized_orgs('member'))
        or public.agent_can_read_conversation(c.organization_id, c.id)
      )
      and (
        not exists (
          select 1 from public.chatbot_node_bridges b
          where b.organization_id = c.organization_id
            and b.organization_address = c.organization_address and b.engine <> 'native'
        )
        or exists (
          select 1 from public.chatbot_node_conversations m
          where m.organization_id = c.organization_id and m.conversation_id = c.id
            and m.organization_address = c.organization_address
            and (
              m.human_owned or m.pending_request_id is not null
              or m.support_request->>'status' = 'waiting'
              or (c.status in ('closed', 'spam') and m.state = 'closed'
                and (m.closed_at is not null or m.support_request->>'status' = 'resolved'))
            )
        )
      )
  );
$$;
revoke all on function public.is_support_inbox_visible(uuid,uuid) from public, anon;
grant execute on function public.is_support_inbox_visible(uuid,uuid) to authenticated, service_role;

create index chatbot_node_conversations_inbox_idx
  on public.chatbot_node_conversations(organization_id, conversation_id);

create function public.get_support_inbox_visibility(
  p_organization_id uuid, p_conversation_ids uuid[]
) returns table (conversation_id uuid, visible boolean)
language plpgsql stable security invoker set search_path = '' as $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.get_authorized_orgs('agent') a(id) where a.id = p_organization_id
  ) then
    raise exception 'organization is not accessible to the authenticated user' using errcode = '42501';
  end if;
  if p_conversation_ids is null or cardinality(p_conversation_ids) > 500 then
    raise exception 'provide at most 500 conversation IDs' using errcode = '22023';
  end if;
  return query select c.id, public.is_support_inbox_visible(c.organization_id,c.id)
    from public.conversations c
    where c.organization_id = p_organization_id and c.id = any(p_conversation_ids);
end;
$$;
revoke all on function public.get_support_inbox_visibility(uuid,uuid[]) from public, anon;
grant execute on function public.get_support_inbox_visibility(uuid,uuid[]) to authenticated;

-- Invalidate derived visibility even when assignment/status did not change.
-- Payloads deliberately contain no support context, secrets or ownership claims.
create function public.broadcast_support_inbox_change() returns trigger
language plpgsql security definer set search_path = '' as $$
declare context jsonb; previous jsonb;
begin
  context := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  if tg_op = 'UPDATE' then
    previous := to_jsonb(old);
    if tg_table_name = 'chatbot_node_conversations'
      and context - 'last_inbound_wamid' - 'ownership_revision'
        = previous - 'last_inbound_wamid' - 'ownership_revision' then
      return null;
    end if;
    if tg_table_name = 'chatbot_node_bridges'
      and context->'engine' = previous->'engine'
      and context->'organization_id' = previous->'organization_id'
      and context->'organization_address' = previous->'organization_address' then
      return null;
    end if;
  end if;
  perform realtime.send(jsonb_build_object(
    'organization_id', context->>'organization_id',
    'organization_address', context->>'organization_address',
    'conversation_id', context->>'conversation_id'
  ), 'conversation_inbox_changed', 'conversation-queue:' || (context->>'organization_id'), true);
  return null;
end;
$$;
revoke all on function public.broadcast_support_inbox_change() from public, anon, authenticated;
create trigger broadcast_node_conversation_inbox_change
  after insert or update or delete on public.chatbot_node_conversations
  for each row execute function public.broadcast_support_inbox_change();
create trigger broadcast_node_binding_inbox_change
  after insert or update or delete on public.chatbot_node_bridges
  for each row execute function public.broadcast_support_inbox_change();
