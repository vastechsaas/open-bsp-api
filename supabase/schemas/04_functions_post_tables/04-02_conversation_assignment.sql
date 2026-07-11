create function public.enforce_human_conversation_assignee() returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if new.assigned_agent_id is null then
    return new;
  end if;

  if not exists (
    select 1
    from public.agents
    where id = new.assigned_agent_id
      and organization_id = new.organization_id
      and ai = false
      and user_id is not null
  ) then
    raise exception 'Conversation assignee must be a human agent in the same organization'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger enforce_human_conversation_assignee
before insert or update of assigned_agent_id, organization_id
on public.conversations
for each row
execute function public.enforce_human_conversation_assignee();
