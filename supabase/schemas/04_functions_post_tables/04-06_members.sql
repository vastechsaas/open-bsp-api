create function public.list_members_page(
  p_organization_id uuid,
  p_page integer default 1,
  p_page_size integer default 10,
  p_search text default null,
  p_role public.role default null,
  p_status text default null
) returns table (
  organization_id uuid,
  id uuid,
  user_id uuid,
  name text,
  email text,
  picture text,
  role public.role,
  status text,
  is_last_owner boolean,
  created_at timestamp with time zone,
  updated_at timestamp with time zone,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path to ''
as $$
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
  normalized_page_size := least(greatest(coalesce(p_page_size, 10), 1), 50);
  normalized_search := lower(btrim(coalesce(p_search, '')));
  normalized_status := nullif(lower(btrim(coalesce(p_status, ''))), '');

  if normalized_status is not null
    and normalized_status not in ('active', 'pending', 'rejected')
  then
    raise exception using
      errcode = '22023',
      message = 'member status filter is invalid';
  end if;

  return query
  with members as (
    select
      agent.organization_id,
      agent.id,
      agent.user_id,
      agent.name,
      coalesce(
        nullif(agent.extra->'invitation'->>'email', ''),
        auth_user.email
      ) as email,
      agent.picture,
      case agent.extra->>'role'
        when 'owner' then 'owner'::public.role
        when 'admin' then 'admin'::public.role
        when 'supervisor' then 'supervisor'::public.role
        when 'agent' then 'agent'::public.role
        else 'member'::public.role
      end as role,
      case agent.extra->'invitation'->>'status'
        when 'pending' then 'pending'
        when 'rejected' then 'rejected'
        else 'active'
      end as status,
      count(*) filter (
        where agent.extra->>'role' = 'owner'
          and (
            agent.extra->'invitation' is null
            or agent.extra->'invitation'->>'status' = 'accepted'
          )
      ) over () as owner_count,
      agent.created_at,
      agent.updated_at
    from public.agents as agent
    left join auth.users as auth_user on auth_user.id = agent.user_id
    where agent.organization_id = p_organization_id
      and agent.ai = false
  ),
  filtered_members as (
    select member_row.*
    from members as member_row
    where (
      normalized_search = ''
      or lower(member_row.name) like '%' || normalized_search || '%'
      or lower(coalesce(member_row.email, '')) like '%' || normalized_search || '%'
    )
      and (p_role is null or member_row.role = p_role)
      and (normalized_status is null or member_row.status = normalized_status)
  )
  select
    member.organization_id,
    member.id,
    member.user_id,
    member.name,
    member.email,
    member.picture,
    member.role,
    member.status,
    member.role = 'owner'::public.role
      and member.status = 'active'
      and member.owner_count = 1 as is_last_owner,
    member.created_at,
    member.updated_at,
    count(*) over() as total_count
  from filtered_members as member
  order by member.updated_at desc, member.id desc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$$;

revoke execute on function public.list_members_page(
  uuid,
  integer,
  integer,
  text,
  public.role,
  text
) from public;

grant execute on function public.list_members_page(
  uuid,
  integer,
  integer,
  text,
  public.role,
  text
) to authenticated;
