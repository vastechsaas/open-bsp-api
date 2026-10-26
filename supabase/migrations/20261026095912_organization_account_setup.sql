drop function if exists "public"."list_platform_organization_provisioning_page"(p_page integer, p_page_size integer, p_search text, p_status text);


  create table "public"."organization_provisioning_people" (
    "provisioning_id" uuid not null,
    "member_id" uuid not null,
    "client_key" text not null,
    "ordinal" integer not null,
    "mode" text not null,
    "request_id" uuid not null default gen_random_uuid(),
    "name" text not null,
    "email" text not null,
    "role" public.role not null,
    "expected_updated_at" timestamp with time zone not null,
    "failure_code" text
      );


alter table "public"."organization_provisioning_people" enable row level security;

alter table "public"."organization_provisioning" add column "setup_version" integer not null default 1;

CREATE UNIQUE INDEX organization_provisioning_people_pkey ON public.organization_provisioning_people USING btree (provisioning_id, member_id);

CREATE UNIQUE INDEX organization_provisioning_people_provisioning_id_client_key_key ON public.organization_provisioning_people USING btree (provisioning_id, client_key);

CREATE UNIQUE INDEX organization_provisioning_people_provisioning_id_ordinal_key ON public.organization_provisioning_people USING btree (provisioning_id, ordinal);

CREATE UNIQUE INDEX organization_provisioning_people_request_id_key ON public.organization_provisioning_people USING btree (request_id);

alter table "public"."organization_provisioning_people" add constraint "organization_provisioning_people_pkey" PRIMARY KEY using index "organization_provisioning_people_pkey";

alter table "public"."organization_provisioning" add constraint "organization_provisioning_setup_version_check" CHECK ((setup_version = ANY (ARRAY[1, 2]))) not valid;

alter table "public"."organization_provisioning" validate constraint "organization_provisioning_setup_version_check";

alter table "public"."organization_provisioning_people" add constraint "organization_provisioning_people_client_key_check" CHECK (((char_length(client_key) >= 1) AND (char_length(client_key) <= 64))) not valid;

alter table "public"."organization_provisioning_people" validate constraint "organization_provisioning_people_client_key_check";

alter table "public"."organization_provisioning_people" add constraint "organization_provisioning_people_mode_check" CHECK ((mode = ANY (ARRAY['invitation'::text, 'direct'::text, 'pending'::text]))) not valid;

alter table "public"."organization_provisioning_people" validate constraint "organization_provisioning_people_mode_check";

alter table "public"."organization_provisioning_people" add constraint "organization_provisioning_people_ordinal_check" CHECK ((ordinal >= 0)) not valid;

alter table "public"."organization_provisioning_people" validate constraint "organization_provisioning_people_ordinal_check";

alter table "public"."organization_provisioning_people" add constraint "organization_provisioning_people_provisioning_id_client_key_key" UNIQUE using index "organization_provisioning_people_provisioning_id_client_key_key";

alter table "public"."organization_provisioning_people" add constraint "organization_provisioning_people_provisioning_id_fkey" FOREIGN KEY (provisioning_id) REFERENCES public.organization_provisioning(id) ON DELETE CASCADE not valid;

alter table "public"."organization_provisioning_people" validate constraint "organization_provisioning_people_provisioning_id_fkey";

alter table "public"."organization_provisioning_people" add constraint "organization_provisioning_people_provisioning_id_ordinal_key" UNIQUE using index "organization_provisioning_people_provisioning_id_ordinal_key";

alter table "public"."organization_provisioning_people" add constraint "organization_provisioning_people_request_id_key" UNIQUE using index "organization_provisioning_people_request_id_key";

alter table "public"."organization_provisioning_people" add constraint "organization_provisioning_people_role_check" CHECK ((role = ANY (ARRAY['owner'::public.role, 'supervisor'::public.role, 'agent'::public.role]))) not valid;

alter table "public"."organization_provisioning_people" validate constraint "organization_provisioning_people_role_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.begin_platform_organization_setup(p_request_id uuid, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid; parent public.organization_provisioning; canonical jsonb; member jsonb; members jsonb:='[]'; modes jsonb:='[]'; existing_modes jsonb;
  owner jsonb; i integer:=0; agent public.agents; person jsonb;
begin
  actor:=public.require_platform_admin();
  if p_request_id is null or jsonb_typeof(p_payload) is distinct from 'object' or
    exists(select 1 from jsonb_object_keys(p_payload) k where k not in ('organization_name','owner','members','max_agent_seats','storage_quota_gb','auto_assign')) then
    raise exception 'ONBOARDING_INVALID_REQUEST' using errcode='22023'; end if;
  owner:=p_payload->'owner';
  if jsonb_typeof(owner) is distinct from 'object' or
    exists(select 1 from jsonb_object_keys(owner) k where k not in ('name','email','mode')) or
    coalesce(owner->>'mode','invitation') not in ('pending','invitation','direct') or
    jsonb_typeof(p_payload->'members') is distinct from 'array' or jsonb_array_length(p_payload->'members')>50 then
    raise exception 'ONBOARDING_INVALID_REQUEST' using errcode='22023'; end if;
  modes:=jsonb_build_array(jsonb_build_object('client_key','owner','mode',coalesce(owner->>'mode','invitation')));
  for member in select value from jsonb_array_elements(p_payload->'members') loop
    if jsonb_typeof(member) is distinct from 'object' or exists(select 1 from jsonb_object_keys(member) k where k not in ('client_key','name','email','role','mode')) or
      coalesce(member->>'role','') not in ('owner','supervisor','agent') or coalesce(member->>'mode','invitation') not in ('pending','invitation','direct') or
      member->>'client_key' is null or char_length(member->>'client_key') not between 1 and 64 or member->>'client_key'='owner' then
      raise exception 'ONBOARDING_INVALID_REQUEST' using errcode='22023'; end if;
    members:=members||jsonb_build_array(jsonb_build_object('name',btrim(member->>'name'),'email',lower(btrim(member->>'email')),'role',member->>'role'));
    modes:=modes||jsonb_build_array(jsonb_build_object('client_key',member->>'client_key','mode',coalesce(member->>'mode','invitation')));
  end loop;
  if (select count(distinct m->>'client_key') from jsonb_array_elements(modes) m)<>jsonb_array_length(modes) then
    raise exception 'ONBOARDING_INVALID_REQUEST' using errcode='22023'; end if;
  canonical:=jsonb_build_object('organization_name',btrim(p_payload->>'organization_name'),
    'owner',jsonb_build_object('name',btrim(owner->>'name'),'email',lower(btrim(owner->>'email'))), 'members',members,
    'max_agent_seats',p_payload->'max_agent_seats','storage_quota_gb',coalesce((p_payload->>'storage_quota_gb')::integer,25),
    'auto_assign',coalesce((p_payload->>'auto_assign')::boolean,false));
  perform pg_advisory_xact_lock(hashtextextended(actor::text||':'||p_request_id::text,0));
  select * into parent from public.organization_provisioning where platform_admin_user_id=actor and request_id=p_request_id for update;
  if found then
    select jsonb_agg(jsonb_build_object('client_key',p.client_key,'mode',p.mode) order by p.ordinal) into existing_modes
      from public.organization_provisioning_people p where provisioning_id=parent.id;
    if parent.setup_version<>2 or parent.request_payload is distinct from canonical or existing_modes is distinct from modes then
      raise exception 'ONBOARDING_REQUEST_REUSED' using errcode='22023'; end if;
    return public.get_platform_organization_setup(parent.id);
  end if;
  parent:=public.provision_platform_organization(p_request_id,canonical->>'organization_name',canonical->'owner'->>'name',canonical->'owner'->>'email',members,
    (canonical->>'max_agent_seats')::integer,(canonical->>'storage_quota_gb')::integer,(canonical->>'auto_assign')::boolean);
  for person in select value from jsonb_array_elements(modes) loop
    i:=i+1;
    select * into agent from public.agents where id=parent.invitation_agent_ids[i] and organization_id=parent.organization_id;
    insert into public.organization_provisioning_people(provisioning_id,member_id,client_key,ordinal,mode,name,email,role,expected_updated_at)
      values(parent.id,agent.id,person->>'client_key',i-1,person->>'mode',agent.name,lower(agent.extra->'invitation'->>'email'),
        (agent.extra->>'role')::public.role,agent.updated_at);
  end loop;
  update public.organization_provisioning set setup_version=2 where id=parent.id;
  return public.get_platform_organization_setup(parent.id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_platform_organization_setup(p_provisioning_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare parent public.organization_provisioning; people jsonb; ready boolean; failed boolean; next_status text;
begin
  perform public.require_platform_admin();
  select * into parent from public.organization_provisioning where id=p_provisioning_id for update;
  if not found then raise exception 'ONBOARDING_NOT_FOUND' using errcode='P0002'; end if;
  if parent.setup_version=1 then return jsonb_build_object('version',1,'provisioning',to_jsonb(parent)); end if;
  select jsonb_agg(jsonb_build_object('member_id',p.member_id,'client_key',p.client_key,'mode',p.mode,'name',p.name,'email',p.email,'role',p.role,
    'request_id',p.request_id,'expected_updated_at',p.expected_updated_at,'operation_id',o.id,
    'status',case
      when a.id is null or a.extra->>'role' is distinct from p.role::text or
        (a.user_id is null and (a.updated_at<>p.expected_updated_at or lower(a.extra->'invitation'->>'email') is distinct from p.email)) then 'failed'
      when p.mode='pending' then 'pending_membership'
      when o.status='completed' then 'completed'
      when o.status='revoked' then 'failed'
      when o.lease_until>clock_timestamp() then 'processing'
      when coalesce(o.failure_code,p.failure_code) is not null then 'failed'
      when o.delivery_accepted_at is not null then 'invitation_sent'
      else 'queued' end,
    'failure_code',case when a.id is null or a.extra->>'role' is distinct from p.role::text or
      (a.user_id is null and (a.updated_at<>p.expected_updated_at or lower(a.extra->'invitation'->>'email') is distinct from p.email)) then 'TEAM_MEMBER_STALE'
      when o.status='revoked' then 'ONBOARDING_REVOKED'
      when o.status='completed' or o.delivery_accepted_at is not null then null else coalesce(o.failure_code,p.failure_code) end,
    'invitation_sent_at',o.delivery_accepted_at) order by p.ordinal)
  into people from public.organization_provisioning_people p
  left join public.agents a on a.id=p.member_id and a.organization_id=parent.organization_id
  left join lateral (select op.* from public.platform_user_onboarding op where op.member_id=p.member_id
    and op.organization_id=parent.organization_id and op.request_id=p.request_id order by op.created_at desc limit 1) o on true
  where p.provisioning_id=parent.id;
  ready:=not exists(select 1 from jsonb_array_elements(people) person where person->>'status' not in ('pending_membership','invitation_sent','completed'));
  failed:=exists(select 1 from jsonb_array_elements(people) person where person->>'status'='failed');
  next_status:=case when ready then 'completed' when failed then 'failed' else 'pending_invitation' end;
  if parent.status<>next_status then
    update public.organization_provisioning set status=next_status,
      last_error=case when failed then 'ACCOUNT_SETUP_REQUIRES_ATTENTION' else null end,
      completed_at=case when ready then clock_timestamp() else null end where id=parent.id returning * into parent;
  end if;
  return jsonb_build_object('version',2,'provisioning_id',parent.id,'organization_id',parent.organization_id,
    'organization_name',parent.organization_name,'status',case when ready then 'completed' when failed then 'partial' else 'processing' end,
    'people',people,'has_remaining_work',not ready);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_platform_provisioning_person_result(p_provisioning_id uuid, p_member_id uuid, p_failure_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform public.require_platform_admin();
  if p_failure_code is not null and p_failure_code not in ('ONBOARDING_EMAIL_IN_USE','ONBOARDING_EMAIL_RESERVED','ONBOARDING_CAPACITY_REACHED',
    'ONBOARDING_BUSY','ONBOARDING_REVOKED','TEAM_MEMBER_STALE','AUTH_UNAVAILABLE','AUTH_REJECTED','PASSWORD_REENTRY_REQUIRED','WEAK_PASSWORD',
    'SMTP_FAILED','DELIVERY_UNKNOWN','FINALIZATION_FAILED','ONBOARDING_NOT_CONFIGURED','ONBOARDING_INVALID_REQUEST') then
    raise exception 'ONBOARDING_INVALID_REQUEST' using errcode='22023'; end if;
  update public.organization_provisioning_people set failure_code=p_failure_code
    where provisioning_id=p_provisioning_id and member_id=p_member_id;
  if not found then raise exception 'ONBOARDING_NOT_FOUND' using errcode='P0002'; end if;
  insert into public.organization_provisioning_events(provisioning_id,platform_admin_user_id,organization_id,event_type,details)
    select p.id,auth.uid(),p.organization_id,case when p_failure_code is null then 'retried' else 'failed' end,
      jsonb_build_object('member_id',p_member_id,'code',p_failure_code)
      from public.organization_provisioning p where p.id=p_provisioning_id;
  return public.get_platform_organization_setup(p_provisioning_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_platform_organization_provisioning_page(p_page integer DEFAULT 1, p_page_size integer DEFAULT 25, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, request_id uuid, organization_id uuid, organization_name text, owner_name text, owner_email text, status text, attempt_count integer, last_error text, completed_at timestamp with time zone, created_at timestamp with time zone, updated_at timestamp with time zone, setup_version integer, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  normalized_page integer := greatest(coalesce(p_page, 1), 1);
  normalized_page_size integer := least(greatest(coalesce(p_page_size, 25), 1), 50);
  normalized_search text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform public.require_platform_admin();
  if p_status is not null and p_status not in ('pending_invitation', 'completed', 'failed') then
    raise exception using errcode = '22023', message = 'invalid provisioning status filter';
  end if;

  return query
  with filtered as (
    select provisioning.*
    from public.organization_provisioning provisioning
    where (p_status is null or provisioning.status = p_status)
      and (
        normalized_search is null
        or provisioning.organization_name ilike '%' || normalized_search || '%'
        or provisioning.request_payload->'owner'->>'name' ilike '%' || normalized_search || '%'
        or provisioning.request_payload->'owner'->>'email' ilike '%' || normalized_search || '%'
      )
  )
  select
    filtered.id,
    filtered.request_id,
    filtered.organization_id,
    filtered.organization_name,
    filtered.request_payload->'owner'->>'name',
    filtered.request_payload->'owner'->>'email',
    filtered.status,
    filtered.attempt_count,
    filtered.last_error,
    filtered.completed_at,
    filtered.created_at,
    filtered.updated_at,
    filtered.setup_version,
    count(*) over ()
  from filtered
  order by filtered.updated_at desc, filtered.id desc
  limit normalized_page_size
  offset (normalized_page - 1) * normalized_page_size;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.provision_platform_organization(p_request_id uuid, p_organization_name text, p_owner_name text, p_owner_email text, p_members jsonb DEFAULT '[]'::jsonb, p_max_agent_seats integer DEFAULT NULL::integer, p_storage_quota_gb integer DEFAULT 25, p_auto_assign boolean DEFAULT false)
 RETURNS public.organization_provisioning
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  authenticated_user_id uuid;
  normalized_organization_name text := btrim(coalesce(p_organization_name, ''));
  normalized_owner_name text := btrim(coalesce(p_owner_name, ''));
  normalized_owner_email text := lower(btrim(coalesce(p_owner_email, '')));
  normalized_members jsonb := '[]'::jsonb;
  normalized_member jsonb;
  member jsonb;
  member_name text;
  member_email text;
  member_role text;
  seen_emails text[];
  capacity_member_count integer := 0;
  created_organization public.organizations;
  created_agent public.agents;
  invitation_agent_ids uuid[] := array[]::uuid[];
  canonical_payload jsonb;
  existing_provisioning public.organization_provisioning;
  created_provisioning public.organization_provisioning;
begin
  authenticated_user_id := public.require_platform_admin();

  if p_request_id is null then
    raise exception using errcode = '22023', message = 'request id is required';
  end if;

  if char_length(normalized_organization_name) not between 1 and 250 then
    raise exception using
      errcode = '22023',
      message = 'organization name must contain between 1 and 250 characters';
  end if;

  if char_length(normalized_owner_name) not between 1 and 120 then
    raise exception using
      errcode = '22023',
      message = 'owner name must contain between 1 and 120 characters';
  end if;

  if char_length(normalized_owner_email) > 320
    or position('@' in normalized_owner_email) <= 1
  then
    raise exception using errcode = '22023', message = 'valid owner email is required';
  end if;

  if jsonb_typeof(coalesce(p_members, '[]'::jsonb)) <> 'array'
    or jsonb_array_length(coalesce(p_members, '[]'::jsonb)) > 50
  then
    raise exception using
      errcode = '22023',
      message = 'members must be an array containing at most 50 entries';
  end if;

  if p_max_agent_seats is not null and p_max_agent_seats <= 0 then
    raise exception using
      errcode = '22023',
      message = 'agent capacity must be greater than zero';
  end if;

  if p_storage_quota_gb not in (25, 50, 75, 100) then
    raise exception using
      errcode = '22023',
      message = 'storage quota must be 25, 50, 75 or 100 GB';
  end if;

  seen_emails := array[normalized_owner_email];
  for member in select value from jsonb_array_elements(coalesce(p_members, '[]'::jsonb)) loop
    if jsonb_typeof(member) <> 'object' then
      raise exception using errcode = '22023', message = 'each member must be an object';
    end if;

    member_name := btrim(coalesce(member->>'name', ''));
    member_email := lower(btrim(coalesce(member->>'email', '')));
    member_role := lower(btrim(coalesce(member->>'role', '')));

    if char_length(member_name) not between 1 and 120 then
      raise exception using
        errcode = '22023',
        message = 'member name must contain between 1 and 120 characters';
    end if;
    if char_length(member_email) > 320 or position('@' in member_email) <= 1 then
      raise exception using errcode = '22023', message = 'valid member email is required';
    end if;
    if member_role not in ('owner', 'admin', 'supervisor', 'member', 'agent') then
      raise exception using errcode = '22023', message = 'unsupported organization role';
    end if;
    if member_email = any(seen_emails) then
      raise exception using
        errcode = '23505',
        message = 'each onboarding email must be unique';
    end if;

    seen_emails := array_append(seen_emails, member_email);
    if member_role in ('supervisor', 'agent') then
      capacity_member_count := capacity_member_count + 1;
    end if;
    normalized_member := jsonb_build_object(
      'name', member_name,
      'email', member_email,
      'role', member_role
    );
    normalized_members := normalized_members || jsonb_build_array(normalized_member);
  end loop;

  if p_max_agent_seats is not null and capacity_member_count > p_max_agent_seats then
    raise exception using
      errcode = '23514',
      message = 'initial Agents and Supervisors exceed the configured capacity';
  end if;

  canonical_payload := jsonb_build_object(
    'organization_name', normalized_organization_name,
    'owner', jsonb_build_object(
      'name', normalized_owner_name,
      'email', normalized_owner_email
    ),
    'members', normalized_members,
    'max_agent_seats', p_max_agent_seats,
    'storage_quota_gb', p_storage_quota_gb,
    'auto_assign', coalesce(p_auto_assign, false)
  );

  perform pg_advisory_xact_lock(
    hashtextextended(authenticated_user_id::text || ':' || p_request_id::text, 0)
  );

  select provisioning.* into existing_provisioning
  from public.organization_provisioning provisioning
  where provisioning.platform_admin_user_id = authenticated_user_id
    and provisioning.request_id = p_request_id
  for update;

  if found then
    if existing_provisioning.setup_version = 2 then
      raise exception 'ONBOARDING_VERSION_REQUIRED' using errcode = '22023';
    end if;
    if existing_provisioning.request_payload <> canonical_payload then
      raise exception using
        errcode = '22023',
        message = 'request id was already used with a different onboarding payload';
    end if;

    if existing_provisioning.status = 'failed' then
      update public.organization_provisioning provisioning
      set status = 'pending_invitation', last_error = null
      where provisioning.id = existing_provisioning.id
      returning * into existing_provisioning;

      insert into public.organization_provisioning_events (
        provisioning_id, platform_admin_user_id, organization_id, event_type
      ) values (
        existing_provisioning.id,
        authenticated_user_id,
        existing_provisioning.organization_id,
        'retried'
      );
    end if;

    return existing_provisioning;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('organization-name:' || lower(normalized_organization_name), 0)
  );
  if exists (
    select 1 from public.organizations organization
    where lower(btrim(organization.name)) = lower(normalized_organization_name)
  ) then
    raise exception using
      errcode = '23505',
      message = 'an organization with this name already exists';
  end if;

  perform set_config('app.organization_provisioning', 'on', true);
  insert into public.organizations (name, extra)
  values (
    normalized_organization_name,
    jsonb_build_object('provisioned_by', 'platform_admin')
  ) returning * into created_organization;
  perform set_config('app.organization_provisioning', 'off', true);

  insert into public.organization_agent_capacity (
    organization_id, max_agent_seats, updated_by, updated_by_scope
  ) values (
    created_organization.id, p_max_agent_seats, authenticated_user_id, 'platform'
  );

  update public.organization_media_storage storage
  set quota_bytes = p_storage_quota_gb::bigint * 1000000000,
      updated_by = authenticated_user_id,
      updated_by_scope = 'platform'
  where storage.organization_id = created_organization.id;

  update public.organization_automation_settings settings
  set auto_assign_conversations = coalesce(p_auto_assign, false),
      updated_by_user_id = authenticated_user_id,
      updated_by_scope = 'platform'
  where settings.organization_id = created_organization.id;

  insert into public.agents (organization_id, name, ai, extra)
  values (
    created_organization.id,
    normalized_owner_name,
    false,
    jsonb_build_object(
      'role', 'owner',
      'invitation', jsonb_build_object(
        'organization_name', normalized_organization_name,
        'email', normalized_owner_email,
        'status', 'pending'
      )
    )
  ) returning * into created_agent;
  invitation_agent_ids := array_append(invitation_agent_ids, created_agent.id);

  for member in select value from jsonb_array_elements(normalized_members) loop
    insert into public.agents (organization_id, name, ai, extra)
    values (
      created_organization.id,
      member->>'name',
      false,
      jsonb_build_object(
        'role', member->>'role',
        'invitation', jsonb_build_object(
          'organization_name', normalized_organization_name,
          'email', member->>'email',
          'status', 'pending'
        )
      )
    ) returning * into created_agent;
    invitation_agent_ids := array_append(invitation_agent_ids, created_agent.id);
  end loop;

  insert into public.organization_provisioning (
    request_id,
    platform_admin_user_id,
    organization_id,
    organization_name,
    request_payload,
    invitation_agent_ids
  ) values (
    p_request_id,
    authenticated_user_id,
    created_organization.id,
    normalized_organization_name,
    canonical_payload,
    invitation_agent_ids
  ) returning * into created_provisioning;

  insert into public.organization_provisioning_events (
    provisioning_id,
    platform_admin_user_id,
    organization_id,
    event_type,
    details
  ) values (
    created_provisioning.id,
    authenticated_user_id,
    created_organization.id,
    'started',
    jsonb_build_object('invitation_count', cardinality(invitation_agent_ids))
  );

  return created_provisioning;
end;
$function$
;

grant delete on table "public"."organization_provisioning_people" to "service_role";

grant insert on table "public"."organization_provisioning_people" to "service_role";

grant references on table "public"."organization_provisioning_people" to "service_role";

grant select on table "public"."organization_provisioning_people" to "service_role";

grant trigger on table "public"."organization_provisioning_people" to "service_role";

grant truncate on table "public"."organization_provisioning_people" to "service_role";

grant update on table "public"."organization_provisioning_people" to "service_role";

-- Reassert schema-source ACLs omitted by migra for new/recreated objects.
revoke all on public.organization_provisioning_people from anon,authenticated;
revoke all on function public.get_platform_organization_setup(uuid), public.begin_platform_organization_setup(uuid,jsonb), public.record_platform_provisioning_person_result(uuid,uuid,text) from public,anon;
grant execute on function public.get_platform_organization_setup(uuid), public.begin_platform_organization_setup(uuid,jsonb), public.record_platform_provisioning_person_result(uuid,uuid,text) to authenticated;
revoke all on function public.list_platform_organization_provisioning_page(integer,integer,text,text) from public,anon;
grant execute on function public.list_platform_organization_provisioning_page(integer,integer,text,text) to authenticated;
