
set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.create_quick_reply(p_organization_id uuid, p_shortcut text, p_content text)
 RETURNS public.quick_replies
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  request_role public.role;
  normalized_shortcut text := public.normalize_quick_reply_shortcut(p_shortcut);
  normalized_content text := btrim(p_content);
  locked_organization_id uuid;
  created_reply public.quick_replies;
begin
  request_role := public.get_request_organization_role(p_organization_id);
  if request_role is null
    or request_role not in ('owner'::public.role, 'admin'::public.role, 'supervisor'::public.role, 'agent'::public.role)
  then
    raise exception using
      errcode = '42501',
      message = 'owner, admin, supervisor, or agent role required to manage quick replies';
  end if;

  perform public.validate_quick_reply_input(normalized_shortcut, normalized_content);

  select organization.id into locked_organization_id
  from public.organizations organization
  where organization.id = p_organization_id
  for update;

  if locked_organization_id is null then
    raise exception using
      errcode = '22023',
      message = 'organization not found';
  end if;

  if (
    select count(*)
    from public.quick_replies reply
    where reply.organization_id = p_organization_id
  ) >= 50 then
    raise exception using
      errcode = '22023',
      message = 'maximum limit of 50 quick replies reached for this organization';
  end if;

  insert into public.quick_replies (organization_id, shortcut, content)
  values (p_organization_id, normalized_shortcut, normalized_content)
  returning * into created_reply;

  return created_reply;
exception
  when unique_violation then
    raise exception using
      errcode = '23505',
      message = 'quick reply shortcut already exists in this organization';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.delete_quick_reply(p_quick_reply_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  existing_reply public.quick_replies;
  request_role public.role;
begin
  select reply.* into existing_reply
  from public.quick_replies reply
  where reply.id = p_quick_reply_id
  for update;

  if existing_reply.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'quick reply not found';
  end if;

  request_role := public.get_request_organization_role(existing_reply.organization_id);
  if request_role is null
    or request_role not in ('owner'::public.role, 'admin'::public.role, 'supervisor'::public.role, 'agent'::public.role)
  then
    raise exception using
      errcode = '42501',
      message = 'owner, admin, supervisor, or agent role required to manage quick replies';
  end if;

  delete from public.quick_replies reply
  where reply.id = p_quick_reply_id;

  return p_quick_reply_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_quick_reply(p_quick_reply_id uuid, p_shortcut text, p_content text)
 RETURNS public.quick_replies
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  existing_reply public.quick_replies;
  request_role public.role;
  normalized_shortcut text := public.normalize_quick_reply_shortcut(p_shortcut);
  normalized_content text := btrim(p_content);
  updated_reply public.quick_replies;
begin
  select reply.* into existing_reply
  from public.quick_replies reply
  where reply.id = p_quick_reply_id
  for update;

  if existing_reply.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'quick reply not found';
  end if;

  request_role := public.get_request_organization_role(existing_reply.organization_id);
  if request_role is null
    or request_role not in ('owner'::public.role, 'admin'::public.role, 'supervisor'::public.role, 'agent'::public.role)
  then
    raise exception using
      errcode = '42501',
      message = 'owner, admin, supervisor, or agent role required to manage quick replies';
  end if;

  perform public.validate_quick_reply_input(normalized_shortcut, normalized_content);

  update public.quick_replies reply
  set shortcut = normalized_shortcut,
      content = normalized_content
  where reply.id = p_quick_reply_id
  returning * into updated_reply;

  return updated_reply;
exception
  when unique_violation then
    raise exception using
      errcode = '23505',
      message = 'quick reply shortcut already exists in this organization';
end;
$function$
;


