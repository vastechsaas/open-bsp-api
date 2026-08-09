create function public.list_contacts_page(
  p_organization_id uuid,
  p_page integer default 1,
  p_page_size integer default 10,
  p_search text default null
) returns table (
  organization_id uuid,
  id uuid,
  name text,
  email text,
  company text,
  job_title text,
  city text,
  country text,
  status text,
  addresses jsonb,
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
begin
  if not exists (
    select 1
    from public.get_authorized_orgs('agent') as authorized_orgs(id)
    where authorized_orgs.id = p_organization_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  normalized_page := greatest(coalesce(p_page, 1), 1);
  normalized_page_size := least(greatest(coalesce(p_page_size, 10), 1), 50);
  normalized_search := lower(btrim(coalesce(p_search, '')));

  return query
  with listed as materialized (
    select
      contact.organization_id,
      contact.id,
      contact.name,
      contact.email,
      contact.company,
      contact.job_title,
      contact.city,
      contact.country,
      contact.status,
      coalesce(contact_channels.addresses, '[]'::jsonb) as addresses,
      contact.created_at,
      contact.updated_at
    from public.contacts as contact
    left join lateral (
      select
        jsonb_agg(
          jsonb_build_object(
            'service', contact_address.service,
            'address', coalesce(
              nullif(contact_address.extra->>'phone_number', ''),
              contact_address.address
            ),
            'raw_address', contact_address.address,
            'name', contact_address.extra->>'name',
            'username', contact_address.extra->>'username'
          )
          order by
            case when contact_address.status = 'active' then 0 else 1 end,
            contact_address.created_at,
            contact_address.address
        ) as addresses,
        string_agg(
          lower(
            concat_ws(
              ' ',
              contact_address.address,
              contact_address.extra->>'phone_number',
              contact_address.extra->>'name',
              contact_address.extra->>'username'
            )
          ),
          ' '
        ) as search_text
      from public.contacts_addresses as contact_address
      where contact_address.organization_id = contact.organization_id
        and contact_address.contact_id = contact.id
    ) as contact_channels on true
    where contact.organization_id = p_organization_id
      and (
        normalized_search = ''
        or position(
          normalized_search in lower(
            concat_ws(
              ' ',
              contact.name,
              contact.email,
              contact.company,
              contact.job_title,
              contact.city,
              contact.country,
              contact_channels.search_text
            )
          )
        ) > 0
      )
  )
  select
    listed.organization_id,
    listed.id,
    listed.name,
    listed.email,
    listed.company,
    listed.job_title,
    listed.city,
    listed.country,
    listed.status,
    listed.addresses,
    listed.created_at,
    listed.updated_at,
    count(*) over() as total_count
  from listed
  order by listed.updated_at desc, listed.id desc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$$;

revoke execute on function public.list_contacts_page(
  uuid,
  integer,
  integer,
  text
) from public;

grant execute on function public.list_contacts_page(
  uuid,
  integer,
  integer,
  text
) to authenticated;
