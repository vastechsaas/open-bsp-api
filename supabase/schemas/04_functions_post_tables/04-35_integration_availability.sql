-- Internal boolean also used by the onboarding-token INSERT policy. It reveals
-- no settings for organizations outside the caller's existing authorization.
create function public.is_integration_available(p_organization_id uuid, p_integration_id text)
returns boolean language sql stable security definer set search_path to '' as $$
  select coalesce((select coalesce(a.enabled, c.default_enabled)
    from public.integration_catalogue c
    left join public.organization_integration_availability a
      on a.integration_id = c.id and a.organization_id = p_organization_id
    where c.id = p_integration_id
      and (auth.role() = 'service_role' or public.get_request_organization_role(p_organization_id) is not null)), false);
$$;

create function public.get_effective_integration_availability(p_organization_id uuid)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if auth.uid() is null or public.get_request_organization_role(p_organization_id) is null then
    raise exception using errcode = '42501', message = 'Organization access required';
  end if;
  return jsonb_build_object('revision', coalesce((select revision from public.organization_integration_settings where organization_id = p_organization_id), 0),
    'integrations', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name,
      'enabled', coalesce(a.enabled,c.default_enabled)) order by c.id), '[]'::jsonb)
      from public.integration_catalogue c left join public.organization_integration_availability a
      on a.integration_id = c.id and a.organization_id = p_organization_id));
end;
$$;

create function public.get_platform_integration_availability(p_organization_id uuid)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  perform public.require_platform_admin();
  if not exists (select 1 from public.organizations where id = p_organization_id) then
    raise exception using errcode = 'P0002', message = 'Organization not found'; end if;
  return jsonb_build_object('revision', coalesce((select revision from public.organization_integration_settings where organization_id = p_organization_id), 0),
    'integrations', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name,
      'enabled', coalesce(a.enabled,c.default_enabled), 'connected_count', coalesce(n.total,0)) order by c.id), '[]'::jsonb)
      from public.integration_catalogue c left join public.organization_integration_availability a
      on a.integration_id = c.id and a.organization_id = p_organization_id
      left join (select service::text as integration_id, count(*) as total from public.organizations_addresses
        where organization_id = p_organization_id and status = 'connected' group by service) n on n.integration_id = c.id));
end;
$$;

create function public.update_platform_integration_availability(p_organization_id uuid, p_integrations jsonb, p_expected_revision bigint, p_request_id uuid)
returns jsonb language plpgsql volatile security definer set search_path to '' as $$
declare actor uuid; previous jsonb; result jsonb; existing public.platform_admin_action_events; current_revision bigint;
begin
  actor := public.require_platform_admin();
  if p_request_id is null or p_expected_revision is null or jsonb_typeof(p_integrations) is distinct from 'array' then
    raise exception using errcode = '22023', message = 'Integrations, revision and request ID are required'; end if;
  if jsonb_array_length(p_integrations) <> (select count(*) from public.integration_catalogue)
    or (select count(distinct item->>'id') from jsonb_array_elements(p_integrations) item) <> jsonb_array_length(p_integrations)
    or exists (select 1 from jsonb_array_elements(p_integrations) item
      where jsonb_typeof(item->'enabled') is distinct from 'boolean'
        or not exists (select 1 from public.integration_catalogue c where c.id = item->>'id')) then
    raise exception using errcode = '22023', message = 'Complete supported integration settings required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':' || p_request_id::text, 0));
  select * into existing from public.platform_admin_action_events where platform_admin_user_id = actor and request_id = p_request_id;
  if found then
    if existing.action_type <> 'organization_integrations.update' or existing.organization_id <> p_organization_id
      or existing.after_state->'request_integrations' is distinct from p_integrations
      or (existing.after_state->>'expected_revision')::bigint is distinct from p_expected_revision then
      raise exception using errcode = '22023', message = 'Request ID already used for a different action'; end if;
    return existing.after_state->'result';
  end if;
  insert into public.organization_integration_settings(organization_id) values (p_organization_id) on conflict do nothing;
  select revision into current_revision from public.organization_integration_settings where organization_id = p_organization_id for update;
  if current_revision <> p_expected_revision then raise exception using errcode = '40001', message = 'Integration settings changed. Reload before saving.'; end if;
  previous := public.get_platform_integration_availability(p_organization_id);
  insert into public.organization_integration_availability(organization_id, integration_id, enabled)
    select p_organization_id, item->>'id', (item->>'enabled')::boolean from jsonb_array_elements(p_integrations) item
    on conflict (organization_id,integration_id) do update set enabled = excluded.enabled;
  update public.organization_integration_settings set revision = revision + 1, updated_at = now() where organization_id = p_organization_id;
  result := public.get_platform_integration_availability(p_organization_id);
  insert into public.platform_admin_action_events(platform_admin_user_id, organization_id, action_type, target_type, target_id, request_id, before_state, after_state)
    values (actor,p_organization_id,'organization_integrations.update','organization_integrations',p_organization_id::text,p_request_id,previous,
      jsonb_build_object('result',result,'request_integrations',p_integrations,'expected_revision',p_expected_revision));
  perform realtime.send('{}'::jsonb, 'integration-availability', 'integration-availability:' || p_organization_id::text, true);
  return result;
end;
$$;

revoke all on function public.is_integration_available(uuid,text), public.get_effective_integration_availability(uuid), public.get_platform_integration_availability(uuid), public.update_platform_integration_availability(uuid,jsonb,bigint,uuid) from public;
grant execute on function public.is_integration_available(uuid,text) to authenticated, anon, service_role;
grant execute on function public.get_effective_integration_availability(uuid), public.get_platform_integration_availability(uuid), public.update_platform_integration_availability(uuid,jsonb,bigint,uuid) to authenticated;

create policy "organization users receive integration availability changes" on realtime.messages
for select to authenticated using (
  realtime.messages.extension = 'broadcast' and realtime.messages.topic = realtime.topic()
  and exists (select 1 from public.get_authorized_orgs('agent') org(id)
    where realtime.topic() = 'integration-availability:' || org.id::text)
);
