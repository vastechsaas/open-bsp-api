drop policy "admins can update chatbot flow drafts" on "public"."chatbot_flow_versions";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.create_chatbot_flow_draft(p_organization_id uuid, p_name text, p_created_by uuid DEFAULT NULL::uuid)
 RETURNS TABLE(flow_id uuid, draft_id uuid, draft_version integer, draft_updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  created_flow public.chatbot_flows;
  created_draft public.chatbot_flow_versions;
begin
  if p_name is null or length(btrim(p_name)) = 0 then
    raise exception using
      errcode = '22023',
      message = 'chatbot flow name cannot be blank';
  end if;

  insert into public.chatbot_flows (
    organization_id,
    created_by,
    name
  ) values (
    p_organization_id,
    p_created_by,
    btrim(p_name)
  )
  returning * into created_flow;

  insert into public.chatbot_flow_versions (
    organization_id,
    flow_id,
    created_by,
    version
  ) values (
    p_organization_id,
    created_flow.id,
    p_created_by,
    1
  )
  returning * into created_draft;

  return query select
    created_flow.id,
    created_draft.id,
    created_draft.version,
    created_draft.updated_at;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.duplicate_chatbot_flow_draft(p_organization_id uuid, p_source_flow_id uuid, p_name text, p_created_by uuid DEFAULT NULL::uuid)
 RETURNS TABLE(flow_id uuid, draft_id uuid, draft_version integer, draft_updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  source_graph jsonb;
  created_flow public.chatbot_flows;
  created_draft public.chatbot_flow_versions;
begin
  if p_name is null or length(btrim(p_name)) = 0 then
    raise exception using
      errcode = '22023',
      message = 'chatbot flow name cannot be blank';
  end if;

  perform 1
  from public.chatbot_flows as flow
  where flow.organization_id = p_organization_id
    and flow.id = p_source_flow_id
  for share;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'source chatbot flow not found';
  end if;

  select version.editor_graph
  into source_graph
  from public.chatbot_flow_versions as version
  where version.organization_id = p_organization_id
    and version.flow_id = p_source_flow_id
  order by
    case when version.status = 'draft' then 0 else 1 end,
    version.version desc
  limit 1;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'source chatbot flow has no version to duplicate';
  end if;

  insert into public.chatbot_flows (
    organization_id,
    created_by,
    name
  ) values (
    p_organization_id,
    p_created_by,
    btrim(p_name)
  )
  returning * into created_flow;

  insert into public.chatbot_flow_versions (
    organization_id,
    flow_id,
    created_by,
    version,
    editor_graph
  ) values (
    p_organization_id,
    created_flow.id,
    p_created_by,
    1,
    source_graph
  )
  returning * into created_draft;

  return query select
    created_flow.id,
    created_draft.id,
    created_draft.version,
    created_draft.updated_at;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.publish_chatbot_flow_draft(p_organization_id uuid, p_flow_id uuid, p_version_id uuid, p_expected_updated_at timestamp with time zone, p_definition jsonb, p_created_by uuid DEFAULT NULL::uuid)
 RETURNS TABLE(outcome text, published_version_id uuid, published_version integer, draft_id uuid, draft_version integer, draft_updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  target_draft public.chatbot_flow_versions;
  next_draft public.chatbot_flow_versions;
begin
  select *
  into target_draft
  from public.chatbot_flow_versions as version
  where version.organization_id = p_organization_id
    and version.flow_id = p_flow_id
    and version.id = p_version_id
    and version.status = 'draft'
  for update;

  if not found then
    return query select
      'not_found'::text,
      null::uuid,
      null::integer,
      null::uuid,
      null::integer,
      null::timestamp with time zone;
    return;
  end if;

  if target_draft.updated_at is distinct from p_expected_updated_at then
    return query select
      'conflict'::text,
      null::uuid,
      null::integer,
      target_draft.id,
      target_draft.version,
      target_draft.updated_at;
    return;
  end if;

  if p_definition is null or jsonb_typeof(p_definition) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'compiled chatbot definition must be a JSON object';
  end if;

  update public.chatbot_flow_versions as version
  set
    status = 'published',
    definition = p_definition,
    published_at = now()
  where version.id = target_draft.id
  returning * into target_draft;

  insert into public.chatbot_flow_versions (
    organization_id,
    flow_id,
    created_by,
    version,
    editor_graph
  ) values (
    p_organization_id,
    p_flow_id,
    p_created_by,
    target_draft.version + 1,
    target_draft.editor_graph
  )
  returning * into next_draft;

  return query select
    'published'::text,
    target_draft.id,
    target_draft.version,
    next_draft.id,
    next_draft.version,
    next_draft.updated_at;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.touch_chatbot_flow_from_version()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'DELETE' then
    update public.chatbot_flows
    set updated_at = now()
    where organization_id = old.organization_id
      and id = old.flow_id;

    return old;
  end if;

  update public.chatbot_flows
  set updated_at = now()
  where organization_id = new.organization_id
    and id = new.flow_id;

  return new;
end;
$function$
;


  create policy "admins can update chatbot flow drafts"
  on "public"."chatbot_flow_versions"
  as permissive
  for update
  to authenticated, anon
using (((organization_id IN ( SELECT public.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)) AND (status = 'draft'::text)))
with check (((organization_id IN ( SELECT public.get_authorized_orgs('admin'::public.role) AS get_authorized_orgs)) AND (status = 'draft'::text)));


CREATE TRIGGER touch_chatbot_flow_from_version AFTER INSERT OR DELETE OR UPDATE ON public.chatbot_flow_versions FOR EACH ROW EXECUTE FUNCTION public.touch_chatbot_flow_from_version();

revoke execute on function public.create_chatbot_flow_draft(
  uuid,
  text,
  uuid
) from public, anon, authenticated;
grant execute on function public.create_chatbot_flow_draft(
  uuid,
  text,
  uuid
) to service_role;

revoke execute on function public.duplicate_chatbot_flow_draft(
  uuid,
  uuid,
  text,
  uuid
) from public, anon, authenticated;
grant execute on function public.duplicate_chatbot_flow_draft(
  uuid,
  uuid,
  text,
  uuid
) to service_role;

revoke execute on function public.publish_chatbot_flow_draft(
  uuid,
  uuid,
  uuid,
  timestamp with time zone,
  jsonb,
  uuid
) from public, anon, authenticated;
grant execute on function public.publish_chatbot_flow_draft(
  uuid,
  uuid,
  uuid,
  timestamp with time zone,
  jsonb,
  uuid
) to service_role;
