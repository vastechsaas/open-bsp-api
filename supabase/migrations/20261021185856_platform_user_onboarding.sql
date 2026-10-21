
  create table "public"."platform_user_onboarding" (
    "id" uuid not null default gen_random_uuid(),
    "organization_id" uuid not null,
    "member_id" uuid not null,
    "administrator_id" uuid not null,
    "request_id" uuid not null,
    "intended_user_id" uuid not null default gen_random_uuid(),
    "email" text not null,
    "name" text not null,
    "role" public.role not null,
    "mode" text not null,
    "status" text not null default 'reserved'::text,
    "failure_code" text,
    "generation" integer not null default 0,
    "context_hash" text,
    "context_expires_at" timestamp with time zone,
    "delivery_request_id" uuid,
    "delivery_accepted_at" timestamp with time zone,
    "lease_id" uuid,
    "lease_until" timestamp with time zone,
    "created_at" timestamp with time zone not null default clock_timestamp(),
    "updated_at" timestamp with time zone not null default clock_timestamp()
      );


alter table "public"."platform_user_onboarding" enable row level security;


  create table "public"."platform_user_onboarding_events" (
    "id" bigint generated always as identity not null,
    "operation_id" uuid not null,
    "actor_user_id" uuid not null,
    "event" text not null,
    "code" text,
    "member_state" jsonb not null,
    "created_at" timestamp with time zone not null default clock_timestamp()
      );


alter table "public"."platform_user_onboarding_events" enable row level security;

CREATE UNIQUE INDEX platform_user_onboarding_administrator_id_request_id_key ON public.platform_user_onboarding USING btree (administrator_id, request_id);

CREATE UNIQUE INDEX platform_user_onboarding_email_reservation ON public.platform_user_onboarding USING btree (email) WHERE (status <> ALL (ARRAY['completed'::text, 'revoked'::text]));

CREATE UNIQUE INDEX platform_user_onboarding_events_pkey ON public.platform_user_onboarding_events USING btree (id);

CREATE UNIQUE INDEX platform_user_onboarding_intended_user_id_key ON public.platform_user_onboarding USING btree (intended_user_id);

CREATE INDEX platform_user_onboarding_member ON public.platform_user_onboarding USING btree (organization_id, member_id, created_at DESC);

CREATE UNIQUE INDEX platform_user_onboarding_pkey ON public.platform_user_onboarding USING btree (id);

alter table "public"."platform_user_onboarding" add constraint "platform_user_onboarding_pkey" PRIMARY KEY using index "platform_user_onboarding_pkey";

alter table "public"."platform_user_onboarding_events" add constraint "platform_user_onboarding_events_pkey" PRIMARY KEY using index "platform_user_onboarding_events_pkey";

alter table "public"."platform_user_onboarding" add constraint "platform_user_onboarding_administrator_id_fkey" FOREIGN KEY (administrator_id) REFERENCES auth.users(id) not valid;

alter table "public"."platform_user_onboarding" validate constraint "platform_user_onboarding_administrator_id_fkey";

alter table "public"."platform_user_onboarding" add constraint "platform_user_onboarding_administrator_id_request_id_key" UNIQUE using index "platform_user_onboarding_administrator_id_request_id_key";

alter table "public"."platform_user_onboarding" add constraint "platform_user_onboarding_intended_user_id_key" UNIQUE using index "platform_user_onboarding_intended_user_id_key";

alter table "public"."platform_user_onboarding" add constraint "platform_user_onboarding_mode_check" CHECK ((mode = ANY (ARRAY['direct'::text, 'invitation'::text]))) not valid;

alter table "public"."platform_user_onboarding" validate constraint "platform_user_onboarding_mode_check";

alter table "public"."platform_user_onboarding" add constraint "platform_user_onboarding_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."platform_user_onboarding" validate constraint "platform_user_onboarding_organization_id_fkey";

alter table "public"."platform_user_onboarding" add constraint "platform_user_onboarding_role_check" CHECK ((role = ANY (ARRAY['owner'::public.role, 'supervisor'::public.role, 'agent'::public.role]))) not valid;

alter table "public"."platform_user_onboarding" validate constraint "platform_user_onboarding_role_check";

alter table "public"."platform_user_onboarding" add constraint "platform_user_onboarding_status_check" CHECK ((status = ANY (ARRAY['reserved'::text, 'account_created'::text, 'invitation_sent'::text, 'completing'::text, 'completed'::text, 'revoked'::text]))) not valid;

alter table "public"."platform_user_onboarding" validate constraint "platform_user_onboarding_status_check";

alter table "public"."platform_user_onboarding_events" add constraint "platform_user_onboarding_events_operation_id_fkey" FOREIGN KEY (operation_id) REFERENCES public.platform_user_onboarding(id) ON DELETE CASCADE not valid;

alter table "public"."platform_user_onboarding_events" validate constraint "platform_user_onboarding_events_operation_id_fkey";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.guard_onboarding_membership()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare op public.platform_user_onboarding;
begin
  perform public.lock_organization_team(old.organization_id);
  select * into op from public.platform_user_onboarding where member_id=old.id and status not in ('completed','revoked') for update;
  if not found then return case when tg_op='DELETE' then old else new end; end if;
  if tg_op='UPDATE' and new.user_id is distinct from old.user_id and new.user_id is distinct from op.intended_user_id then
    raise exception 'ONBOARDING_ACCOUNT_MISMATCH' using errcode='23514';
  end if;
  if tg_op='DELETE' or new.extra->>'role' is distinct from old.extra->>'role'
    or new.extra->'invitation'->>'status'='rejected' then
    if op.lease_until>clock_timestamp() then raise exception 'ONBOARDING_BUSY' using errcode='55P03'; end if;
    update public.platform_user_onboarding set status='revoked',context_hash=null,updated_at=clock_timestamp() where id=op.id;
    insert into public.platform_user_onboarding_events(operation_id,actor_user_id,event,member_state)
      values(op.id,coalesce(auth.uid(),op.administrator_id),'revoked',jsonb_build_object('member_id',old.id,'role',old.extra->>'role'));
  elsif tg_op='UPDATE' and new.extra->'invitation'->>'status'='accepted' then
    raise exception 'ONBOARDING_SETUP_REQUIRED' using errcode='23514';
  end if;
  return case when tg_op='DELETE' then old else new end;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_platform_member_onboarding(p_organization_id uuid, p_member_ids uuid[])
 RETURNS TABLE(operation_id uuid, member_id uuid, mode text, status text, failure_code text, invitation_sent_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform public.require_platform_admin();
  if cardinality(p_member_ids)>50 then raise exception 'ONBOARDING_INVALID_REQUEST'; end if;
  return query select distinct on(o.member_id) o.id,o.member_id,o.mode,o.status,o.failure_code,o.delivery_accepted_at
    from public.platform_user_onboarding o where o.organization_id=p_organization_id and o.member_id=any(p_member_ids)
    order by o.member_id,o.created_at desc,o.id desc;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.platform_onboarding_command(p_actor uuid, p_command text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  op public.platform_user_onboarding; member public.agents; account auth.users;
  org uuid; normalized_email text; desired_role public.role; op_id uuid;
  req_id uuid; lease uuid; current_hash text; event_name text:=p_command;
begin
  if p_command not in ('preview','complete_claim','complete_status','complete_finish','complete_failed') and not exists(
    select 1 from public.platform_admins where user_id=p_actor and active
  ) then raise exception 'ONBOARDING_FORBIDDEN' using errcode='42501'; end if;

  if p_command='begin' then
    org:=(p_payload->>'organization_id')::uuid;
    req_id:=(p_payload->>'request_id')::uuid;
    normalized_email:=lower(btrim(p_payload->>'email'));
    desired_role:=(p_payload->>'role')::public.role;
    if org is null or req_id is null or desired_role not in ('owner','supervisor','agent')
      or p_payload->>'mode' not in ('direct','invitation')
      or char_length(btrim(p_payload->>'name')) not between 1 and 120
      or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
      or char_length(normalized_email)>320 then
      raise exception 'ONBOARDING_INVALID_REQUEST' using errcode='22023';
    end if;
    perform pg_advisory_xact_lock(hashtextextended('account-email:'||normalized_email,0));
    perform pg_advisory_xact_lock(hashtextextended('account-request:'||p_actor::text||req_id::text,0));
    select * into op from public.platform_user_onboarding where administrator_id=p_actor and request_id=req_id;
    if found then
      if op.organization_id<>org or op.email<>normalized_email or op.role<>desired_role or op.name<>btrim(p_payload->>'name')
        or op.mode<>p_payload->>'mode' or (p_payload->>'member_id' is not null and op.member_id<>(p_payload->>'member_id')::uuid) then
        raise exception 'ONBOARDING_REQUEST_REUSED' using errcode='22023';
      end if;
      return to_jsonb(op);
    end if;
    if exists(select 1 from auth.users where lower(email)=normalized_email) then
      raise exception 'ONBOARDING_EMAIL_IN_USE' using errcode='23505';
    end if;
    if exists(select 1 from public.platform_user_onboarding where email=normalized_email and status not in ('completed','revoked')) then
      raise exception 'ONBOARDING_EMAIL_RESERVED' using errcode='23505';
    end if;
    perform public.lock_organization_team(org);
    if p_payload->>'member_id' is null then
      -- Reuse Phase 1 validation, capacity reservations, authorization and audit.
      perform set_config('request.jwt.claim.sub',p_actor::text,true);
      member:=public.create_platform_organization_member_invitation(org,btrim(p_payload->>'name'),normalized_email,desired_role,req_id);
    else
      select * into member from public.agents where id=(p_payload->>'member_id')::uuid and organization_id=org for update;
      if not found or member.ai or member.user_id is not null or member.extra->>'role'<>desired_role
        or member.extra->'invitation'->>'status'<>'pending'
        or lower(member.extra->'invitation'->>'email')<>normalized_email
        or member.updated_at<>(p_payload->>'expected_updated_at')::timestamptz
        or p_payload->>'expected_updated_at' is null then
        raise exception 'TEAM_MEMBER_STALE' using errcode='40001';
      end if;
    end if;
    insert into public.platform_user_onboarding(organization_id,member_id,administrator_id,request_id,email,name,role,mode)
      values(org,member.id,p_actor,req_id,normalized_email,btrim(p_payload->>'name'),desired_role,p_payload->>'mode') returning * into op;
  else
    op_id:=(p_payload->>'operation_id')::uuid;
    select organization_id into org from public.platform_user_onboarding where id=op_id;
    if org is null then raise exception 'ONBOARDING_NOT_FOUND' using errcode='P0002'; end if;
    -- Same lock order as membership edits and cancellation.
    perform public.lock_organization_team(org);
    select * into op from public.platform_user_onboarding where id=op_id for update;
    if p_command not in ('preview','complete_claim','complete_status','complete_finish','complete_failed') and org is distinct from (p_payload->>'organization_id')::uuid then
      raise exception 'ONBOARDING_FORBIDDEN' using errcode='42501';
    end if;
    select * into member from public.agents where id=op.member_id and organization_id=org;
    if op.status='revoked' or member.id is null or member.extra->>'role'<>op.role then
      raise exception 'ONBOARDING_REVOKED' using errcode='23514';
    end if;
    select * into account from auth.users where id=op.intended_user_id;
    if account.id is not null and (account.raw_app_meta_data->>'onboarding_operation_id' is distinct from op.id::text
      or lower(account.email) is distinct from op.email) then
      raise exception 'ONBOARDING_ACCOUNT_MISMATCH' using errcode='23514';
    end if;
    if p_command in ('preview','complete_claim','complete_status','complete_finish','complete_failed') then
      -- Recipient reconciliation after an ambiguous successful completion is
      -- read-only. Anonymous or reused links still cannot reopen setup.
      if op.status='completed' and p_actor=op.intended_user_id then return to_jsonb(op); end if;
      current_hash:=p_payload->>'context_hash';
      if op.mode<>'invitation' or op.context_hash is null or current_hash is distinct from op.context_hash
        or op.context_expires_at<=clock_timestamp() or op.status='completed' then
        raise exception 'ONBOARDING_LINK_INVALID' using errcode='23514';
      end if;
      if p_command<>'preview' and (p_actor<>op.intended_user_id or account.email_confirmed_at is null) then
        raise exception 'ONBOARDING_FORBIDDEN' using errcode='42501';
      end if;
    end if;
    if p_command in ('status','complete_status') then
      return to_jsonb(op)||jsonb_build_object('account_exists',account.id is not null,
        'has_password',coalesce(account.encrypted_password,'')<>'','email_confirmed',account.email_confirmed_at is not null);
    elsif p_command='preview' then
      return jsonb_build_object('organization_name',(select name from public.organizations where id=org),
        'email',op.email,'role',op.role,'user_id',op.intended_user_id);
    elsif p_command in ('claim','resend','complete_claim') then
      if op.status='completed' then return to_jsonb(op); end if;
      if op.lease_until>clock_timestamp() then raise exception 'ONBOARDING_BUSY' using errcode='55P03'; end if;
      if p_command='resend' then
        if op.mode<>'invitation' or coalesce(account.encrypted_password,'')<>'' then
          raise exception 'ONBOARDING_RESEND_NOT_ALLOWED' using errcode='23514';
        end if;
        if op.delivery_request_id=(p_payload->>'delivery_request_id')::uuid then
          -- Same accepted or ambiguous delivery attempt: do not rotate its context.
          if op.delivery_accepted_at is not null then return to_jsonb(op); end if;
        else
          if op.updated_at>clock_timestamp()-interval '60 seconds' then
            raise exception 'ONBOARDING_RESEND_RATE_LIMIT' using errcode='54000';
          end if;
          op.generation:=op.generation+1;
          op.delivery_request_id:=(p_payload->>'delivery_request_id')::uuid;
          op.context_hash:=null;
          op.delivery_accepted_at:=null;
        end if;
      end if;
      if p_command='complete_claim' then op.status:='completing'; end if;
      op.lease_id:=(p_payload->>'lease_id')::uuid;
      if op.lease_id is null then raise exception 'ONBOARDING_INVALID_REQUEST'; end if;
      op.lease_until:=clock_timestamp()+interval '90 seconds';
    elsif p_command in ('account_created','context','sent','finish','failed','complete_finish','complete_failed') then
      lease:=(p_payload->>'lease_id')::uuid;
      if lease is null or op.lease_id is distinct from lease or op.lease_until<=clock_timestamp() then
        raise exception 'ONBOARDING_STALE_ATTEMPT' using errcode='40001';
      end if;
      if p_command='account_created' then
        if account.id is null then raise exception 'ONBOARDING_ACCOUNT_MISSING'; end if;
        op.status:='account_created';
      elsif p_command='context' then
        if op.mode<>'invitation' or p_payload->>'context_hash' !~ '^[a-f0-9]{64}$' then raise exception 'ONBOARDING_INVALID_REQUEST'; end if;
        op.context_hash:=p_payload->>'context_hash';
        -- Native Auth link expiry is enforced independently by verifyOtp.
        op.context_expires_at:=clock_timestamp()+interval '24 hours';
        op.delivery_request_id:=coalesce(op.delivery_request_id,op.request_id);
      elsif p_command='sent' then
        op.status:='invitation_sent'; op.delivery_accepted_at:=clock_timestamp(); op.failure_code:=null;
        op.lease_id:=null; op.lease_until:=null;
      elsif p_command in ('finish','complete_finish') then
        if account.id is null or account.email_confirmed_at is null or coalesce(account.encrypted_password,'')='' then
          raise exception 'ONBOARDING_PASSWORD_REQUIRED' using errcode='23514';
        end if;
        if p_command='finish' and op.mode<>'direct' then raise exception 'ONBOARDING_FORBIDDEN'; end if;
        if p_command='complete_finish' and op.status<>'completing' then raise exception 'ONBOARDING_FORBIDDEN'; end if;
        -- Mark before UPDATE so the acceptance trigger recognizes this exact finalization.
        update public.platform_user_onboarding set status='completed',context_hash=null,lease_id=null,lease_until=null where id=op.id;
        update public.agents set user_id=op.intended_user_id,
          extra=jsonb_set(member.extra,'{invitation,status}','"accepted"') where id=op.member_id;
        op.status:='completed'; op.context_hash:=null; op.failure_code:=null; op.lease_id:=null; op.lease_until:=null;
      else
        if p_payload->>'code' not in ('AUTH_UNAVAILABLE','AUTH_REJECTED','PASSWORD_REENTRY_REQUIRED','WEAK_PASSWORD','SMTP_FAILED','DELIVERY_UNKNOWN','FINALIZATION_FAILED') then
          raise exception 'ONBOARDING_INVALID_REQUEST';
        end if;
        op.failure_code:=p_payload->>'code'; op.lease_id:=null; op.lease_until:=null;
      end if;
    else raise exception 'ONBOARDING_INVALID_REQUEST' using errcode='22023'; end if;
    update public.platform_user_onboarding set status=op.status,failure_code=op.failure_code,generation=op.generation,
      context_hash=op.context_hash,context_expires_at=op.context_expires_at,delivery_request_id=op.delivery_request_id,
      delivery_accepted_at=op.delivery_accepted_at,lease_id=op.lease_id,lease_until=op.lease_until,updated_at=clock_timestamp()
      where id=op.id returning * into op;
  end if;
  insert into public.platform_user_onboarding_events(operation_id,actor_user_id,event,code,member_state)
    values(op.id,p_actor,event_name,op.failure_code,jsonb_build_object('member_id',op.member_id,'email',op.email,
      'role',op.role,'mode',op.mode,'status',op.status,'generation',op.generation));
  perform realtime.send(jsonb_build_object('module','team_members'),'module-permissions','module-permissions:'||op.organization_id::text,true);
  return to_jsonb(op);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.prevent_last_owner_deletion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  owner_count int;
begin
  -- Skip check if org is being deleted (cascade delete)
  perform public.lock_organization_team(old.organization_id);
  if not exists (select 1 from public.organizations where id=old.organization_id) then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if old.extra->>'role' = 'owner'
    and coalesce(old.extra->'invitation'->>'status','accepted')='accepted' then
    select count(*) into owner_count
    from public.agents
    where organization_id = old.organization_id
      and extra->>'role' = 'owner'
      and (
        extra->>'invitation' is null
        or extra->'invitation'->>'status' = 'accepted'
      )
      and id <> old.id;

    if owner_count = 0 then
      raise exception 'Cannot delete the last owner of an organization';
    end if;
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$function$
;

grant references on table "public"."platform_user_onboarding" to "service_role";

grant trigger on table "public"."platform_user_onboarding" to "service_role";

grant truncate on table "public"."platform_user_onboarding" to "service_role";

grant references on table "public"."platform_user_onboarding_events" to "service_role";

grant trigger on table "public"."platform_user_onboarding_events" to "service_role";

grant truncate on table "public"."platform_user_onboarding_events" to "service_role";

CREATE TRIGGER z_onboarding_membership BEFORE DELETE OR UPDATE ON public.agents FOR EACH ROW EXECUTE FUNCTION public.guard_onboarding_membership();
-- Preserve source-declared security: migra does not emit function ACL changes.
revoke all on table public.platform_user_onboarding,public.platform_user_onboarding_events from anon,authenticated;
revoke update,delete on public.platform_user_onboarding_events from service_role;
revoke all on function public.platform_onboarding_command(uuid,text,jsonb),public.guard_onboarding_membership() from public,anon,authenticated;
grant execute on function public.platform_onboarding_command(uuid,text,jsonb) to service_role;
revoke all on function public.list_platform_member_onboarding(uuid,uuid[]) from public,anon;
grant execute on function public.list_platform_member_onboarding(uuid,uuid[]) to authenticated;



