create table "public"."campaign_log_export_parts" (
    "export_id" uuid not null,
    "part_no" bigint not null,
    "path" text not null
      );


alter table "public"."campaign_log_export_parts" enable row level security;


  create table "public"."campaign_log_export_rows" (
    "export_id" uuid not null,
    "ordinal" bigint not null,
    "sent_at" timestamp with time zone,
    "recipient" text not null,
    "recipient_name" text,
    "variables" jsonb not null,
    "status" text not null
      );


alter table "public"."campaign_log_export_rows" enable row level security;


  create table "public"."campaign_log_exports" (
    "id" uuid not null default gen_random_uuid(),
    "organization_id" uuid not null,
    "campaign_id" uuid not null,
    "owner_id" uuid not null,
    "request_id" uuid not null,
    "state" text not null default 'queued'::text,
    "snapshot_at" timestamp with time zone not null default clock_timestamp(),
    "expires_at" timestamp with time zone not null default (clock_timestamp() + '24:00:00'::interval),
    "timezone" text not null,
    "template" jsonb not null,
    "mapping" jsonb not null,
    "sender_number" text not null,
    "display_name" text not null,
    "row_count" bigint not null default 0,
    "processed_count" bigint not null default 0,
    "lease_token" uuid,
    "lease_until" timestamp with time zone,
    "failures" integer not null default 0,
    "ticket_hash" text,
    "ticket_until" timestamp with time zone
      );


alter table "public"."campaign_log_exports" enable row level security;

CREATE UNIQUE INDEX campaign_log_export_parts_pkey ON public.campaign_log_export_parts USING btree (export_id, part_no);

CREATE UNIQUE INDEX campaign_log_export_rows_pkey ON public.campaign_log_export_rows USING btree (export_id, ordinal);

CREATE INDEX campaign_log_exports_lookup_idx ON public.campaign_log_exports USING btree (organization_id, campaign_id, owner_id, snapshot_at DESC);

CREATE UNIQUE INDEX campaign_log_exports_owner_id_request_id_key ON public.campaign_log_exports USING btree (owner_id, request_id);

CREATE INDEX campaign_log_exports_pending_idx ON public.campaign_log_exports USING btree (state, lease_until, snapshot_at);

CREATE UNIQUE INDEX campaign_log_exports_pkey ON public.campaign_log_exports USING btree (id);

alter table "public"."campaign_log_export_parts" add constraint "campaign_log_export_parts_pkey" PRIMARY KEY using index "campaign_log_export_parts_pkey";

alter table "public"."campaign_log_export_rows" add constraint "campaign_log_export_rows_pkey" PRIMARY KEY using index "campaign_log_export_rows_pkey";

alter table "public"."campaign_log_exports" add constraint "campaign_log_exports_pkey" PRIMARY KEY using index "campaign_log_exports_pkey";

alter table "public"."campaign_log_export_parts" add constraint "campaign_log_export_parts_export_id_fkey" FOREIGN KEY (export_id) REFERENCES public.campaign_log_exports(id) ON DELETE CASCADE not valid;

alter table "public"."campaign_log_export_parts" validate constraint "campaign_log_export_parts_export_id_fkey";

alter table "public"."campaign_log_export_rows" add constraint "campaign_log_export_rows_export_id_fkey" FOREIGN KEY (export_id) REFERENCES public.campaign_log_exports(id) ON DELETE CASCADE not valid;

alter table "public"."campaign_log_export_rows" validate constraint "campaign_log_export_rows_export_id_fkey";

alter table "public"."campaign_log_export_rows" add constraint "campaign_log_export_rows_status_check" CHECK ((status = ANY (ARRAY['Delivered'::text, 'Not Delivered'::text, ''::text]))) not valid;

alter table "public"."campaign_log_export_rows" validate constraint "campaign_log_export_rows_status_check";

alter table "public"."campaign_log_exports" add constraint "campaign_log_exports_check" CHECK (((processed_count >= 0) AND (processed_count <= row_count))) not valid;

alter table "public"."campaign_log_exports" validate constraint "campaign_log_exports_check";

alter table "public"."campaign_log_exports" add constraint "campaign_log_exports_organization_id_campaign_id_fkey" FOREIGN KEY (organization_id, campaign_id) REFERENCES public.campaigns(organization_id, id) ON DELETE CASCADE not valid;

alter table "public"."campaign_log_exports" validate constraint "campaign_log_exports_organization_id_campaign_id_fkey";

alter table "public"."campaign_log_exports" add constraint "campaign_log_exports_owner_id_fkey" FOREIGN KEY (owner_id) REFERENCES auth.users(id) ON DELETE CASCADE not valid;

alter table "public"."campaign_log_exports" validate constraint "campaign_log_exports_owner_id_fkey";

alter table "public"."campaign_log_exports" add constraint "campaign_log_exports_owner_id_request_id_key" UNIQUE using index "campaign_log_exports_owner_id_request_id_key";

alter table "public"."campaign_log_exports" add constraint "campaign_log_exports_state_check" CHECK ((state = ANY (ARRAY['queued'::text, 'processing'::text, 'ready'::text, 'failed'::text]))) not valid;

alter table "public"."campaign_log_exports" validate constraint "campaign_log_exports_state_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.authorize_campaign_log_export(p_org uuid, p_campaign uuid, p_owner uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists(select 1 from public.agents a
    join public.organization_lifecycle l on l.organization_id=a.organization_id and l.status='active'
    join public.campaigns c on c.organization_id=a.organization_id and c.id=p_campaign and c.status='completed'
    where a.organization_id=p_org and a.user_id=p_owner and a.extra->>'role'='owner'
      and (a.extra->'invitation' is null or a.extra->'invitation'->>'status'='accepted'));
$function$
;

CREATE OR REPLACE FUNCTION public.campaign_log_export_cleanup_candidates()
 RETURNS SETOF text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select folder from (
    select id::text folder from public.campaign_log_exports where expires_at<=now()
    union
    select split_part(name,'/',1) from storage.objects o where bucket_id='campaign-log-exports'
      and not exists(select 1 from public.campaign_log_exports e where e.id::text=split_part(o.name,'/',1) and e.expires_at>now())
  ) candidates order by folder limit 5;
$function$
;

CREATE OR REPLACE FUNCTION public.campaign_log_export_info(p_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object('id',id,'state',state,'snapshot_at',snapshot_at,'expires_at',expires_at,
    'timezone',timezone,'row_count',row_count,'processed_count',processed_count)
  from public.campaign_log_exports where id=p_id;
$function$
;

CREATE OR REPLACE FUNCTION public.claim_campaign_log_export()
 RETURNS public.campaign_log_exports
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e public.campaign_log_exports;
begin
  select * into e from public.campaign_log_exports
    where expires_at>clock_timestamp() and (state='queued' or (state='processing' and lease_until<clock_timestamp()))
      and public.authorize_campaign_log_export(organization_id,campaign_id,owner_id)
    order by snapshot_at,id limit 1 for update skip locked;
  if not found then return null; end if;
  update public.campaign_log_exports set state='processing',lease_token=gen_random_uuid(),lease_until=clock_timestamp()+interval '60 seconds'
    where id=e.id returning * into e;
  return e;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.consume_campaign_log_download(p_ticket text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e public.campaign_log_exports;
begin
  if length(p_ticket)<>64 then return null; end if;
  select * into e from public.campaign_log_exports where ticket_hash=encode(extensions.digest(p_ticket,'sha256'),'hex') for update;
  if not found then return null; end if;
  update public.campaign_log_exports set ticket_hash=null,ticket_until=null where id=e.id;
  if e.state<>'ready' or e.expires_at<=clock_timestamp() or e.ticket_until<=clock_timestamp()
    or not public.authorize_campaign_log_export(e.organization_id,e.campaign_id,e.owner_id) then return null; end if;
  return public.campaign_log_export_info(e.id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.finish_campaign_log_export_part(p_export_id uuid, p_token uuid, p_success boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e public.campaign_log_exports; next_count bigint;
begin
  select * into e from public.campaign_log_exports where id=p_export_id for update;
  if not found or e.state<>'processing' or e.lease_token is distinct from p_token or e.lease_until<=clock_timestamp()
    or e.expires_at<=clock_timestamp() then return false; end if;
  if not p_success then
    update public.campaign_log_exports set failures=failures+1,state=case when failures>=2 then 'failed' else 'queued' end,
      lease_token=null,lease_until=null where id=e.id;
    return true;
  end if;
  next_count:=least(e.processed_count+100,e.row_count);
  if next_count>e.processed_count then
    insert into public.campaign_log_export_parts(export_id,part_no,path)
      values(e.id,e.processed_count/100,e.id::text||'/'||(e.processed_count/100)::text||'.csv') on conflict do nothing;
  end if;
  update public.campaign_log_exports set processed_count=next_count,
    state=case when next_count=e.row_count then 'ready' else 'queued' end,
    failures=0,lease_token=null,lease_until=null where id=e.id;
  return true;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_campaign_log_export(p_organization_id uuid, p_campaign_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;
begin
  if auth.uid() is null or not public.authorize_campaign_log_export(p_organization_id,p_campaign_id,auth.uid()) then
    raise exception using errcode='42501',message='Completed campaign and organization Owner access required'; end if;
  select public.campaign_log_export_info(id) into result from public.campaign_log_exports
    where organization_id=p_organization_id and campaign_id=p_campaign_id and owner_id=auth.uid()
      and expires_at>clock_timestamp() order by snapshot_at desc,id desc limit 1;
  return result;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.issue_campaign_log_download(p_export_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e public.campaign_log_exports; ticket text;
begin
  select * into e from public.campaign_log_exports where id=p_export_id for update;
  if not found or auth.uid() is null or e.owner_id<>auth.uid()
    or not public.authorize_campaign_log_export(e.organization_id,e.campaign_id,auth.uid()) then
    raise exception using errcode='42501',message='Owner access required'; end if;
  if e.state<>'ready' or e.expires_at<=clock_timestamp() then raise exception 'Export unavailable'; end if;
  ticket:=encode(extensions.gen_random_bytes(32),'hex');
  update public.campaign_log_exports set ticket_hash=encode(extensions.digest(ticket,'sha256'),'hex'),
    ticket_until=clock_timestamp()+interval '1 minute' where id=e.id;
  return ticket;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.request_campaign_log_export(p_organization_id uuid, p_campaign_id uuid, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c public.campaigns; e public.campaign_log_exports; profile jsonb; count_rows bigint;
begin
  if auth.uid() is null or not public.authorize_campaign_log_export(p_organization_id,p_campaign_id,auth.uid()) then
    raise exception using errcode='42501',message='Completed campaign and organization Owner access required';
  end if;
  if p_request_id is null then raise exception 'Request ID required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('campaign-export:'||p_campaign_id::text||auth.uid()::text,0));
  select * into e from public.campaign_log_exports where owner_id=auth.uid() and request_id=p_request_id;
  if found then
    if e.organization_id<>p_organization_id or e.campaign_id<>p_campaign_id then raise exception 'Request ID conflict'; end if;
    if e.expires_at<=clock_timestamp() then raise exception 'Export expired; use a new request ID'; end if;
    return public.campaign_log_export_info(e.id);
  end if;
  select * into e from public.campaign_log_exports where organization_id=p_organization_id
    and campaign_id=p_campaign_id and owner_id=auth.uid() and expires_at>clock_timestamp()
    and state in ('queued','processing') order by snapshot_at desc limit 1;
  if found then return public.campaign_log_export_info(e.id); end if;
  select * into strict c from public.campaigns where organization_id=p_organization_id and id=p_campaign_id;
  select extra into profile from public.organizations_addresses where organization_id=p_organization_id
    and address=c.organization_address and service=c.service;
  insert into public.campaign_log_exports(organization_id,campaign_id,owner_id,request_id,timezone,template,mapping,sender_number,display_name)
  values(p_organization_id,c.id,auth.uid(),p_request_id,coalesce(c.schedule_timezone,'UTC'),c.template,c.template_variable_mapping,
    coalesce(profile->>'phone_number',''),coalesce(profile->>'verified_name','')) returning * into e;
  -- One statement/MVCC snapshot: later receipts cannot change a partially built export.
  insert into public.campaign_log_export_rows(export_id,ordinal,sent_at,recipient,recipient_name,variables,status)
  select e.id,row_number() over(order by d.id),coalesce(j.sent_at,a.sent_at),d.contact_address,d.name,d.variables,
    case when r.delivered_at is not null or r.read_at is not null then 'Delivered'
      when r.failed_at is not null or d.status='failed' then 'Not Delivered' else '' end
  from public.campaign_deliveries d
  left join public.campaign_delivery_receipts r on r.delivery_id=d.id
  left join lateral(select max(send_started_at) sent_at from public.campaign_dispatch_jobs where delivery_id=d.id) j on true
  left join lateral(select max(recorded_at) sent_at from public.campaign_activity
    where organization_id=p_organization_id and campaign_id=p_campaign_id and delivery_id=d.id and event_type='submission_started') a on true
  where d.organization_id=p_organization_id and d.campaign_id=p_campaign_id;
  get diagnostics count_rows=row_count;
  update public.campaign_log_exports set row_count=count_rows where id=e.id;
  return public.campaign_log_export_info(e.id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.retry_campaign_log_export(p_export_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e public.campaign_log_exports;
begin
  select * into e from public.campaign_log_exports where id=p_export_id for update;
  if not found or auth.uid() is null or e.owner_id<>auth.uid()
    or not public.authorize_campaign_log_export(e.organization_id,e.campaign_id,auth.uid()) then
    raise exception using errcode='42501',message='Owner access required'; end if;
  if e.expires_at<=clock_timestamp() then raise exception 'Export expired'; end if;
  if e.state='failed' then
    update public.campaign_log_exports set state='queued',failures=0,lease_token=null,lease_until=null where id=e.id;
  end if;
  return public.campaign_log_export_info(e.id);
end;
$function$
;

grant delete on table "public"."campaign_log_export_parts" to "service_role";

grant insert on table "public"."campaign_log_export_parts" to "service_role";

grant references on table "public"."campaign_log_export_parts" to "service_role";

grant select on table "public"."campaign_log_export_parts" to "service_role";

grant trigger on table "public"."campaign_log_export_parts" to "service_role";

grant truncate on table "public"."campaign_log_export_parts" to "service_role";

grant update on table "public"."campaign_log_export_parts" to "service_role";

grant delete on table "public"."campaign_log_export_rows" to "service_role";

grant insert on table "public"."campaign_log_export_rows" to "service_role";

grant references on table "public"."campaign_log_export_rows" to "service_role";

grant select on table "public"."campaign_log_export_rows" to "service_role";

grant trigger on table "public"."campaign_log_export_rows" to "service_role";

grant truncate on table "public"."campaign_log_export_rows" to "service_role";

grant update on table "public"."campaign_log_export_rows" to "service_role";

grant delete on table "public"."campaign_log_exports" to "service_role";

grant insert on table "public"."campaign_log_exports" to "service_role";

grant references on table "public"."campaign_log_exports" to "service_role";

grant select on table "public"."campaign_log_exports" to "service_role";

grant trigger on table "public"."campaign_log_exports" to "service_role";

grant truncate on table "public"."campaign_log_exports" to "service_role";

grant update on table "public"."campaign_log_exports" to "service_role";

-- Explicit privileges: migra does not preserve function ACLs/default grants.
revoke all on public.campaign_log_exports,public.campaign_log_export_rows,public.campaign_log_export_parts from public,anon,authenticated;
revoke all on function public.authorize_campaign_log_export(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.authorize_campaign_log_export(uuid,uuid,uuid) to service_role;
revoke all on function public.campaign_log_export_info(uuid) from public,anon,authenticated;
grant execute on function public.campaign_log_export_info(uuid) to service_role;
revoke all on function public.request_campaign_log_export(uuid,uuid,uuid) from public,anon;
grant execute on function public.request_campaign_log_export(uuid,uuid,uuid) to authenticated;
revoke all on function public.get_campaign_log_export(uuid,uuid) from public,anon;
grant execute on function public.get_campaign_log_export(uuid,uuid) to authenticated;
revoke all on function public.retry_campaign_log_export(uuid) from public,anon;
grant execute on function public.retry_campaign_log_export(uuid) to authenticated;
revoke all on function public.issue_campaign_log_download(uuid) from public,anon;
grant execute on function public.issue_campaign_log_download(uuid) to authenticated;
revoke all on function public.consume_campaign_log_download(text) from public,anon,authenticated;
grant execute on function public.consume_campaign_log_download(text) to service_role;
revoke all on function public.claim_campaign_log_export() from public,anon,authenticated;
grant execute on function public.claim_campaign_log_export() to service_role;
revoke all on function public.finish_campaign_log_export_part(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function public.finish_campaign_log_export_part(uuid,uuid,boolean) to service_role;
revoke all on function public.campaign_log_export_cleanup_candidates() from public,anon,authenticated;
grant execute on function public.campaign_log_export_cleanup_candidates() to service_role;

-- Data definitions: db diff cannot capture bucket/cron records. Include these
-- statements in the generated feature migration as the documented data exception.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('campaign-log-exports','campaign-log-exports',false,20971520,array['text/csv'])
on conflict(id) do nothing;

select cron.schedule('campaign-log-exports-every-minute','* * * * *',
  $job$ select net.http_post(
    url:=(select decrypted_secret from vault.decrypted_secrets where name='edge_functions_url')||'/campaign-log-export',
    headers:=jsonb_build_object('content-type','application/json','authorization','Bearer '||
      (select decrypted_secret from vault.decrypted_secrets where name='edge_functions_token')),
    body:='{}'::jsonb,timeout_milliseconds:=30000); $job$);


