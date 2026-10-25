alter table "public"."chatbot_node_operations" drop constraint "chatbot_node_operations_action_check";

alter table "public"."chatbot_node_bridges" add column "account_ack_revision" bigint not null default 0;

alter table "public"."chatbot_node_bridges" add column "account_checked_at" timestamp with time zone;

alter table "public"."chatbot_node_bridges" add column "account_last_error" text;

alter table "public"."chatbot_node_bridges" add column "account_revision" bigint not null default 0;

alter table "public"."chatbot_node_bridges" add column "account_sync_status" text not null default 'pending'::text;

alter table "public"."chatbot_node_bridges" add column "account_synced_at" timestamp with time zone;

alter table "public"."chatbot_node_bridges" add constraint "chatbot_node_bridges_account_ack_revision_check" CHECK ((account_ack_revision >= 0)) not valid;

alter table "public"."chatbot_node_bridges" validate constraint "chatbot_node_bridges_account_ack_revision_check";

alter table "public"."chatbot_node_bridges" add constraint "chatbot_node_bridges_account_revision_check" CHECK ((account_revision >= 0)) not valid;

alter table "public"."chatbot_node_bridges" validate constraint "chatbot_node_bridges_account_revision_check";

alter table "public"."chatbot_node_bridges" add constraint "chatbot_node_bridges_account_sync_status_check" CHECK ((account_sync_status = ANY (ARRAY['pending'::text, 'syncing'::text, 'synchronized'::text, 'failed'::text]))) not valid;

alter table "public"."chatbot_node_bridges" validate constraint "chatbot_node_bridges_account_sync_status_check";

alter table "public"."chatbot_node_operations" add constraint "chatbot_node_operations_action_check" CHECK ((action = ANY (ARRAY['activate'::text, 'deactivate'::text, 'suspend'::text, 'restore'::text, 'resume'::text, 'resolve-and-close'::text, 'takeover'::text, 'account-sync'::text]))) not valid;

alter table "public"."chatbot_node_operations" validate constraint "chatbot_node_operations_action_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.complete_whatsapp_account_sync(p_request_id uuid, p_revision text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.chatbot_node_operations;
begin
  select * into o from public.chatbot_node_operations where request_id=p_request_id and action='account-sync' for update;
  if not found or p_revision is distinct from o.payload->>'account_revision' then return false; end if;
  update public.chatbot_node_bridges set account_ack_revision=p_revision::bigint,account_sync_status='synchronized',
    account_last_error=null,account_synced_at=now() where organization_id=o.organization_id and organization_address=o.organization_address
    and account_revision=p_revision::bigint;
  if not found then return false; end if;
  update public.chatbot_node_operations set status='succeeded',last_error=null,next_attempt_at=null,
    result=jsonb_build_object('account_revision',p_revision) where request_id=p_request_id;
  return true;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.enqueue_whatsapp_account_sync(p_organization_id uuid, p_address text, p_force boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b public.chatbot_node_bridges; request_id uuid; revision bigint;
begin
  perform 1 from public.organizations_addresses where organization_id=p_organization_id and address=p_address and service='whatsapp' for update;
  if not found then return null; end if;
  select * into b from public.chatbot_node_bridges where organization_id=p_organization_id and organization_address=p_address and engine<>'native' for update;
  if not found then return null; end if;
  if not p_force and b.account_revision>0 then
    select o.request_id into request_id from public.chatbot_node_operations o where o.organization_id=p_organization_id
      and o.organization_address=p_address and o.action='account-sync' and o.payload->>'account_revision'=b.account_revision::text
      and o.status not in ('succeeded','failed') order by o.created_at desc limit 1;
    if request_id is not null or b.account_sync_status='synchronized' then return request_id; end if;
  end if;
  revision:=b.account_revision+1;
  request_id:=gen_random_uuid();
  update public.chatbot_node_operations set status='failed',last_error='Superseded by newer account revision'
    where organization_id=p_organization_id and organization_address=p_address and action='account-sync' and status not in ('succeeded','failed');
  update public.chatbot_node_bridges set account_revision=revision,account_sync_status='pending',account_last_error=null
    where organization_id=p_organization_id and organization_address=p_address;
  insert into public.chatbot_node_operations(request_id,organization_id,organization_address,action,phase,payload)
    values(request_id,p_organization_id,p_address,'account-sync','account-sync',jsonb_build_object('account_revision',revision::text));
  return request_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.initialize_node_account_sync()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform public.enqueue_whatsapp_account_sync(new.organization_id,new.organization_address);
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_node_account_auth_failure(p_organization_id uuid, p_address text, p_revision text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform 1 from public.organizations_addresses where organization_id=p_organization_id and address=p_address for update;
  perform 1 from public.chatbot_node_bridges where organization_id=p_organization_id and organization_address=p_address
    and account_revision::text=p_revision and account_ack_revision=account_revision for update;
  if not found then return false; end if;
  update public.organizations_addresses set status='disconnected' where organization_id=p_organization_id and address=p_address and service='whatsapp' and status='connected';
  return found;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.resolve_whatsapp_account_sync(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.chatbot_node_operations; a public.organizations_addresses; b public.chatbot_node_bridges;
begin
  select * into o from public.chatbot_node_operations where request_id=p_request_id and action='account-sync';
  if not found then return null; end if;
  select * into b from public.chatbot_node_bridges where organization_id=o.organization_id and organization_address=o.organization_address;
  if b.account_revision::text<>o.payload->>'account_revision' then return null; end if;
  select * into a from public.organizations_addresses where organization_id=o.organization_id and address=o.organization_address and service='whatsapp';
  return jsonb_build_object('organization_id',a.organization_id,'phone_number_id',a.address,'account_revision',b.account_revision::text,
    'connected',a.status='connected','waba_id',a.extra->>'waba_id','application_id',a.extra->>'application_id',
    'access_token',case when a.status='connected' then a.extra->>'access_token' else null end,
    'token_expires_at',a.extra->>'token_expires_at');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.retry_whatsapp_account_sync(p_organization_id uuid, p_address text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_organization_id not in (select public.get_authorized_orgs('owner')) then
    raise exception 'owner access required' using errcode='42501';
  end if;
  return public.enqueue_whatsapp_account_sync(p_organization_id,p_address);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.sync_whatsapp_account_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.service='whatsapp' and (old.status is distinct from new.status
    or old.extra->>'access_token' is distinct from new.extra->>'access_token'
    or old.extra->>'token_expires_at' is distinct from new.extra->>'token_expires_at'
    or old.extra->>'waba_id' is distinct from new.extra->>'waba_id') then
    perform public.enqueue_whatsapp_account_sync(new.organization_id,new.address,true);
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.whatsapp_account_sync_status(p_organization_id uuid, p_address text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_organization_id not in (select public.get_authorized_orgs('member')) then
    raise exception 'organization access required' using errcode='42501';
  end if;
  return (select jsonb_build_object('revision',account_revision::text,'ack_revision',account_ack_revision::text,
    'status',account_sync_status,'last_error',account_last_error,'synced_at',account_synced_at)
    from public.chatbot_node_bridges where organization_id=p_organization_id and organization_address=p_address and engine<>'native');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.enqueue_node_chatbot_operation(p_organization_id uuid, p_address text, p_company_id text, p_request_id uuid, p_action text, p_payload jsonb)
 RETURNS public.chatbot_node_operations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  operation public.chatbot_node_operations;
  binding public.chatbot_node_bridges;
begin
  perform 1 from public.organizations_addresses where organization_id = p_organization_id
    and address = p_address and service = 'whatsapp' for update;
  if not found then raise exception 'WhatsApp number not found' using errcode = 'P0002'; end if;
  select * into operation from public.chatbot_node_operations where request_id = p_request_id;
  if found then
    if operation.organization_id <> p_organization_id or operation.organization_address <> p_address
      or operation.action <> p_action or operation.payload <> p_payload then
      raise exception 'request ID cannot be reused with different data' using errcode = '23514';
    end if;
    return operation;
  end if;
  if p_action in ('activate', 'restore', 'resume') and not exists (
    select 1 from public.organization_lifecycle where organization_id = p_organization_id and status = 'active'
  ) then raise exception 'organization is archived' using errcode = '42501'; end if;
  if exists (select 1 from public.chatbot_node_operations where organization_id = p_organization_id
    and organization_address = p_address and action <> 'account-sync' and status not in ('succeeded', 'failed')) then
    raise exception 'number has an unresolved bridge operation' using errcode = '23514';
  end if;
  if p_action = 'activate' then
    if exists (select 1 from public.chatbot_flow_deployments where organization_id = p_organization_id
      and organization_address = p_address) or exists (
      select 1 from public.chatbot_flow_runs r join public.conversations c on c.id = r.conversation_id
      where c.organization_id = p_organization_id and c.organization_address = p_address and r.status in ('running', 'waiting')
    ) then raise exception 'deactivate native deployment and finish active native sessions first' using errcode = '23514'; end if;
    if not exists (select 1 from public.chatbot_flow_versions v join public.chatbot_flows f on f.id = v.flow_id
      where v.organization_id = p_organization_id and v.id = (p_payload->>'source_version_id')::uuid
      and v.flow_id = (p_payload->>'source_flow_id')::uuid and v.status = 'published' and f.status = 'active') then
      raise exception 'published tenant flow not found' using errcode = '23514';
    end if;
  end if;
  insert into public.chatbot_node_bridges(organization_id, organization_address, node_company_id)
    values(p_organization_id, p_address, p_company_id) on conflict do nothing;
  select * into binding from public.chatbot_node_bridges where organization_id = p_organization_id
    and organization_address = p_address for update;
  if binding.node_company_id <> p_company_id then raise exception 'Node tenant mapping mismatch' using errcode = '23514'; end if;
  insert into public.chatbot_node_operations(request_id, organization_id, organization_address, action, phase, payload)
    values(p_request_id, p_organization_id, p_address, p_action,
      case when p_action = 'activate' then 'prepare' else p_action end, p_payload) returning * into operation;
  -- Until acknowledged, suppress native execution; failures cannot silently
  -- restore native mode because the remote result may be ambiguous.
  update public.chatbot_node_bridges set engine = 'transitioning', sync_status = 'pending',
    flow_id = case when p_action = 'activate' then (p_payload->>'source_flow_id')::uuid else flow_id end,
    flow_version_id = case when p_action = 'activate' then (p_payload->>'source_version_id')::uuid else flow_version_id end,
    request_id = p_request_id, last_error = null, updated_at = now()
    where organization_id = p_organization_id and organization_address = p_address;
  return operation;
end;
$function$
;

CREATE TRIGGER initialize_node_account_sync AFTER INSERT ON public.chatbot_node_bridges FOR EACH ROW EXECUTE FUNCTION public.initialize_node_account_sync();

CREATE TRIGGER sync_whatsapp_account_change AFTER UPDATE ON public.organizations_addresses FOR EACH ROW EXECUTE FUNCTION public.sync_whatsapp_account_change();



-- Preserve explicit schema-source function privileges (migra omits ACL changes).
revoke all on function public.enqueue_whatsapp_account_sync(uuid,text,boolean) from public,anon,authenticated;
grant execute on function public.enqueue_whatsapp_account_sync(uuid,text,boolean) to service_role;
revoke all on function public.resolve_whatsapp_account_sync(uuid) from public,anon,authenticated;
grant execute on function public.resolve_whatsapp_account_sync(uuid) to service_role;
revoke all on function public.record_node_account_auth_failure(uuid,text,text) from public,anon,authenticated;
grant execute on function public.record_node_account_auth_failure(uuid,text,text) to service_role;
revoke all on function public.complete_whatsapp_account_sync(uuid,text) from public,anon,authenticated;
grant execute on function public.complete_whatsapp_account_sync(uuid,text) to service_role;
revoke all on function public.whatsapp_account_sync_status(uuid,text) from public,anon;
grant execute on function public.whatsapp_account_sync_status(uuid,text) to authenticated,service_role;
revoke all on function public.retry_whatsapp_account_sync(uuid,text) from public,anon;
grant execute on function public.retry_whatsapp_account_sync(uuid,text) to authenticated;
