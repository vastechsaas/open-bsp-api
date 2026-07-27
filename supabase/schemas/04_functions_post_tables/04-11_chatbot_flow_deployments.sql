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
    or target_agent.extra->>'mode' = 'inactive'
  then
    raise exception using
      errcode = '23514',
      message = 'chatbot deployments require an active AI agent from the same organization';
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
