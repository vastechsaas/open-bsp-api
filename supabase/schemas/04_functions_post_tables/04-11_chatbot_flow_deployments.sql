create function public.ensure_chatbot_runtime_agent(
  p_organization_id uuid
) returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  runtime_agent_id uuid;
begin
  select agent.id
  into runtime_agent_id
  from public.agents as agent
  where agent.organization_id = p_organization_id
    and agent.ai = true
    and agent.extra->>'kind' = 'chatbot_runtime'
  limit 1;

  if runtime_agent_id is not null then
    return runtime_agent_id;
  end if;

  begin
    insert into public.agents (
      organization_id,
      name,
      ai,
      extra
    ) values (
      p_organization_id,
      'Chatbot Runtime',
      true,
      jsonb_build_object(
        'kind', 'chatbot_runtime',
        'mode', 'active',
        'system', true
      )
    )
    returning id into runtime_agent_id;
  exception
    when unique_violation then
      select agent.id
      into runtime_agent_id
      from public.agents as agent
      where agent.organization_id = p_organization_id
        and agent.ai = true
        and agent.extra->>'kind' = 'chatbot_runtime';
  end;

  return runtime_agent_id;
end;
$$;

revoke execute on function public.ensure_chatbot_runtime_agent(uuid)
from public, anon, authenticated;
grant execute on function public.ensure_chatbot_runtime_agent(uuid)
to service_role;

create function public.validate_chatbot_flow_deployment() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  target_version public.chatbot_flow_versions;
  target_agent public.agents;
begin
  if not exists (
    select 1
    from public.organizations_addresses as address
    where address.organization_id = new.organization_id
      and address.address = new.organization_address
      and address.service = 'whatsapp'::public.service
      and address.status = 'connected'
  ) then
    raise exception using
      errcode = '23514',
      message = 'chatbot deployments require a connected WhatsApp address';
  end if;

  if not exists (
    select 1
    from public.chatbot_flows as flow
    where flow.organization_id = new.organization_id
      and flow.id = new.flow_id
      and flow.status = 'active'
  ) then
    raise exception using
      errcode = '23514',
      message = 'chatbot deployments require an active flow from the same organization';
  end if;

  select * into target_version
  from public.chatbot_flow_versions as version
  where version.organization_id = new.organization_id
    and version.id = new.flow_version_id;

  if not found
    or target_version.flow_id <> new.flow_id
    or target_version.status <> 'published'
  then
    raise exception using
      errcode = '23514',
      message = 'chatbot deployments require a published version of the selected flow';
  end if;

  select * into target_agent
  from public.agents as agent
  where agent.organization_id = new.organization_id
    and agent.id = new.agent_id;

  if not found
    or target_agent.ai is distinct from true
    or target_agent.extra->>'kind' is distinct from 'chatbot_runtime'
    or target_agent.extra->>'mode' = 'inactive'
  then
    raise exception using
      errcode = '23514',
      message = 'chatbot deployments require the organization chatbot runtime identity';
  end if;

  if new.activated_by is not null and not exists (
    select 1
    from public.agents as actor
    where actor.organization_id = new.organization_id
      and actor.id = new.activated_by
      and actor.ai = false
  ) then
    raise exception using
      errcode = '23514',
      message = 'chatbot deployment actor must be a human agent from the same organization';
  end if;

  return new;
end;
$$;

create trigger validate_chatbot_flow_deployment
before insert or update
on public.chatbot_flow_deployments
for each row
execute function public.validate_chatbot_flow_deployment();
