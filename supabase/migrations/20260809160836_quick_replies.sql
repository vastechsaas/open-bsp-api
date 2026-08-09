drop policy "supervisors can manage their orgs quick replies"
on public.quick_replies;

alter table public.quick_replies
rename column name to shortcut;

do $$
declare
  legacy_reply record;
  base_shortcut text;
  candidate_shortcut text;
  suffix integer;
begin
  create temporary table quick_reply_shortcut_map (
    id uuid primary key,
    organization_id uuid not null,
    shortcut text not null,
    unique (organization_id, shortcut)
  ) on commit drop;

  for legacy_reply in
    select id, organization_id, shortcut
    from public.quick_replies
    order by organization_id, created_at, id
  loop
    base_shortcut := lower(btrim(legacy_reply.shortcut));
    base_shortcut := regexp_replace(base_shortcut, '[^a-z0-9_-]+', '_', 'g');
    base_shortcut := btrim(base_shortcut, '_-');

    if base_shortcut = '' then
      base_shortcut := 'reply';
    end if;

    base_shortcut := '/' || left(base_shortcut, 29);
    candidate_shortcut := base_shortcut;
    suffix := 1;

    while exists (
      select 1
      from quick_reply_shortcut_map mapped
      where mapped.organization_id = legacy_reply.organization_id
        and mapped.shortcut = candidate_shortcut
    ) loop
      suffix := suffix + 1;
      candidate_shortcut := left(
        base_shortcut,
        30 - char_length(suffix::text) - 1
      ) || '_' || suffix::text;
    end loop;

    insert into quick_reply_shortcut_map (id, organization_id, shortcut)
    values (legacy_reply.id, legacy_reply.organization_id, candidate_shortcut);
  end loop;

  update public.quick_replies target_reply
  set shortcut = mapped.shortcut
  from quick_reply_shortcut_map mapped
  where mapped.id = target_reply.id;
end;
$$;

create unique index quick_replies_organization_shortcut_key
on public.quick_replies
using btree (organization_id, shortcut);

alter table public.quick_replies
add constraint quick_replies_organization_shortcut_key
unique using index quick_replies_organization_shortcut_key;

alter table public.quick_replies
add constraint quick_replies_shortcut_check
check (
  char_length(shortcut) between 2 and 30
  and shortcut ~ '^/[a-z0-9_-]+$'
) not valid;

alter table public.quick_replies
validate constraint quick_replies_shortcut_check;

create function public.normalize_quick_reply_shortcut(
  p_shortcut text
) returns text
language sql
immutable
set search_path to ''
as $$
  select case
    when left(lower(btrim(p_shortcut)), 1) = '/'
      then lower(btrim(p_shortcut))
    else '/' || lower(btrim(p_shortcut))
  end;
$$;

create function public.validate_quick_reply_input(
  p_shortcut text,
  p_content text
) returns void
language plpgsql
immutable
set search_path to ''
as $$
begin
  if p_shortcut is null
    or char_length(p_shortcut) not between 2 and 30
    or p_shortcut !~ '^/[a-z0-9_-]+$'
  then
    raise exception using
      errcode = '22023',
      message = 'shortcut must start with /, use lowercase letters, numbers, dashes, or underscores, and contain at most 30 characters';
  end if;

  if p_content is null
    or char_length(btrim(p_content)) not between 1 and 1000
  then
    raise exception using
      errcode = '22023',
      message = 'quick reply content must contain between 1 and 1000 characters';
  end if;
end;
$$;

create function public.list_quick_replies_page(
  p_organization_id uuid,
  p_page integer default 1,
  p_page_size integer default 10,
  p_search text default null
) returns table (
  id uuid,
  organization_id uuid,
  shortcut text,
  content text,
  created_at timestamp with time zone,
  updated_at timestamp with time zone,
  total_count bigint
)
language plpgsql
security definer
set search_path to ''
as $$
declare
  normalized_page integer := greatest(coalesce(p_page, 1), 1);
  normalized_page_size integer := least(greatest(coalesce(p_page_size, 10), 1), 50);
  normalized_search text := nullif(btrim(coalesce(p_search, '')), '');
begin
  if public.get_request_organization_role(p_organization_id) is null then
    raise exception using
      errcode = '42501',
      message = 'organization is not accessible to the authenticated user';
  end if;

  return query
  with filtered as (
    select reply.*
    from public.quick_replies reply
    where reply.organization_id = p_organization_id
      and (
        normalized_search is null
        or reply.shortcut ilike '%' || normalized_search || '%'
        or reply.content ilike '%' || normalized_search || '%'
      )
  )
  select
    reply.id,
    reply.organization_id,
    reply.shortcut,
    reply.content,
    reply.created_at,
    reply.updated_at,
    count(*) over() as total_count
  from filtered reply
  order by reply.shortcut asc, reply.id asc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$$;

create function public.create_quick_reply(
  p_organization_id uuid,
  p_shortcut text,
  p_content text
) returns public.quick_replies
language plpgsql
security definer
set search_path to ''
as $$
declare
  request_role public.role;
  normalized_shortcut text := public.normalize_quick_reply_shortcut(p_shortcut);
  normalized_content text := btrim(p_content);
  locked_organization_id uuid;
  created_reply public.quick_replies;
begin
  request_role := public.get_request_organization_role(p_organization_id);
  if request_role is null
    or request_role not in ('owner'::public.role, 'admin'::public.role, 'supervisor'::public.role)
  then
    raise exception using
      errcode = '42501',
      message = 'owner, admin, or supervisor role required to manage quick replies';
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
$$;

create function public.update_quick_reply(
  p_quick_reply_id uuid,
  p_shortcut text,
  p_content text
) returns public.quick_replies
language plpgsql
security definer
set search_path to ''
as $$
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
    or request_role not in ('owner'::public.role, 'admin'::public.role, 'supervisor'::public.role)
  then
    raise exception using
      errcode = '42501',
      message = 'owner, admin, or supervisor role required to manage quick replies';
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
$$;

create function public.delete_quick_reply(
  p_quick_reply_id uuid
) returns uuid
language plpgsql
security definer
set search_path to ''
as $$
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
    or request_role not in ('owner'::public.role, 'admin'::public.role, 'supervisor'::public.role)
  then
    raise exception using
      errcode = '42501',
      message = 'owner, admin, or supervisor role required to manage quick replies';
  end if;

  delete from public.quick_replies reply
  where reply.id = p_quick_reply_id;

  return p_quick_reply_id;
end;
$$;

revoke insert, update, delete
on table public.quick_replies
from anon, authenticated;

revoke execute on function public.normalize_quick_reply_shortcut(text) from public;
revoke execute on function public.validate_quick_reply_input(text, text) from public;
revoke execute on function public.list_quick_replies_page(uuid, integer, integer, text) from public;
revoke execute on function public.create_quick_reply(uuid, text, text) from public;
revoke execute on function public.update_quick_reply(uuid, text, text) from public;
revoke execute on function public.delete_quick_reply(uuid) from public;

grant execute on function public.list_quick_replies_page(uuid, integer, integer, text) to authenticated;
grant execute on function public.create_quick_reply(uuid, text, text) to authenticated;
grant execute on function public.update_quick_reply(uuid, text, text) to authenticated;
grant execute on function public.delete_quick_reply(uuid) to authenticated;

alter table public.quick_replies replica identity full;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables publication_table
    where publication_table.pubname = 'supabase_realtime'
      and publication_table.schemaname = 'public'
      and publication_table.tablename = 'quick_replies'
  ) then
    alter publication supabase_realtime
    add table public.quick_replies;
  end if;
end;
$$;
