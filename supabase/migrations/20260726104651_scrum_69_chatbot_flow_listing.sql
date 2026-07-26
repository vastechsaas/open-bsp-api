set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.list_chatbot_flows_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, id uuid, created_by uuid, created_by_name text, name text, status text, created_at timestamp with time zone, updated_at timestamp with time zone, draft_id uuid, draft_version integer, draft_updated_at timestamp with time zone, published_version_id uuid, published_version integer, published_at timestamp with time zone, has_unpublished_changes boolean, total_count bigint)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  normalized_page integer;
  normalized_page_size integer;
  normalized_search text;
  normalized_status text;
begin
  if not exists (
    select 1
    from public.get_authorized_orgs('member') as authorized_orgs(id)
    where authorized_orgs.id = p_organization_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  normalized_page := greatest(coalesce(p_page, 1), 1);
  normalized_page_size := least(
    greatest(coalesce(p_page_size, 10), 1),
    50
  );
  normalized_search := lower(btrim(coalesce(p_search, '')));
  normalized_status := nullif(lower(btrim(coalesce(p_status, ''))), '');

  if normalized_status is not null
    and normalized_status not in ('active', 'archived')
  then
    raise exception using
      errcode = '22023',
      message = 'chatbot flow status filter is invalid';
  end if;

  return query
  with listed as materialized (
    select
      flow.organization_id,
      flow.id,
      flow.created_by,
      creator.name as created_by_name,
      flow.name,
      flow.status,
      flow.created_at,
      greatest(
        flow.updated_at,
        coalesce(draft.updated_at, flow.updated_at),
        coalesce(published.updated_at, flow.updated_at)
      ) as updated_at,
      draft.id as draft_id,
      draft.version as draft_version,
      draft.updated_at as draft_updated_at,
      published.id as published_version_id,
      published.version as published_version,
      published.published_at,
      case
        when draft.id is null then false
        when published.id is null then true
        else draft.editor_graph is distinct from published.editor_graph
      end as has_unpublished_changes
    from public.chatbot_flows as flow
    left join public.agents as creator
      on creator.organization_id = flow.organization_id
      and creator.id = flow.created_by
    left join lateral (
      select
        version.id,
        version.version,
        version.editor_graph,
        version.updated_at
      from public.chatbot_flow_versions as version
      where version.organization_id = flow.organization_id
        and version.flow_id = flow.id
        and version.status = 'draft'
      order by version.version desc, version.id desc
      limit 1
    ) as draft on true
    left join lateral (
      select
        version.id,
        version.version,
        version.editor_graph,
        version.published_at,
        version.updated_at
      from public.chatbot_flow_versions as version
      where version.organization_id = flow.organization_id
        and version.flow_id = flow.id
        and version.status = 'published'
      order by version.version desc, version.id desc
      limit 1
    ) as published on true
    where flow.organization_id = p_organization_id
      and (
        normalized_status is null
        or flow.status = normalized_status
      )
      and (
        normalized_search = ''
        or position(normalized_search in lower(flow.name)) > 0
      )
  )
  select
    listed.organization_id,
    listed.id,
    listed.created_by,
    listed.created_by_name,
    listed.name,
    listed.status,
    listed.created_at,
    listed.updated_at,
    listed.draft_id,
    listed.draft_version,
    listed.draft_updated_at,
    listed.published_version_id,
    listed.published_version,
    listed.published_at,
    listed.has_unpublished_changes,
    count(*) over() as total_count
  from listed
  order by listed.updated_at desc, listed.id desc
  offset (normalized_page - 1) * normalized_page_size
  limit normalized_page_size;
end;
$function$
;


