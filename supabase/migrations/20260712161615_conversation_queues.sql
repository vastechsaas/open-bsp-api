set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.get_conversation_queues(p_organization_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(key text, label text, "order" integer, enabled boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin
  if p_organization_id is not null
    and not exists (
      select 1
      from public.get_authorized_orgs('member') as authorized_orgs(id)
      where authorized_orgs.id = p_organization_id
    )
  then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  return query
  select
    q.key,
    q.label,
    q.sort_order as "order",
    q.enabled
  from (
    values
      ('all_active', 'All (active)', 1, true),
      ('assigned', 'Assigned', 2, true),
      ('pending', 'Pending', 3, true),
      ('spam', 'Spam', 4, true),
      ('closed', 'Closed', 5, true),
      ('expired', 'Expired', 6, true)
  ) as q(key, label, sort_order, enabled)
  order by q.sort_order;
end;
$function$
;
