drop policy "supervisors can delete members" on "public"."agents";

drop policy "supervisors can send member invitations" on "public"."agents";

drop policy "supervisors can update members" on "public"."agents";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.agent_can_download_media_object(p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1
    from public.messages m
    cross join lateral jsonb_path_query(m.content, '$.**') as content_value
    where content_value = to_jsonb('internal://media/' || p_name)
      and public.agent_can_read_conversation(m.organization_id, m.conversation_id)
  );
$function$
;

CREATE OR REPLACE FUNCTION public.agent_can_read_conversation(p_organization_id uuid, p_conversation_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select public.get_request_organization_role(p_organization_id) = 'agent'::public.role
    and exists (
      select 1
      from public.conversations c
      where c.id = p_conversation_id
        and c.organization_id = p_organization_id
        and c.status = 'active'
        and (
          c.assigned_agent_id is null
          or c.assigned_agent_id = public.get_current_human_agent_id(p_organization_id)
        )
    );
$function$
;

CREATE OR REPLACE FUNCTION public.agent_conversation_update_rules(p_id uuid, p_organization_id uuid, p_service public.service, p_organization_address text, p_contact_address text, p_group_address text, p_assigned_agent_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1
    from public.conversations c
    where c.id = p_id
      and c.organization_id = p_organization_id
      and c.service = p_service
      and c.organization_address = p_organization_address
      and c.contact_address is not distinct from p_contact_address
      and c.group_address is not distinct from p_group_address
      and c.assigned_agent_id = p_assigned_agent_id
      and c.assigned_agent_id = public.get_current_human_agent_id(p_organization_id)
  );
$function$
;

CREATE OR REPLACE FUNCTION public.agent_message_insert_rules(p_organization_id uuid, p_conversation_id uuid, p_agent_id uuid, p_direction public.direction, p_service public.service, p_organization_address text, p_group_address text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select public.get_request_organization_role(p_organization_id) = 'agent'::public.role
    and p_direction = 'outgoing'::public.direction
    and p_agent_id = public.get_current_human_agent_id(p_organization_id)
    and exists (
      select 1
      from public.conversations c
      where c.id = p_conversation_id
        and c.organization_id = p_organization_id
        and c.status = 'active'
        and c.assigned_agent_id = p_agent_id
        and c.service = p_service
        and c.organization_address = p_organization_address
        and c.group_address is not distinct from p_group_address
    );
$function$
;

CREATE OR REPLACE FUNCTION public.agent_owns_conversation(p_organization_id uuid, p_conversation_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select public.get_request_organization_role(p_organization_id) = 'agent'::public.role
    and exists (
      select 1
      from public.conversations c
      where c.id = p_conversation_id
        and c.organization_id = p_organization_id
        and c.status = 'active'
        and c.assigned_agent_id = public.get_current_human_agent_id(p_organization_id)
    );
$function$
;

CREATE OR REPLACE FUNCTION public.create_conversation_for_me(p_organization_id uuid, p_service public.service, p_organization_address text, p_contact_address text DEFAULT NULL::text, p_group_address text DEFAULT NULL::text, p_name text DEFAULT NULL::text, p_extra jsonb DEFAULT NULL::jsonb)
 RETURNS public.conversations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  current_agent_id uuid;
  created_conversation public.conversations;
begin
  if public.get_request_organization_role(p_organization_id) <> 'agent'::public.role then
    raise exception using
      errcode = '42501',
      message = 'only an accepted Agent can create a self-assigned conversation';
  end if;

  current_agent_id := public.get_current_human_agent_id(p_organization_id);
  if current_agent_id is null then
    raise exception using
      errcode = '42501',
      message = 'authenticated Agent membership is not available';
  end if;

  insert into public.conversations (
    organization_id,
    service,
    organization_address,
    contact_address,
    group_address,
    name,
    assigned_agent_id,
    extra,
    status
  ) values (
    p_organization_id,
    p_service,
    p_organization_address,
    p_contact_address,
    p_group_address,
    p_name,
    current_agent_id,
    p_extra,
    'active'
  )
  returning * into created_conversation;

  return created_conversation;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_current_human_agent_id(p_organization_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select a.id
  from public.agents a
  where a.organization_id = p_organization_id
    and a.user_id = auth.uid()
    and a.ai = false
    and (
      a.extra->'invitation' is null
      or a.extra->'invitation'->>'status' = 'accepted'
    )
  limit 1;
$function$
;

CREATE OR REPLACE FUNCTION public.get_request_organization_role(p_organization_id uuid)
 RETURNS public.role
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  request_role public.role;
  api_key text;
begin
  if auth.uid() is not null then
    select (a.extra->>'role')::public.role into request_role
    from public.agents a
    where a.organization_id = p_organization_id
      and a.user_id = auth.uid()
      and a.ai = false
      and (
        a.extra->'invitation' is null
        or a.extra->'invitation'->>'status' = 'accepted'
      )
      and a.extra->>'role' in ('owner', 'admin', 'supervisor', 'member', 'agent')
    limit 1;

    return request_role;
  end if;

  api_key := current_setting('request.headers', true)::json->>'api-key';
  if api_key is not null then
    select a.role into request_role
    from public.api_keys a
    where a.organization_id = p_organization_id
      and a.key = api_key;
  end if;

  return request_role;
exception
  when invalid_text_representation then
    return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.role_rank(role public.role)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case role
    when 'owner'::public.role then 5
    when 'admin'::public.role then 4
    when 'supervisor'::public.role then 3
    when 'member'::public.role then 2
    when 'agent'::public.role then 1
    else 0
  end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_conversation_agent_assignment(p_conversation_id uuid, p_agent_id uuid)
 RETURNS public.conversations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  target_conversation public.conversations;
  caller_role public.role;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'authentication required';
  end if;

  select c.* into target_conversation
  from public.conversations c
  where c.id = p_conversation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'conversation not found';
  end if;

  caller_role := public.get_request_organization_role(
    target_conversation.organization_id
  );

  if caller_role not in (
    'owner'::public.role,
    'admin'::public.role,
    'supervisor'::public.role
  ) then
    raise exception using
      errcode = '42501',
      message = 'only owners, admins, and supervisors can manage Agent assignments';
  end if;

  if target_conversation.assigned_agent_id is not null
    and not exists (
      select 1
      from public.agents a
      where a.id = target_conversation.assigned_agent_id
        and a.organization_id = target_conversation.organization_id
        and a.ai = false
        and a.user_id is not null
        and a.extra->>'role' = 'agent'
        and (
          a.extra->'invitation' is null
          or a.extra->'invitation'->>'status' = 'accepted'
        )
    )
  then
    raise exception using
      errcode = '42501',
      message = 'conversations assigned to non-Agent users cannot be reassigned';
  end if;

  if p_agent_id is not null
    and not exists (
      select 1
      from public.agents a
      where a.id = p_agent_id
        and a.organization_id = target_conversation.organization_id
        and a.ai = false
        and a.user_id is not null
        and a.extra->>'role' = 'agent'
        and (
          a.extra->'invitation' is null
          or a.extra->'invitation'->>'status' = 'accepted'
        )
    )
  then
    raise exception using
      errcode = '23514',
      message = 'assignee must be an accepted Agent in the same organization';
  end if;

  update public.conversations
  set assigned_agent_id = p_agent_id
  where id = p_conversation_id
  returning * into target_conversation;

  return target_conversation;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.assign_conversation_to_me(p_conversation_id uuid)
 RETURNS public.conversations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  updated_conversation public.conversations;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'authentication required';
  end if;

  update public.conversations c
  set assigned_agent_id = a.id
  from public.agents a
  where c.id = p_conversation_id
    and c.assigned_agent_id is null
    and c.organization_id in (
      select public.get_authorized_orgs('agent')
    )
    and (
      public.get_request_organization_role(c.organization_id) <> 'agent'::public.role
      or c.status = 'active'
    )
    and a.organization_id = c.organization_id
    and a.user_id = auth.uid()
    and a.ai = false
  returning c.* into updated_conversation;

  if found then
    return updated_conversation;
  end if;

  if not exists (
    select 1
    from public.conversations
    where id = p_conversation_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'conversation not found';
  end if;

  if not exists (
    select 1
    from public.conversations
    where id = p_conversation_id
      and organization_id in (
        select public.get_authorized_orgs('agent')
      )
  ) then
    raise exception using
      errcode = '42501',
      message = 'conversation is not accessible to the authenticated user';
  end if;

  if not exists (
    select 1
    from public.agents a
    join public.conversations c
      on c.organization_id = a.organization_id
    where c.id = p_conversation_id
      and a.user_id = auth.uid()
      and a.ai = false
  ) then
    raise exception using
      errcode = '23514',
      message = 'authenticated user is not a human agent in the conversation organization';
  end if;

  raise exception using
    errcode = '23505',
    message = 'conversation is already assigned';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_authorized_orgs(role public.role DEFAULT 'member'::public.role)
 RETURNS SETOF uuid
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select public.get_authorized_orgs_by_roles(
    case role
      when 'owner'::public.role then array['owner']::public.role[]
      when 'admin'::public.role then array['owner', 'admin']::public.role[]
      when 'supervisor'::public.role then array['owner', 'admin', 'supervisor']::public.role[]
      when 'member'::public.role then array['owner', 'admin', 'supervisor', 'member']::public.role[]
      when 'agent'::public.role then array['owner', 'admin', 'supervisor', 'member', 'agent']::public.role[]
      else array[]::public.role[]
    end
  );
$function$
;

CREATE OR REPLACE FUNCTION public.get_conversation_queue_conversations(p_organization_id uuid, p_queue_key text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS SETOF public.conversations
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  normalized_limit integer;
  normalized_offset integer;
  request_role public.role;
  current_agent_id uuid;
begin
  if p_organization_id is null then
    raise exception using
      errcode = '22004',
      message = 'organization id is required';
  end if;

  if p_queue_key is null or p_queue_key not in (
    'all_active',
    'assigned',
    'pending',
    'spam',
    'closed',
    'expired'
  ) then
    raise exception using
      errcode = '22023',
      message = 'invalid conversation queue key';
  end if;

  if not exists (
    select 1
    from public.get_authorized_orgs('agent') as authorized_orgs(id)
    where authorized_orgs.id = p_organization_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  request_role := public.get_request_organization_role(p_organization_id);
  current_agent_id := public.get_current_human_agent_id(p_organization_id);

  if request_role = 'agent'::public.role
    and p_queue_key not in ('pending', 'assigned')
  then
    raise exception using
      errcode = '42501',
      message = 'conversation queue is not available to Agent users';
  end if;

  normalized_limit := least(greatest(coalesce(p_limit, 50), 1), 500);
  normalized_offset := greatest(coalesce(p_offset, 0), 0);

  return query
  select c.*
  from public.conversations c
  left join lateral (
    select max(m.timestamp) as latest_incoming_at
    from public.messages m
    where m.organization_id = c.organization_id
      and m.conversation_id = c.id
      and m.direction = 'incoming'::public.direction
  ) incoming on true
  where c.organization_id = p_organization_id
    and (
      (
        p_queue_key = 'all_active'
        and c.status = 'active'
      )
      or (
        p_queue_key = 'assigned'
        and c.status = 'active'
        and c.assigned_agent_id is not null
        and (
          request_role <> 'agent'::public.role
          or c.assigned_agent_id = current_agent_id
        )
      )
      or (
        p_queue_key = 'pending'
        and c.status = 'active'
        and c.assigned_agent_id is null
      )
      or (
        p_queue_key = 'spam'
        and c.status = 'spam'
      )
      or (
        p_queue_key = 'closed'
        and c.status = 'closed'
      )
      or (
        p_queue_key = 'expired'
        and c.status = 'active'
        and incoming.latest_incoming_at <= now() - interval '24 hours'
      )
    )
  order by c.updated_at desc, c.id desc
  limit normalized_limit
  offset normalized_offset;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_conversation_queues(p_organization_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(key text, label text, "order" integer, enabled boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  request_role public.role;
begin
  if p_organization_id is not null
    and not exists (
      select 1
      from public.get_authorized_orgs('agent') as authorized_orgs(id)
      where authorized_orgs.id = p_organization_id
    )
  then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  request_role := case
    when p_organization_id is null then null
    else public.get_request_organization_role(p_organization_id)
  end;

  if request_role = 'agent'::public.role then
    return query
    select q.key, q.label, q.sort_order as "order", q.enabled
    from (
      values
        ('pending', 'Pending', 1, true),
        ('assigned', 'Assigned', 2, true)
    ) as q(key, label, sort_order, enabled)
    order by q.sort_order;
    return;
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

CREATE OR REPLACE FUNCTION public.list_members_page(p_organization_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 10, p_search text DEFAULT NULL::text, p_role public.role DEFAULT NULL::public.role, p_status text DEFAULT NULL::text)
 RETURNS TABLE(organization_id uuid, id uuid, user_id uuid, name text, email text, picture text, role public.role, status text, is_last_owner boolean, created_at timestamp with time zone, updated_at timestamp with time zone, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
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
$function$
;

CREATE OR REPLACE FUNCTION public.member_update_by_supervisor_rules(p_id uuid, p_user_id uuid, p_organization_id uuid, p_ai boolean, p_extra jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  return exists (
    select 1 from public.agents
    where id = p_id
      and user_id is not distinct from p_user_id
      and organization_id = p_organization_id
      and ai = false
      and p_ai = false
      and extra->>'role' in ('member', 'agent')
      and extra is not distinct from p_extra
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.unassign_conversation_from_me(p_conversation_id uuid)
 RETURNS public.conversations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  updated_conversation public.conversations;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'authentication required';
  end if;

  update public.conversations c
  set assigned_agent_id = null
  from public.agents a
  where c.id = p_conversation_id
    and c.assigned_agent_id = a.id
    and c.organization_id in (
      select public.get_authorized_orgs('agent')
    )
    and (
      public.get_request_organization_role(c.organization_id) <> 'agent'::public.role
      or c.status = 'active'
    )
    and a.organization_id = c.organization_id
    and a.user_id = auth.uid()
    and a.ai = false
  returning c.* into updated_conversation;

  if found then
    return updated_conversation;
  end if;

  if not exists (
    select 1
    from public.conversations
    where id = p_conversation_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'conversation not found';
  end if;

  if not exists (
    select 1
    from public.conversations
    where id = p_conversation_id
      and organization_id in (
        select public.get_authorized_orgs('agent')
      )
  ) then
    raise exception using
      errcode = '42501',
      message = 'conversation is not accessible to the authenticated user';
  end if;

  if not exists (
    select 1
    from public.conversations c
    join public.agents a
      on a.organization_id = c.organization_id
     and a.id = c.assigned_agent_id
    where c.id = p_conversation_id
      and a.user_id = auth.uid()
      and a.ai = false
  ) then
    raise exception using
      errcode = '42501',
      message = 'conversation is not assigned to the authenticated human agent';
  end if;

  raise exception using
    errcode = '23514',
    message = 'conversation cannot be unassigned';
end;
$function$
;


  create policy "admins and supervisors can delete members or agents"
  on "public"."agents"
  as permissive
  for delete
  to authenticated
using (((organization_id IN ( SELECT public.get_authorized_orgs('supervisor'::public.role) AS get_authorized_orgs)) AND (ai = false) AND ((extra ->> 'role'::text) = ANY (ARRAY['member'::text, 'agent'::text]))));



  create policy "admins and supervisors can send member or agent invitations"
  on "public"."agents"
  as permissive
  for insert
  to authenticated
with check (((organization_id IN ( SELECT public.get_authorized_orgs('supervisor'::public.role) AS get_authorized_orgs)) AND (user_id IS NULL) AND (ai = false) AND ((extra ->> 'role'::text) = ANY (ARRAY['member'::text, 'agent'::text])) AND (((extra -> 'invitation'::text) ->> 'status'::text) = 'pending'::text) AND (((extra -> 'invitation'::text) ->> 'email'::text) IS NOT NULL)));



  create policy "admins and supervisors can update members or agents"
  on "public"."agents"
  as permissive
  for update
  to authenticated
using (((organization_id IN ( SELECT public.get_authorized_orgs('supervisor'::public.role) AS get_authorized_orgs)) AND (ai = false) AND ((extra ->> 'role'::text) = ANY (ARRAY['member'::text, 'agent'::text]))))
with check (public.member_update_by_supervisor_rules(id, user_id, organization_id, ai, extra));



  create policy "agents can manage their orgs contacts"
  on "public"."contacts"
  as permissive
  for all
  to authenticated
using ((public.get_request_organization_role(organization_id) = 'agent'::public.role))
with check ((public.get_request_organization_role(organization_id) = 'agent'::public.role));



  create policy "agents can delete non-synced contacts addresses"
  on "public"."contacts_addresses"
  as permissive
  for delete
  to authenticated
using (((public.get_request_organization_role(organization_id) = 'agent'::public.role) AND (((extra -> 'synced'::text) ->> 'action'::text) IS DISTINCT FROM 'add'::text)));



  create policy "agents can insert contacts addresses"
  on "public"."contacts_addresses"
  as permissive
  for insert
  to authenticated
with check (((public.get_request_organization_role(organization_id) = 'agent'::public.role) AND (((extra -> 'synced'::text) ->> 'action'::text) IS DISTINCT FROM 'add'::text)));



  create policy "agents can read their orgs contacts addresses"
  on "public"."contacts_addresses"
  as permissive
  for select
  to authenticated
using ((public.get_request_organization_role(organization_id) = 'agent'::public.role));



  create policy "agents can update contacts addresses"
  on "public"."contacts_addresses"
  as permissive
  for update
  to authenticated
using ((public.get_request_organization_role(organization_id) = 'agent'::public.role))
with check (((public.get_request_organization_role(organization_id) = 'agent'::public.role) AND public.contact_address_update_rules(organization_id, service, address, extra, status)));



  create policy "agents can read visible conversations"
  on "public"."conversations"
  as permissive
  for select
  to authenticated
using (public.agent_can_read_conversation(organization_id, id));



  create policy "agents can update assigned conversations"
  on "public"."conversations"
  as permissive
  for update
  to authenticated
using (public.agent_owns_conversation(organization_id, id))
with check (((public.get_request_organization_role(organization_id) = 'agent'::public.role) AND public.agent_conversation_update_rules(id, organization_id, service, organization_address, contact_address, group_address, assigned_agent_id)));



  create policy "agents can read approved message templates"
  on "public"."message_templates"
  as permissive
  for select
  to authenticated
using (((status = 'approved'::text) AND (public.get_request_organization_role(organization_id) = 'agent'::public.role)));



  create policy "agents can create assigned conversation messages"
  on "public"."messages"
  as permissive
  for insert
  to authenticated
with check (public.agent_message_insert_rules(organization_id, conversation_id, agent_id, direction, service, organization_address, group_address));



  create policy "agents can read visible conversation messages"
  on "public"."messages"
  as permissive
  for select
  to authenticated
using (public.agent_can_read_conversation(organization_id, conversation_id));



  create policy "agents can read their orgs"
  on "public"."organizations"
  as permissive
  for select
  to authenticated
using ((public.get_request_organization_role(id) = 'agent'::public.role));



  create policy "agents can read their orgs addresses"
  on "public"."organizations_addresses"
  as permissive
  for select
  to authenticated
using ((public.get_request_organization_role(organization_id) = 'agent'::public.role));



  create policy "agents can read their orgs quick replies"
  on "public"."quick_replies"
  as permissive
  for select
  to authenticated
using ((public.get_request_organization_role(organization_id) = 'agent'::public.role));



  create policy "agents can download referenced visible media"
  on "storage"."objects"
  as permissive
  for select
  to authenticated
using (((bucket_id = 'media'::text) AND public.agent_can_download_media_object(name)));



  create policy "agents can upload their orgs media"
  on "storage"."objects"
  as permissive
  for insert
  to authenticated
with check (((bucket_id = 'media'::text) AND (public.get_request_organization_role(((storage.foldername(name))[2])::uuid) = 'agent'::public.role)));

