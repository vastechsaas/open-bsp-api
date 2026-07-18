create or replace function public.list_message_templates_page(
  p_organization_id uuid,
  p_page integer default 1,
  p_page_size integer default 10,
  p_search text default null,
  p_organization_address text default null,
  p_category text default null,
  p_status text default null
) returns table (
  organization_id uuid,
  id uuid,
  organization_address text,
  created_by uuid,
  external_id text,
  name text,
  language text,
  category text,
  status text,
  components jsonb,
  rejection_reason text,
  submitted_at timestamp with time zone,
  synced_at timestamp with time zone,
  created_at timestamp with time zone,
  updated_at timestamp with time zone,
  total_count bigint
)
language plpgsql
stable
security invoker
set search_path to ''
as $$
declare
  normalized_page integer;
  normalized_page_size integer;
  normalized_search text;
  normalized_account text;
  normalized_category text;
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
  normalized_page_size := least(greatest(coalesce(p_page_size, 10), 1), 100);
  normalized_search := lower(btrim(coalesce(p_search, '')));
  normalized_account := nullif(btrim(coalesce(p_organization_address, '')), '');
  normalized_category := nullif(lower(btrim(coalesce(p_category, ''))), '');
  normalized_status := nullif(lower(btrim(coalesce(p_status, ''))), '');

  if normalized_category is not null
    and normalized_category not in ('utility', 'marketing', 'authentication')
  then
    raise exception using
      errcode = '22023',
      message = 'template category filter is invalid';
  end if;

  if normalized_status is not null
    and normalized_status not in (
      'draft',
      'pending',
      'approved',
      'in_appeal',
      'rejected',
      'pending_deletion',
      'deleted',
      'disabled',
      'paused',
      'limit_exceeded'
    )
  then
    raise exception using
      errcode = '22023',
      message = 'template status filter is invalid';
  end if;

  return query
  select
    template.organization_id,
    template.id,
    template.organization_address,
    template.created_by,
    template.external_id,
    template.name,
    template.language,
    template.category,
    template.status,
    template.components,
    template.rejection_reason,
    template.submitted_at,
    template.synced_at,
    template.created_at,
    template.updated_at,
    count(*) over() as total_count
  from public.message_templates template
  where template.organization_id = p_organization_id
    and (
      normalized_status is not null
      or template.status <> 'deleted'
    )
    and (
      normalized_account is null
      or template.organization_address = normalized_account
    )
    and (
      normalized_category is null
      or template.category = normalized_category
    )
    and (
      normalized_status is null
      or template.status = normalized_status
    )
    and (
      normalized_search = ''
      or position(normalized_search in lower(template.name)) > 0
      or position(
        normalized_search in lower(template.organization_address)
      ) > 0
    )
  order by template.updated_at desc, template.id desc
  offset (normalized_page - 1) * normalized_page_size
  limit normalized_page_size;
end;
$$;
